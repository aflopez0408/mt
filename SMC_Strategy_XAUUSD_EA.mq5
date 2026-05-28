//+------------------------------------------------------------------+
//|                                      SMC_Strategy_XAUUSD_EA.mq5  |
//|                        SMC POI Strategy - Expert Advisor for MT5  |
//|                          Basado en Smart Money Concepts (ICT)     |
//+------------------------------------------------------------------+
#property copyright "SMC Strategy"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| ENUMERACIONES                                                      |
//+------------------------------------------------------------------+
enum ENUM_ENTRY_TYPE
{
   ENTRY_BOTH = 0,       // Ambos (Long y Short)
   ENTRY_LONG_ONLY = 1,  // Solo Longs
   ENTRY_SHORT_ONLY = 2  // Solo Shorts
};

enum ENUM_SL_TYPE
{
   SL_OB_EDGE = 0,  // Borde del Order Block
   SL_ATR = 1,      // Basado en ATR
   SL_FIXED = 2     // Fijo en pips
};

enum ENUM_MARKET_TREND
{
   TREND_NEUTRAL = 0,   // Neutral
   TREND_BULLISH = 1,   // Alcista
   TREND_BEARISH = -1   // Bajista
};

//+------------------------------------------------------------------+
//| INPUTS                                                             |
//+------------------------------------------------------------------+
input group "=== ESTRUCTURA DE MERCADO ==="
input int      InpSwingLen = 5;           // Longitud Swing (pivots)
input bool     InpShowBOS = true;         // Mostrar BOS/CHoCH en grafico

input group "=== ORDER BLOCKS ==="
input int      InpMaxActiveOB = 3;        // Max Order Blocks activos (por lado)
input bool     InpShowOB = true;          // Mostrar Order Blocks en grafico

input group "=== FILTRO DE SESION ==="
input bool     InpUseSessionFilter = true;  // Usar filtro de sesion
input int      InpLondonStart = 2;          // London KZ Inicio (hora servidor)
input int      InpLondonEnd = 5;            // London KZ Fin (hora servidor)
input int      InpNYStart = 7;              // NY KZ Inicio (hora servidor)
input int      InpNYEnd = 10;              // NY KZ Fin (hora servidor)
input int      InpLondonCloseStart = 10;    // London Close Inicio (hora servidor)
input int      InpLondonCloseEnd = 12;      // London Close Fin (hora servidor)

input group "=== CONFIGURACION DE ENTRADAS ==="
input ENUM_ENTRY_TYPE InpEntryType = ENTRY_BOTH; // Tipo de operaciones
input bool     InpRequireBOS = true;      // Requiere BOS previo para entrada
input bool     InpRequireFVG = false;     // Requiere FVG como confluencia

input group "=== GESTION DE RIESGO ==="
input double   InpRiskReward = 3.0;       // Ratio Riesgo:Beneficio
input ENUM_SL_TYPE InpSLType = SL_OB_EDGE; // Tipo de Stop Loss
input double   InpSLATRMult = 1.5;        // Multiplicador ATR para SL
input double   InpSLFixedPips = 50.0;     // SL Fijo (pips)
input bool     InpUseTrailing = false;    // Usar Trailing Stop
input double   InpTrailATRMult = 2.0;     // Trailing ATR Multiplicador
input int      InpMaxDailyTrades = 3;     // Max operaciones por dia
input double   InpRiskPercent = 1.0;      // Riesgo % del balance por trade
input int      InpMagicNumber = 123456;   // Magic Number (identificador)

//+------------------------------------------------------------------+
//| ESTRUCTURAS                                                        |
//+------------------------------------------------------------------+
struct OrderBlock
{
   double   top;
   double   bottom;
   int      barIndex;
   bool     active;
   datetime time;
};

struct SwingPoint
{
   double   price;
   int      barIndex;
   datetime time;
};

//+------------------------------------------------------------------+
//| VARIABLES GLOBALES                                                 |
//+------------------------------------------------------------------+
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

