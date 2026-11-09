//+------------------------------------------------------------------+
//|                                                  DerivSMC_EA.mq5 |
//|  Multi-Pair | CRT + Rejection + OrderBlock | Trailing + BE       |
//|  Works on Synthetics + Gold + Forex | Fixed $ Risk               |
//+------------------------------------------------------------------+
#property copyright "Dave-4u"
#property link      "https://github.com/Dave-4u/Deriv-SMC-EA"
#property version   "1.20"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//------------------- INPUTS ----------------------------------------
input group "=== MULTI-PAIR & RISK ==="
input string   SymbolsList           = "Volatility 75 Index,Volatility 100 Index,Boom 1000 Index,Crash 500 Index,XAUUSD"; 
input double   RiskMoney             = 3.0;        // Default risk in $
input int      MaxOpenTrades         = 10;
input string   CustomRiskList        = "";         // Optional: Symbol:Risk,Symbol:Risk (e.g. XAUUSD:5,Volatility 75 Index:2.5)

input group "=== PROTECTION ==="
input double   DailyLossLimitPercent = 3.0;
input int      MagicNumber           = 20261109;
input int      MaxSpreadPoints       = 150;

input group "=== STRATEGY SWITCHES ==="
input bool     EnableCRT             = true;
input bool     EnableRejectionBlock  = true;
input bool     EnableOrderBlock      = true;

input group "=== TIMEFRAMES ==="
input ENUM_TIMEFRAMES TrendTF        = PERIOD_H1;
input ENUM_TIMEFRAMES EntryTF        = PERIOD_M5;

input group "=== TREND FILTER ==="
input int      EMA_Period            = 50;
input int      CooldownBars          = 12;

input group "=== TRADE MANAGEMENT ==="
input double   RR_Ratio              = 2.0;
input int      Slippage              = 30;

input group "=== TRAILING STOP ==="
input bool     UseTrailingStop       = true;
input double   TrailingStart         = 1.0;        // Start trailing after this profit ($)
input double   TrailingStep          = 0.5;        // Trail distance ($)

input group "=== BREAK-EVEN ==="
input bool     UseBreakEven          = true;
input double   BreakEvenTrigger      = 1.5;        // Move to BE after this profit ($)
input double   BreakEvenProfit       = 0.2;        // Lock this profit ($)

input group "=== NEWS FILTER (Optional) ==="
input bool     UseNewsFilter         = false;
input int      NewsMinutesBefore     = 30;
input int      NewsMinutesAfter      = 30;

//------------------- STRUCTURES & GLOBALS ---------------------------
struct SymbolData
{
   string   name;
   double   risk;
   datetime lastBar;
   int      cooldown;
   int      atrHandle;
   int      emaHandle;
};

SymbolData symbols[];
int        symbolCount = 0;
double     dailyStartBalance = 0;
datetime   dailyStartDate = 0;

