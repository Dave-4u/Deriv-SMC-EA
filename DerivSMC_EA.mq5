//+------------------------------------------------------------------+
//|                                                  DerivSMC_EA.mq5 |
//|     Multi-Pair Scanner | CRT + Rejection Block + Order Block     |
//|              H1 Trend Filter | Fixed $ Risk | Max 10 Trades      |
//+------------------------------------------------------------------+
#property copyright "Dave-4u"
#property link      "https://github.com/Dave-4u/Deriv-SMC-EA"
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//------------------- INPUTS ----------------------------------------
input group "=== MULTI-PAIR SETTINGS ==="
input string   SymbolsList           = "Volatility 75 Index,Volatility 100 Index,Boom 1000 Index,Crash 500 Index"; // Comma-separated symbols
input double   RiskMoney             = 3.0;     // Risk per trade in $ (e.g. 3.0 = $3)
input int      MaxOpenTrades         = 10;      // Max total open positions across all pairs

input group "=== Risk & Protection ==="
input double   DailyLossLimitPercent = 3.0;     // Max daily loss %
input int      MagicNumber           = 20261109;
input int      MaxSpreadPoints       = 100;

input group "=== Strategy Switches ==="
input bool     EnableCRT             = true;
input bool     EnableRejectionBlock  = true;
input bool     EnableOrderBlock      = true;

input group "=== Timeframes ==="
input ENUM_TIMEFRAMES TrendTF        = PERIOD_H1;
input ENUM_TIMEFRAMES EntryTF        = PERIOD_M5;

input group "=== Trend Filter ==="
input int      EMA_Period            = 50;
input int      CooldownBars          = 12;

input group "=== Trade Management ==="
input double   RR_Ratio              = 2.0;     // Risk:Reward
input int      Slippage              = 30;

//------------------- GLOBALS ----------------------------------------
string   symbols[];
int      symbolCount = 0;
datetime lastBarTime[];
int      cooldownCounter[];
double   dailyStartBalance = 0;
datetime dailyStartDate = 0;

//------------------- INITIALIZATION ---------------------------------
int OnInit()
{
   // Parse symbols list
   string temp = SymbolsList;
   StringReplace(temp, " ", "");          // remove spaces
   StringSplit(temp, ',', symbols);
   symbolCount = ArraySize(symbols);

   if(symbolCount == 0)
   {
      Print("ERROR: No symbols provided!");
      return(INIT_FAILED);
   }

   ArrayResize(lastBarTime, symbolCount);
   ArrayResize(cooldownCounter, symbolCount);
   ArrayInitialize(lastBarTime, 0);
   ArrayInitialize(cooldownCounter, 0);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyStartDate = TimeCurrent();

   Print("DerivSMC_EA Multi-Pair started | Symbols: ", symbolCount, " | Risk: $", RiskMoney, " | MaxTrades: ", MaxOpenTrades);
   for(int i=0; i<symbolCount; i++)
      Print("  → ", symbols[i]);

   return(INIT_SUCCEEDED);
}

//------------------- MAIN LOGIC -------------------------------------
void OnTick()
{
   if(!CheckDailyLossLimit()) return;
   if(CountAllOpenPositions() >= MaxOpenTrades) return;

   for(int i = 0; i < symbolCount; i++)
   {
      string sym = symbols[i];

      // Check if symbol is available
      if(!SymbolSelect(sym, true)) continue;

      // New bar check
      datetime barTime = iTime(sym, EntryTF, 0);
      if(barTime == lastBarTime[i]) continue;
      lastBarTime[i] = barTime;

      // Cooldown
      if(cooldownCounter[i] > 0)
      {
         cooldownCounter[i]--;
         continue;
      }

      // Spread filter
      long spread = SymbolInfoInteger(sym, SYMBOL_SPREAD);
      if(spread > MaxSpreadPoints) continue;

      // Trend filter
      int trend = GetTrendDirection(sym);
      if(trend == 0)
      {
         cooldownCounter[i] = CooldownBars;
         continue;
      }

      // Detect setups
      int signal = 0;

      if(EnableCRT)
         signal = DetectCRT(sym, trend);

      if(signal == 0 && EnableRejectionBlock)
         signal = DetectRejectionBlock(sym, trend);

      if(signal == 0 && EnableOrderBlock)
         signal = DetectOrderBlock(sym, trend);

      if(signal != 0)
      {
         // Only one position per symbol
         if(CountPositionsOnSymbol(sym) == 0)
            OpenTrade(sym, signal);
      }
   }
}