SwingPoint     swingHigh, prevSwingHigh;
SwingPoint     swingLow, prevSwingLow;
ENUM_MARKET_TREND marketTrend = TREND_NEUTRAL;
int            lastBosUpBar = 0;
int            lastBosDownBar = 0;

OrderBlock     obBull[];
OrderBlock     obBear[];

bool           recentFVGBull = false;
bool           recentFVGBear = false;
int            fvgBullBar = 0;
int            fvgBearBar = 0;

int            dailyTradeCount = 0;
int            lastTradeDay = 0;

int            atrHandle;
double         atrBuffer[];

int            lastProcessedBars = 0;


//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   symInfo.Name(_Symbol);
   symInfo.Refresh();
   
   atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("Error creando ATR handle: ", GetLastError());
      return(INIT_FAILED);
   }
   
   ArrayResize(obBull, 0);
   ArrayResize(obBear, 0);
   ArraySetAsSeries(atrBuffer, true);
   
   swingHigh.price = 0;
   swingHigh.barIndex = 0;
   swingLow.price = 0;
   swingLow.barIndex = 0;
   prevSwingHigh.price = 0;
   prevSwingLow.price = 0;
   
   Print("============================================");
   Print("  SMC POI Strategy EA - Iniciado");
   Print("  Riesgo por trade: ", InpRiskPercent, "%");
   Print("  R:R = 1:", InpRiskReward);
   Print("  Max trades/dia: ", InpMaxDailyTrades);
   Print("============================================");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                    |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   ObjectsDeleteAll(0, "SMC_");
   Print("SMC POI Strategy EA - Detenido");
}


//+------------------------------------------------------------------+
//| Expert tick function                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   int currentBars = iBars(_Symbol, PERIOD_CURRENT);
   if(currentBars == lastProcessedBars)
   {
      if(InpUseTrailing)
         ManageTrailingStop();
      return;
   }
   lastProcessedBars = currentBars;
   
   symInfo.Refresh();
   
   if(CopyBuffer(atrHandle, 0, 0, 3, atrBuffer) < 3)
      return;
   
   MqlDateTime timeStruct;
   TimeCurrent(timeStruct);
   if(timeStruct.day != lastTradeDay)
   {
      dailyTradeCount = 0;
      lastTradeDay = timeStruct.day;
   }
   
   DetectMarketStructure();
   DetectOrderBlocks();
   DetectFVG();
   MitigateOrderBlocks();
   
   if(CanTrade())
      CheckEntrySignals();
}


//+------------------------------------------------------------------+
//| DETECCION DE ESTRUCTURA DE MERCADO                                 |
//+------------------------------------------------------------------+
void DetectMarketStructure()
{
   int barsNeeded = InpSwingLen * 2 + 1;
   if(iBars(_Symbol, PERIOD_CURRENT) < barsNeeded + 5)
      return;
   
   double pivotHighPrice = FindPivotHigh(InpSwingLen);
   if(pivotHighPrice > 0)
   {
      prevSwingHigh = swingHigh;
      swingHigh.price = pivotHighPrice;
      swingHigh.barIndex = InpSwingLen;
      swingHigh.time = iTime(_Symbol, PERIOD_CURRENT, InpSwingLen);
   }
   
   double pivotLowPrice = FindPivotLow(InpSwingLen);
   if(pivotLowPrice > 0)
   {
      prevSwingLow = swingLow;
      swingLow.price = pivotLowPrice;
      swingLow.barIndex = InpSwingLen;
      swingLow.time = iTime(_Symbol, PERIOD_CURRENT, InpSwingLen);
   }
   
   double closePrice = iClose(_Symbol, PERIOD_CURRENT, 1);
   double prevClose = iClose(_Symbol, PERIOD_CURRENT, 2);
   
   // BOS Alcista
   if(swingHigh.price > 0 && closePrice > swingHigh.price && prevClose <= swingHigh.price)
   {
      if(marketTrend == TREND_BULLISH)
      {
         lastBosUpBar = 1;
         if(InpShowBOS) DrawBOSLabel(true, true, closePrice);
      }
      else
      {
         marketTrend = TREND_BULLISH;
         lastBosUpBar = 1;
         if(InpShowBOS) DrawBOSLabel(true, false, closePrice);
      }
   }
   
   // BOS Bajista
   if(swingLow.price > 0 && closePrice < swingLow.price && prevClose >= swingLow.price)
   {
      if(marketTrend == TREND_BEARISH)
      {
         lastBosDownBar = 1;
         if(InpShowBOS) DrawBOSLabel(false, true, closePrice);
      }
      else
      {
         marketTrend = TREND_BEARISH;
         lastBosDownBar = 1;
         if(InpShowBOS) DrawBOSLabel(false, false, closePrice);
      }
   }
   
   if(lastBosUpBar > 0) lastBosUpBar++;
   if(lastBosDownBar > 0) lastBosDownBar++;
}