//------------------- INITIALIZATION ---------------------------------
int OnInit()
{
   // Parse main symbols list
   string temp = SymbolsList;
   StringReplace(temp, " ", "");
   string baseSymbols[];
   int baseCount = StringSplit(temp, ',', baseSymbols);

   // Parse custom risk list
   string customPairs[];
   int customCount = 0;
   if(StringLen(CustomRiskList) > 0)
   {
      string cr = CustomRiskList;
      StringReplace(cr, " ", "");
      customCount = StringSplit(cr, ',', customPairs);
   }

   ArrayResize(symbols, baseCount);
   symbolCount = 0;

   for(int i = 0; i < baseCount; i++)
   {
      if(StringLen(baseSymbols[i]) < 2) continue;

      symbols[symbolCount].name = baseSymbols[i];
      symbols[symbolCount].risk = RiskMoney;          // default
      symbols[symbolCount].lastBar = 0;
      symbols[symbolCount].cooldown = 0;

      // Check if custom risk exists for this symbol
      for(int c = 0; c < customCount; c++)
      {
         string parts[];
         if(StringSplit(customPairs[c], ':', parts) == 2)
         {
            if(parts[0] == baseSymbols[i])
            {
               symbols[symbolCount].risk = StringToDouble(parts[1]);
               break;
            }
         }
      }

      // Create indicator handles
      symbols[symbolCount].atrHandle = iATR(baseSymbols[i], EntryTF, 14);
      symbols[symbolCount].emaHandle = iMA(baseSymbols[i], TrendTF, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);

      if(symbols[symbolCount].atrHandle == INVALID_HANDLE || symbols[symbolCount].emaHandle == INVALID_HANDLE)
      {
         Print("Failed to create handles for ", baseSymbols[i]);
         continue;
      }

      symbolCount++;
   }

   ArrayResize(symbols, symbolCount);

   if(symbolCount == 0)
   {
      Print("ERROR: No valid symbols!");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyStartDate = TimeCurrent();

   Print("=== DerivSMC_EA v1.2 Started ===");
   Print("Symbols loaded: ", symbolCount);
   for(int i=0; i<symbolCount; i++)
      Print("  → ", symbols[i].name, " | Risk: $", symbols[i].risk);

   return INIT_SUCCEEDED;
}

//------------------- DEINIT -----------------------------------------
void OnDeinit(const int reason)
{
   for(int i=0; i<symbolCount; i++)
   {
      if(symbols[i].atrHandle != INVALID_HANDLE) IndicatorRelease(symbols[i].atrHandle);
      if(symbols[i].emaHandle != INVALID_HANDLE) IndicatorRelease(symbols[i].emaHandle);
   }
   Print("DerivSMC_EA removed");
}

//------------------- MAIN TICK --------------------------------------
void OnTick()
{
   ManageOpenPositions();               // Trailing + Break-even first

   if(!CheckDailyLossLimit()) return;
   if(CountAllOpenPositions() >= MaxOpenTrades) return;
   if(UseNewsFilter && IsNewsTime()) return;

   for(int i = 0; i < symbolCount; i++)
   {
      string sym = symbols[i].name;

      if(!SymbolSelect(sym, true)) continue;

      datetime barTime = iTime(sym, EntryTF, 0);
      if(barTime == symbols[i].lastBar) continue;
      symbols[i].lastBar = barTime;

      if(symbols[i].cooldown > 0)
      {
         symbols[i].cooldown--;
         continue;
      }

      long spread = SymbolInfoInteger(sym, SYMBOL_SPREAD);
      if(spread > MaxSpreadPoints) continue;

      int trend = GetTrendDirection(i);
      if(trend == 0)
      {
         symbols[i].cooldown = CooldownBars;
         continue;
      }

      int signal = 0;

      if(EnableCRT)            signal = DetectCRT(sym, trend);
      if(signal == 0 && EnableRejectionBlock) signal = DetectRejectionBlock(sym, trend);
      if(signal == 0 && EnableOrderBlock)     signal = DetectOrderBlock(sym, trend);

      if(signal != 0 && CountPositionsOnSymbol(sym) == 0)
         OpenTrade(i, signal);
   }
}

//------------------- TREND FILTER -----------------------------------
int GetTrendDirection(int idx)
{
   double ema[];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(symbols[idx].emaHandle, 0, 0, 3, ema) < 3) return 0;

   double close1 = iClose(symbols[idx].name, TrendTF, 1);
   double close2 = iClose(symbols[idx].name, TrendTF, 2);

   if(close1 > ema[1] && close1 > close2) return 1;
   if(close1 < ema[1] && close1 < close2) return -1;
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
      return 1;
   if(trend == -1 && high2 > high1 && close2 < high1 && close2 > low1)
      return -1;
   return 0;
}

//------------------- REJECTION BLOCK --------------------------------
int DetectRejectionBlock(string sym, int trend)
{
   double open1  = iOpen(sym, EntryTF, 1);
   double close1 = iClose(sym, EntryTF, 1);
   double high1  = iHigh(sym, EntryTF, 1);
   double low1   = iLow(sym, EntryTF, 1);

   double body      = MathAbs(close1 - open1);
   double upperWick = high1 - MathMax(open1, close1);
   double lowerWick = MathMin(open1, close1) - low1;

   if(trend == 1 && lowerWick > body * 1.5 && lowerWick > upperWick) return 1;
   if(trend == -1 && upperWick > body * 1.5 && upperWick > lowerWick) return -1;
   return 0;
}