//------------------- TREND FILTER -----------------------------------
int GetTrendDirection(string sym)
{
   double ema[];
   ArraySetAsSeries(ema, true);
   int handle = iMA(sym, TrendTF, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   if(handle == INVALID_HANDLE) return 0;
   if(CopyBuffer(handle, 0, 0, 3, ema) < 3) return 0;

   double close1 = iClose(sym, TrendTF, 1);
   double close2 = iClose(sym, TrendTF, 2);

   bool bullishStructure = close1 > close2;
   bool bearishStructure = close1 < close2;

   if(close1 > ema[1] && bullishStructure) return 1;
   if(close1 < ema[1] && bearishStructure) return -1;

   return 0;
}

//------------------- CRT --------------------------------------------
int DetectCRT(string sym, int trend)
{
   double high1 = iHigh(sym, EntryTF, 2);
   double low1  = iLow(sym, EntryTF, 2);
   double high2 = iHigh(sym, EntryTF, 1);
   double low2  = iLow(sym, EntryTF, 1);
   double close2= iClose(sym, EntryTF, 1);

   if(trend == 1 && low2 < low1 && close2 > low1 && close2 < high1)
   {
      Print(sym, " | CRT Bullish");
      return 1;
   }
   if(trend == -1 && high2 > high1 && close2 < high1 && close2 > low1)
   {
      Print(sym, " | CRT Bearish");
      return -1;
   }
   return 0;
}

//------------------- REJECTION BLOCK --------------------------------
int DetectRejectionBlock(string sym, int trend)
{
   double open1  = iOpen(sym, EntryTF, 1);
   double close1 = iClose(sym, EntryTF, 1);
   double high1  = iHigh(sym, EntryTF, 1);
   double low1   = iLow(sym, EntryTF, 1);

   double body = MathAbs(close1 - open1);
   double upperWick = high1 - MathMax(open1, close1);
   double lowerWick = MathMin(open1, close1) - low1;

   if(trend == 1 && lowerWick > body * 1.5 && lowerWick > upperWick)
   {
      Print(sym, " | Rejection Block Bullish");
      return 1;
   }
   if(trend == -1 && upperWick > body * 1.5 && upperWick > lowerWick)
   {
      Print(sym, " | Rejection Block Bearish");
      return -1;
   }
   return 0;
}

//------------------- ORDER BLOCK (Simplified) -----------------------
int DetectOrderBlock(string sym, int trend)
{
   double close1 = iClose(sym, EntryTF, 1);
   double close2 = iClose(sym, EntryTF, 2);
   double close3 = iClose(sym, EntryTF, 3);

   if(trend == 1 && close2 < close3 && close1 > close2 && (close1 - close2) > (close3 - close2) * 1.2)
   {
      Print(sym, " | Order Block Bullish");
      return 1;
   }
   if(trend == -1 && close2 > close3 && close1 < close2 && (close2 - close1) > (close2 - close3) * 1.2)
   {
      Print(sym, " | Order Block Bearish");
      return -1;
   }
   return 0;
}

//------------------- OPEN TRADE -------------------------------------
void OpenTrade(string sym, int signal)
{
   double atr = iATR(sym, EntryTF, 14, 1);
   if(atr <= 0) return;

   double slDistance = atr * 1.5;
   double tpDistance = slDistance * RR_Ratio;

   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double point     = SymbolInfoDouble(sym, SYMBOL_POINT);

   if(tickValue <= 0 || point <= 0) return;

   double slPoints = slDistance / point;
   double lot = RiskMoney / (slPoints * tickValue / tickSize);
   lot = NormalizeLot(sym, lot);

   if(lot < SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN)) return;

   double price, sl, tp;

   if(signal == 1)
   {
      price = SymbolInfoDouble(sym, SYMBOL_ASK);
      sl = price - slDistance;
      tp = price + tpDistance;
      trade.Buy(lot, sym, price, sl, tp, "SMC Buy");
   }
   else
   {
      price = SymbolInfoDouble(sym, SYMBOL_BID);
      sl = price + slDistance;
      tp = price - tpDistance;
      trade.Sell(lot, sym, price, sl, tp, "SMC Sell");
   }
}

//------------------- HELPERS ----------------------------------------
double NormalizeLot(string sym, double lot)
{
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return NormalizeDouble(lot, 2);
}

int CountPositionsOnSymbol(string sym)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == sym && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
   }
   return count;
}

int CountAllOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
   }
   return count;
}

bool CheckDailyLossLimit()
{
   MqlDateTime now, start;
   TimeToStruct(TimeCurrent(), now);
   TimeToStruct(dailyStartDate, start);

   if(now.day != start.day || now.mon != start.mon)
   {
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyStartDate = TimeCurrent();
   }

   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double lossPercent = (dailyStartBalance - currentBalance) / dailyStartBalance * 100.0;

   if(lossPercent >= DailyLossLimitPercent)
   {
      Print("Daily loss limit reached. Trading paused.");
      return false;
   }
   return true;
}

void OnDeinit(const int reason)
{
   Print("DerivSMC_EA Multi-Pair removed");
}
//+------------------------------------------------------------------+