double FindPivotHigh(int len)
{
   double highVal = iHigh(_Symbol, PERIOD_CURRENT, len);
   for(int i = 1; i <= len; i++)
   {
      if(iHigh(_Symbol, PERIOD_CURRENT, len + i) >= highVal) return 0;
      if(iHigh(_Symbol, PERIOD_CURRENT, len - i) >= highVal) return 0;
   }
   return highVal;
}

double FindPivotLow(int len)
{
   double lowVal = iLow(_Symbol, PERIOD_CURRENT, len);
   for(int i = 1; i <= len; i++)
   {
      if(iLow(_Symbol, PERIOD_CURRENT, len + i) <= lowVal) return 0;
      if(iLow(_Symbol, PERIOD_CURRENT, len - i) <= lowVal) return 0;
   }
   return lowVal;
}

void DrawBOSLabel(bool isBullish, bool isBOS, double price)
{
   static int bosCount = 0;
   bosCount++;
   string name = "SMC_BOS_" + IntegerToString(bosCount);
   datetime time = iTime(_Symbol, PERIOD_CURRENT, 1);
   string text = "";
   color clr;
   
   if(isBullish)
   { text = isBOS ? "BOS ^" : "CHoCH ^"; clr = isBOS ? clrTeal : clrDodgerBlue; }
   else
   { text = isBOS ? "BOS v" : "CHoCH v"; clr = isBOS ? clrMaroon : clrOrangeRed; }
   
   ObjectCreate(0, name, OBJ_TEXT, 0, time, price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
}


//+------------------------------------------------------------------+
//| DETECCION DE ORDER BLOCKS                                          |
//+------------------------------------------------------------------+
void DetectOrderBlocks()
{
   double atr = atrBuffer[0];
   if(atr <= 0) return;
   
   double open1  = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double high2  = iHigh(_Symbol, PERIOD_CURRENT, 2);
   double open2  = iOpen(_Symbol, PERIOD_CURRENT, 2);
   double close2 = iClose(_Symbol, PERIOD_CURRENT, 2);
   
   bool isImpulsiveUp = (close1 > open1) && ((close1 - open1) > atr) && (close1 > high2);
   bool isImpulsiveDown = (close1 < open1) && ((open1 - close1) > atr) && (close1 < iLow(_Symbol, PERIOD_CURRENT, 2));
   
   if(isImpulsiveUp && close2 < open2)
   {
      OrderBlock newOB;
      newOB.top = open2;
      newOB.bottom = close2;
      newOB.barIndex = 2;
      newOB.active = true;
      newOB.time = iTime(_Symbol, PERIOD_CURRENT, 2);
      AddOrderBlock(obBull, newOB);
      if(InpShowOB) DrawOrderBlock(newOB, true);
   }
   
   if(isImpulsiveDown && close2 > open2)
   {
      OrderBlock newOB;
      newOB.top = close2;
      newOB.bottom = open2;
      newOB.barIndex = 2;
      newOB.active = true;
      newOB.time = iTime(_Symbol, PERIOD_CURRENT, 2);
      AddOrderBlock(obBear, newOB);
      if(InpShowOB) DrawOrderBlock(newOB, false);
   }
}

void AddOrderBlock(OrderBlock &arr[], OrderBlock &newOB)
{
   int size = ArraySize(arr);
   ArrayResize(arr, size + 1);
   arr[size] = newOB;
   if(ArraySize(arr) > InpMaxActiveOB)
   {
      for(int i = 0; i < ArraySize(arr) - 1; i++)
         arr[i] = arr[i + 1];
      ArrayResize(arr, ArraySize(arr) - 1);
   }
}

void MitigateOrderBlocks()
{
   double closePrice = iClose(_Symbol, PERIOD_CURRENT, 1);
   for(int i = ArraySize(obBull) - 1; i >= 0; i--)
   {
      if(obBull[i].active && closePrice < obBull[i].bottom)
         obBull[i].active = false;
   }
   for(int i = ArraySize(obBear) - 1; i >= 0; i--)
   {
      if(obBear[i].active && closePrice > obBear[i].top)
         obBear[i].active = false;
   }
}

void DrawOrderBlock(OrderBlock &ob, bool isBullish)
{
   static int obCount = 0;
   obCount++;
   string name = (isBullish ? "SMC_OB_Bull_" : "SMC_OB_Bear_") + IntegerToString(obCount);
   datetime timeStart = ob.time;
   datetime timeEnd = timeStart + PeriodSeconds(PERIOD_CURRENT) * 20;
   color clr = isBullish ? clrGreen : clrRed;
   
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, timeStart, ob.top, timeEnd, ob.bottom);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
}


