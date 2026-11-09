//+------------------------------------------------------------------+
//|                                                  DerivSMC_EA.mq5 |
//|                        Order Block + Rejection Block + CRT       |
//|                     with H1 Trend Filter (Small Account Ready)   |
//+------------------------------------------------------------------+
#property copyright "Dave-4u / Grok"
#property link      "https://github.com/Dave-4u/Deriv-SMC-EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//------------------- INPUTS ----------------------------------------
input group "=== Risk Management (Small Account) ==="
input double   RiskPercent           = 0.75;    // Risk per trade (% of balance)
input double   DailyLossLimitPercent = 3.0;     // Max daily loss %
input int      MagicNumber           = 20261109;
input int      MaxSpreadPoints       = 80;      // Max allowed spread

input group "=== Strategy Switches ==="
input bool     EnableCRT             = true;
input bool     EnableRejectionBlock  = true;
input bool     EnableOrderBlock      = true;

input group "=== Timeframes ==="
input ENUM_TIMEFRAMES TrendTF        = PERIOD_H1;  // Trend filter timeframe
input ENUM_TIMEFRAMES EntryTF        = PERIOD_M5;  // Setup timeframe

input group "=== Trend Filter ==="
input int      EMA_Period            = 50;         // EMA period for trend
input int      CooldownBars          = 12;         // Bars to skip when misaligned

input group "=== Trade Management ==="
input double   RR_Ratio              = 2.0;        // Risk : Reward
input int      Slippage              = 30;

//------------------- GLOBALS ----------------------------------------
datetime lastBarTime = 0;
int      cooldownCounter = 0;
double   dailyStartBalance = 0;
datetime dailyStartDate = 0;

//------------------- INITIALIZATION ---------------------------------
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyStartDate = TimeCurrent();
   
   Print("DerivSMC_EA initialized | Risk: ", RiskPercent, "% | Magic: ", MagicNumber);
   return(INIT_SUCCEEDED);
}

//------------------- MAIN LOGIC -------------------------------------
void OnTick()
{
   // New bar check on EntryTF
   datetime currentBar = iTime(_Symbol, EntryTF, 0);
   if(currentBar == lastBarTime) return;
   lastBarTime = currentBar;

   // Daily loss protection
   if(!CheckDailyLossLimit()) return;

   // Cooldown
   if(cooldownCounter > 0)
   {
      cooldownCounter--;
      return;
   }

   // Spread filter
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpreadPoints) return;

   // === TREND FILTER ===
   int trend = GetTrendDirection();   // 1 = Bullish, -1 = Bearish, 0 = Neutral
   if(trend == 0) return;

   // === SCAN SETUPS (Priority order) ===
   int signal = 0;   // 1 = Buy, -1 = Sell

   if(EnableCRT)
      signal = DetectCRT(trend);

   if(signal == 0 && EnableRejectionBlock)
      signal = DetectRejectionBlock(trend);

   if(signal == 0 && EnableOrderBlock)
      signal = DetectOrderBlock(trend);

   // Execute if we have a valid aligned signal
   if(signal != 0)
   {
      if(CountOpenPositions() == 0)   // only one position at a time for small accounts
         OpenTrade(signal);
   }
}