//------------------- ORDER BLOCK ------------------------------------
int DetectOrderBlock(string sym, int trend)
{
   double c1 = iClose(sym, EntryTF, 1);
   double c2 = iClose(sym, EntryTF, 2);
   double c3 = iClose(sym, EntryTF, 3);

   if(trend == 1 && c2 < c3 && c1 > c2 && (c1-c2) > (c3-c2)*1.2) return 1;
   if(trend == -1 && c2 > c3 && c1 < c2 && (c2-c1) > (c2-c3)*1.2) return -1;
   return 0;
}

//------------------- OPEN TRADE -------------------------------------
void OpenTrade(int idx, int signal)
{
   string sym = symbols[idx].name;
   double risk = symbols[idx].risk;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(symbols[idx].atrHandle, 0, 1, 1, atr) < 1) return;
   if(atr[0] <= 0) return;

   double slDistance = atr[0] * 1.5;
   double tpDistance = slDistance * RR_Ratio;

   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double point     = SymbolInfoDouble(sym, SYMBOL_POINT);

   if(tickValue <= 0 || point <= 0) return;

   double slPoints = slDistance / point;
   double lot = risk / (slPoints * tickValue / tickSize);
   lot = NormalizeLot(sym, lot);

   if(lot < SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN)) return;

   double price, sl, tp;

   if(signal == 1)
   {
      price = SymbolInfoDouble(sym, SYMBOL_ASK);
      sl = NormalizeDouble(price - slDistance, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
      tp = NormalizeDouble(price + tpDistance, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
      trade.Buy(lot, sym, price, sl, tp, "SMC Buy");
   }
   else
   {
      price = SymbolInfoDouble(sym, SYMBOL_BID);
      sl = NormalizeDouble(price + slDistance, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
      tp = NormalizeDouble(price - tpDistance, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
      trade.Sell(lot, sym, price, sl, tp, "SMC Sell");
   }
}

//------------------- MANAGE OPEN POSITIONS (Trailing + BE) ----------
void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      long   type = PositionGetInteger(POSITION_TYPE);
      double profit = PositionGetDouble(POSITION_PROFIT);

      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

      // --- Break-even ---
      if(UseBreakEven && profit >= BreakEvenTrigger)
      {
         double bePrice;
         if(type == POSITION_TYPE_BUY)
         {
            bePrice = NormalizeDouble(openPrice + BreakEvenProfit, digits);
            if(currentSL < bePrice)
               trade.PositionModify(PositionGetTicket(i), bePrice, currentTP);
         }
         else
         {
            bePrice = NormalizeDouble(openPrice - BreakEvenProfit, digits);
            if(currentSL > bePrice || currentSL == 0)
               trade.PositionModify(PositionGetTicket(i), bePrice, currentTP);
         }
      }

      // --- Trailing Stop ---
      if(UseTrailingStop && profit >= TrailingStart)
      {
         if(type == POSITION_TYPE_BUY)
         {
            double newSL = NormalizeDouble(bid - TrailingStep, digits);
            if(newSL > currentSL && newSL < bid)
               trade.PositionModify(PositionGetTicket(i), newSL, currentTP);
         }
         else
         {
            double newSL = NormalizeDouble(ask + TrailingStep, digits);
            if((newSL < currentSL || currentSL == 0) && newSL > ask)
               trade.PositionModify(PositionGetTicket(i), newSL, currentTP);
         }
      }
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
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == sym && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
   }
   return count;
}

int CountAllOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
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

   double loss = (dailyStartBalance - AccountInfoDouble(ACCOUNT_BALANCE)) / dailyStartBalance * 100.0;
   if(loss >= DailyLossLimitPercent)
   {
      Print("Daily loss limit hit. Trading stopped for today.");
      return false;
   }
   return true;
}

bool IsNewsTime()
{
   // Simple placeholder - can be expanded with economic calendar later
   // For now returns false when filter is enabled (safe default)
   return false;
}
//+------------------------------------------------------------------+