//+------------------------------------------------------------------+
//| DETECCION DE FVG                                                   |
//+------------------------------------------------------------------+
void DetectFVG()
{
   double low1 = iLow(_Symbol, PERIOD_CURRENT, 1);
   double high3 = iHigh(_Symbol, PERIOD_CURRENT, 3);
   double close2 = iClose(_Symbol, PERIOD_CURRENT, 2);
   double open2 = iOpen(_Symbol, PERIOD_CURRENT, 2);
   double high1 = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double low3 = iLow(_Symbol, PERIOD_CURRENT, 3);
   
   if(low1 > high3 && close2 > open2)
   { recentFVGBull = true; fvgBullBar = 1; }
   
   if(high1 < low3 && close2 < open2)
   { recentFVGBear = true; fvgBearBar = 1; }
   
   if(fvgBullBar > 0) fvgBullBar++;
   if(fvgBullBar > 20) { recentFVGBull = false; fvgBullBar = 0; }
   if(fvgBearBar > 0) fvgBearBar++;
   if(fvgBearBar > 20) { recentFVGBear = false; fvgBearBar = 0; }
}

//+------------------------------------------------------------------+
//| FILTRO DE SESION                                                   |
//+------------------------------------------------------------------+
bool IsInKillzone()
{
   MqlDateTime timeStruct;
   TimeCurrent(timeStruct);
   int hour = timeStruct.hour;
   if(hour >= InpLondonStart && hour < InpLondonEnd) return true;
   if(hour >= InpNYStart && hour < InpNYEnd) return true;
   if(hour >= InpLondonCloseStart && hour < InpLondonCloseEnd) return true;
   return false;
}

bool CanTrade()
{
   if(dailyTradeCount >= InpMaxDailyTrades) return false;
   if(InpUseSessionFilter && !IsInKillzone()) return false;
   return true;
}

bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
            return true;
   }
   return false;
}