//------------------- TREND FILTER (H1) -------------------------------
int GetTrendDirection()
{
   double ema[];
   ArraySetAsSeries(ema, true);
   int handle = iMA(_Symbol, TrendTF, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   if(CopyBuffer(handle, 0, 0, 3, ema) < 3) return 0;

   double close1 = iClose(_Symbol, TrendTF, 1);
   double close2 = iClose(_Symbol, TrendTF, 2);

   // Simple structure + EMA
   bool bullishStructure = close1 > close2;
   bool bearishStructure = close1 < close2;

   if(close1 > ema[1] && bullishStructure) return 1;   // Bullish
   if(close1 < ema[1] && bearishStructure) return -1;  // Bearish

   return 0; // Neutral
}

//------------------- CRT DETECTION ----------------------------------
int DetectCRT(int trend)
{
   // Candle 1 = range, Candle 2 = sweep, we act on close of candle 2
   double high1 = iHigh(_Symbol, EntryTF, 2);
   double low1  = iLow(_Symbol, EntryTF, 2);
   double high2 = iHigh(_Symbol, EntryTF, 1);
   double low2  = iLow(_Symbol, EntryTF, 1);
   double close2= iClose(_Symbol, EntryTF, 1);

   // Bullish CRT: swept low of candle 1 and closed back inside
   if(trend == 1 && low2 < low1 && close2 > low1 && close2 < high1)
   {
      Print("CRT Bullish detected");
      return 1;
   }

   // Bearish CRT: swept high of candle 1 and closed back inside
   if(trend == -1 && high2 > high1 && close2 < high1 && close2 > low1)
   {
      Print("CRT Bearish detected");
      return -1;
   }

   return 0;
}

//------------------- REJECTION BLOCK DETECTION ----------------------
int DetectRejectionBlock(int trend)
{
   double open1  = iOpen(_Symbol, EntryTF, 1);
   double close1 = iClose(_Symbol, EntryTF, 1);
   double high1  = iHigh(_Symbol, EntryTF, 1);
   double low1   = iLow(_Symbol, EntryTF, 1);

   double body = MathAbs(close1 - open1);
   double upperWick = high1 - MathMax(open1, close1);
   double lowerWick = MathMin(open1, close1) - low1;

   // Bullish Rejection (long lower wick)
   if(trend == 1 && lowerWick > body * 1.5 && lowerWick > upperWick)
   {
      Print("Rejection Block Bullish detected");
      return 1;
   }

   // Bearish Rejection (long upper wick)
   if(trend == -1 && upperWick > body * 1.5 && upperWick > lowerWick)
   {
      Print("Rejection Block Bearish detected");
      return -1;
   }

   return 0;
}

//------------------- ORDER BLOCK DETECTION (Simplified) -------------
int DetectOrderBlock(int trend)
{
   // Very simplified version for reliability on synthetics
   // Looks for last opposing candle before strong move

   double close1 = iClose(_Symbol, EntryTF, 1);
   double close2 = iClose(_Symbol, EntryTF, 2);
   double close3 = iClose(_Symbol, EntryTF, 3);

   // Bullish OB approximation: strong up move after down candle
   if(trend == 1 && close2 < close3 && close1 > close2 && (close1 - close2) > (close3 - close2) * 1.2)
   {
      Print("Order Block Bullish detected");
      return 1;
   }

   // Bearish OB approximation
   if(trend == -1 && close2 > close3 && close1 < close2 && (close2 - close1) > (close2 - close3) * 1.2)
   {
      Print("Order Block Bearish detected");
      return -1;
   }

   return 0;
}

//------------------- TRADE EXECUTION --------------------------------
void OpenTrade(int signal)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * RiskPercent / 100.0;

   double atr = iATR(_Symbol, EntryTF, 14, 1);
   if(atr <= 0) return;

   double slDistance = atr * 1.5;          // SL = 1.5 ATR
   double tpDistance = slDistance * RR_Ratio;

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double slPoints = slDistance / point;
   double lot = riskMoney / (slPoints * tickValue / tickSize);
   lot = NormalizeLot(lot);

   if(lot < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)) return;

   double price, sl, tp;

   if(signal == 1) // Buy
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = price - slDistance;
      tp = price + tpDistance;
      trade.Buy(lot, _Symbol, price, sl, tp, "SMC Buy");
   }
   else // Sell
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = price + slDistance;
      tp = price - tpDistance;
      trade.Sell(lot, _Symbol, price, sl, tp, "SMC Sell");
   }
}

//------------------- HELPERS ----------------------------------------
double NormalizeLot(double lot)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return NormalizeDouble(lot, 2);
}

int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
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
      Print("Daily loss limit reached. Trading paused until tomorrow.");
      return false;
   }
   return true;
}

void OnDeinit(const int reason)
{
   Print("DerivSMC_EA removed");
}
//+------------------------------------------------------------------+