//+------------------------------------------------------------------+
//| LOGICA DE ENTRADA                                                  |
//+------------------------------------------------------------------+
void CheckEntrySignals()
{
   if(HasOpenPosition()) return;
   
   double closePrice = iClose(_Symbol, PERIOD_CURRENT, 1);
   double openPrice = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double lowPrice = iLow(_Symbol, PERIOD_CURRENT, 1);
   double highPrice = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double atr = atrBuffer[0];
   
   // === ENTRADA LONG ===
   if(InpEntryType == ENTRY_BOTH || InpEntryType == ENTRY_LONG_ONLY)
   {
      for(int i = ArraySize(obBull) - 1; i >= 0; i--)
      {
         if(!obBull[i].active) continue;
         
         bool priceInOB = (lowPrice <= obBull[i].top) && (closePrice >= obBull[i].bottom) && (closePrice > openPrice);
         bool bosFilter = InpRequireBOS ? (lastBosUpBar > 0 && lastBosUpBar < 50) : true;
         bool fvgFilter = InpRequireFVG ? recentFVGBull : true;
         bool trendFilter = (marketTrend == TREND_BULLISH || marketTrend == TREND_NEUTRAL);
         
         if(priceInOB && bosFilter && fvgFilter && trendFilter)
         {
            double sl = CalculateSL(true, obBull[i].bottom, closePrice, atr);
            double riskAmount = closePrice - sl;
            double tp = closePrice + (riskAmount * InpRiskReward);
            double lots = CalculateLotSize(riskAmount);
            
            if(lots > 0 && sl > 0 && tp > 0)
            {
               if(ExecuteBuy(lots, sl, tp))
               {
                  obBull[i].active = false;
                  dailyTradeCount++;
                  Print("LONG | Entry:", closePrice, " SL:", sl, " TP:", tp, " Lots:", lots);
               }
            }
            break;
         }
      }
   }
   
   // === ENTRADA SHORT ===
   if(InpEntryType == ENTRY_BOTH || InpEntryType == ENTRY_SHORT_ONLY)
   {
      for(int i = ArraySize(obBear) - 1; i >= 0; i--)
      {
         if(!obBear[i].active) continue;
         
         bool priceInOB = (highPrice >= obBear[i].bottom) && (closePrice <= obBear[i].top) && (closePrice < openPrice);
         bool bosFilter = InpRequireBOS ? (lastBosDownBar > 0 && lastBosDownBar < 50) : true;
         bool fvgFilter = InpRequireFVG ? recentFVGBear : true;
         bool trendFilter = (marketTrend == TREND_BEARISH || marketTrend == TREND_NEUTRAL);
         
         if(priceInOB && bosFilter && fvgFilter && trendFilter)
         {
            double sl = CalculateSL(false, obBear[i].top, closePrice, atr);
            double riskAmount = sl - closePrice;
            double tp = closePrice - (riskAmount * InpRiskReward);
            double lots = CalculateLotSize(riskAmount);
            
            if(lots > 0 && sl > 0 && tp > 0)
            {
               if(ExecuteSell(lots, sl, tp))
               {
                  obBear[i].active = false;
                  dailyTradeCount++;
                  Print("SHORT | Entry:", closePrice, " SL:", sl, " TP:", tp, " Lots:", lots);
               }
            }
            break;
         }
      }
   }
}


//+------------------------------------------------------------------+
//| CALCULO DE STOP LOSS                                               |
//+------------------------------------------------------------------+
double CalculateSL(bool isLong, double obEdge, double entryPrice, double atr)
{
   double sl = 0;
   double point = symInfo.Point();
   
   if(InpSLType == SL_OB_EDGE)
   {
      if(isLong) sl = obEdge - (atr * 0.2);
      else       sl = obEdge + (atr * 0.2);
   }
   else if(InpSLType == SL_ATR)
   {
      if(isLong) sl = entryPrice - (atr * InpSLATRMult);
      else       sl = entryPrice + (atr * InpSLATRMult);
   }
   else
   {
      double pipValue = point * 10;
      if(isLong) sl = entryPrice - (InpSLFixedPips * pipValue);
      else       sl = entryPrice + (InpSLFixedPips * pipValue);
   }
   
   return NormalizeDouble(sl, (int)symInfo.Digits());
}

//+------------------------------------------------------------------+
//| CALCULO DE LOTAJE                                                  |
//+------------------------------------------------------------------+
double CalculateLotSize(double riskInPrice)
{
   if(riskInPrice <= 0) return 0;
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (InpRiskPercent / 100.0);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   if(tickValue <= 0 || tickSize <= 0) return 0;
   
   double lots = riskMoney / ((riskInPrice / tickSize) * tickValue);
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   
   return NormalizeDouble(lots, 2);
}


//+------------------------------------------------------------------+
//| EJECUTAR ORDENES                                                   |
//+------------------------------------------------------------------+
bool ExecuteBuy(double lots, double sl, double tp)
{
   double ask = symInfo.Ask();
   sl = NormalizeDouble(sl, (int)symInfo.Digits());
   tp = NormalizeDouble(tp, (int)symInfo.Digits());
   
   MqlTradeRequest request = {};
   MqlTradeResult  result = {};
   
   request.action    = TRADE_ACTION_DEAL;
   request.symbol    = _Symbol;
   request.volume    = lots;
   request.type      = ORDER_TYPE_BUY;
   request.price     = ask;
   request.sl        = sl;
   request.tp        = tp;
   request.deviation = 10;
   request.magic     = InpMagicNumber;
   request.comment   = "SMC_Long";
   request.type_filling = ORDER_FILLING_FOK;
   
   if(OrderSend(request, result))
      return (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED);
   
   Print("Error Buy: ", result.retcode, " - ", result.comment);
   return false;
}

bool ExecuteSell(double lots, double sl, double tp)
{
   double bid = symInfo.Bid();
   sl = NormalizeDouble(sl, (int)symInfo.Digits());
   tp = NormalizeDouble(tp, (int)symInfo.Digits());
   
   MqlTradeRequest request = {};
   MqlTradeResult  result = {};
   
   request.action    = TRADE_ACTION_DEAL;
   request.symbol    = _Symbol;
   request.volume    = lots;
   request.type      = ORDER_TYPE_SELL;
   request.price     = bid;
   request.sl        = sl;
   request.tp        = tp;
   request.deviation = 10;
   request.magic     = InpMagicNumber;
   request.comment   = "SMC_Short";
   request.type_filling = ORDER_FILLING_FOK;
   
   if(OrderSend(request, result))
      return (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED);
   
   Print("Error Sell: ", result.retcode, " - ", result.comment);
   return false;
}

//+------------------------------------------------------------------+
//| TRAILING STOP                                                      |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   double atr = atrBuffer[0];
   if(atr <= 0) return;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic() != InpMagicNumber) continue;
      
      double currentSL = posInfo.StopLoss();
      double currentTP = posInfo.TakeProfit();
      double openPrice = posInfo.PriceOpen();
      ulong ticket = posInfo.Ticket();
      
      if(posInfo.PositionType() == POSITION_TYPE_BUY)
      {
         double bid = symInfo.Bid();
         double newSL = NormalizeDouble(bid - (atr * InpTrailATRMult), (int)symInfo.Digits());
         if(newSL > currentSL && newSL > openPrice)
         {
            MqlTradeRequest req = {};
            MqlTradeResult  res = {};
            req.action    = TRADE_ACTION_SLTP;
            req.symbol    = _Symbol;
            req.position  = ticket;
            req.sl        = newSL;
            req.tp        = currentTP;
            OrderSend(req, res);
         }
      }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
      {
         double ask = symInfo.Ask();
         double newSL = NormalizeDouble(ask + (atr * InpTrailATRMult), (int)symInfo.Digits());
         if((newSL < currentSL || currentSL == 0) && newSL < openPrice)
         {
            MqlTradeRequest req = {};
            MqlTradeResult  res = {};
            req.action    = TRADE_ACTION_SLTP;
            req.symbol    = _Symbol;
            req.position  = ticket;
            req.sl        = newSL;
            req.tp        = currentTP;
            OrderSend(req, res);
         }
      }
   }
}
//+------------------------------------------------------------------+
