//+------------------------------------------------------------------+
//|                                                  DerivSMC_EA.mq5 |
//|  Multi-Pair | CRT + Rejection + OrderBlock | Trailing + BE       |
//|  Works on Synthetics + Gold + Forex | Fixed $ Risk               |
//|  v1.23: market structure on setup TF, M1 market-entry timing     |
//+------------------------------------------------------------------+
#property copyright "Dave-4u"
#property link      "https://github.com/Dave-4u/Deriv-SMC-EA"
#property version   "1.23"
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
input ENUM_TIMEFRAMES EntryTF        = PERIOD_M5;  // Setup timeframe (strategies + structure)
input ENUM_TIMEFRAMES ExecTF         = PERIOD_M1;  // Timing chart for market entry

input group "=== TREND & STRUCTURE ==="
input int      EMA_Period            = 50;
input int      CooldownBars          = 12;
input bool     UseMarketStructure    = true;       // Require setup-TF structure to agree with trend
input int      StructureLookback     = 50;         // Bars on EntryTF to read swings
input int      SwingStrength         = 2;          // Pivot bars on each side

input group "=== M1 ENTRY TIMING ==="
input bool     UseM1EntryTiming      = true;       // If false, enter at market when the setup appears
input int      SetupExpireM1Bars     = 15;         // Pending setup dies after this many new M1 bars

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
   datetime lastExecBar;
   int      cooldown;
   int      atrHandle;
   int      emaHandle;
   int      pendingSignal;
   int      pendingAgeM1;
};

SymbolData symbols[];
int        symbolCount = 0;
double     dailyStartBalance = 0;
datetime   dailyStartDate = 0;

//------------------- INITIALIZATION ---------------------------------
int OnInit()
{
   // Parse main symbols list (keep spaces inside names; trim only around commas)
   string baseSymbols[];
   int baseCount = StringSplit(SymbolsList, ',', baseSymbols);
   for(int i = 0; i < baseCount; i++)
   {
      StringTrimLeft(baseSymbols[i]);
      StringTrimRight(baseSymbols[i]);
   }

   string customPairs[];
   int customCount = 0;
   if(StringLen(CustomRiskList) > 0)
   {
      customCount = StringSplit(CustomRiskList, ',', customPairs);
      for(int c = 0; c < customCount; c++)
      {
         StringTrimLeft(customPairs[c]);
         StringTrimRight(customPairs[c]);
      }
   }

   ArrayResize(symbols, baseCount);
   symbolCount = 0;

   for(int i = 0; i < baseCount; i++)
   {
      if(StringLen(baseSymbols[i]) < 2) continue;

      if(!SymbolSelect(baseSymbols[i], true))
      {
         Print("Symbol not found: ", baseSymbols[i]);
         continue;
      }

      symbols[symbolCount].name = baseSymbols[i];
      symbols[symbolCount].risk = RiskMoney;
      symbols[symbolCount].lastBar = 0;
      symbols[symbolCount].lastExecBar = 0;
      symbols[symbolCount].cooldown = 0;
      symbols[symbolCount].atrHandle = INVALID_HANDLE;
      symbols[symbolCount].emaHandle = INVALID_HANDLE;
      symbols[symbolCount].pendingSignal = 0;
      symbols[symbolCount].pendingAgeM1 = 0;

      for(int c = 0; c < customCount; c++)
      {
         string parts[];
         if(StringSplit(customPairs[c], ':', parts) == 2)
         {
            StringTrimLeft(parts[0]);
            StringTrimRight(parts[0]);
            StringTrimLeft(parts[1]);
            StringTrimRight(parts[1]);
            if(parts[0] == baseSymbols[i])
            {
               symbols[symbolCount].risk = StringToDouble(parts[1]);
               break;
            }
         }
      }

      int atrHandle = iATR(baseSymbols[i], EntryTF, 14);
      int emaHandle = iMA(baseSymbols[i], TrendTF, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);

      if(atrHandle == INVALID_HANDLE || emaHandle == INVALID_HANDLE)
      {
         Print("Failed to create handles for ", baseSymbols[i]);
         if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
         if(emaHandle != INVALID_HANDLE) IndicatorRelease(emaHandle);
         continue;
      }

      symbols[symbolCount].atrHandle = atrHandle;
      symbols[symbolCount].emaHandle = emaHandle;
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

   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyStartDate = TimeCurrent();

   Print("=== DerivSMC_EA v1.23 Started ===");
   Print("Symbols loaded: ", symbolCount,
         " | Structure=", UseMarketStructure,
         " | M1 timing=", UseM1EntryTiming);
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
   ManageOpenPositions();

   if(!CheckDailyLossLimit()) return;
   if(UseNewsFilter && IsNewsTime()) return;

   for(int i = 0; i < symbolCount; i++)
   {
      string sym = symbols[i].name;
      if(!SymbolSelect(sym, true)) continue;

      // Time a pending setup on each newly formed ExecTF (M1) bar
      datetime execBar = iTime(sym, ExecTF, 0);
      if(execBar != 0 && execBar != symbols[i].lastExecBar)
      {
         symbols[i].lastExecBar = execBar;
         TryTimedEntry(i);
      }

      datetime barTime = iTime(sym, EntryTF, 0);
      if(barTime == 0 || barTime == symbols[i].lastBar) continue;
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
         ClearPending(i);
         continue;
      }

      if(UseMarketStructure)
      {
         int structure = GetMarketStructure(sym);
         if(structure == 0 || structure != trend)
         {
            ClearPending(i);
            continue; // skip this setup bar only, no long cooldown
         }
      }

      int signal = 0;
      if(EnableCRT)            signal = DetectCRT(sym, trend);
      if(signal == 0 && EnableRejectionBlock) signal = DetectRejectionBlock(sym, trend);
      if(signal == 0 && EnableOrderBlock)     signal = DetectOrderBlock(sym, trend);

      if(signal == 0)
      {
         ClearPending(i);
         continue;
      }

      if(CountAllOpenPositions() >= MaxOpenTrades) continue;
      if(CountPositionsOnSymbol(sym) != 0)
      {
         ClearPending(i);
         continue;
      }

      if(!UseM1EntryTiming)
      {
         OpenTrade(i, signal);
         continue;
      }

      symbols[i].pendingSignal = signal;
      symbols[i].pendingAgeM1  = 0;
      Print(sym, " setup ", (signal == 1 ? "BUY" : "SELL"),
            " on ", EnumToString(EntryTF),
            " — waiting for ", EnumToString(ExecTF), " confirmation");
   }
}

void ClearPending(int idx)
{
   symbols[idx].pendingSignal = 0;
   symbols[idx].pendingAgeM1  = 0;
}

void TryTimedEntry(int idx)
{
   if(symbols[idx].pendingSignal == 0) return;

   symbols[idx].pendingAgeM1++;
   if(symbols[idx].pendingAgeM1 > SetupExpireM1Bars)
   {
      Print(symbols[idx].name, " pending setup expired after ",
            SetupExpireM1Bars, " ", EnumToString(ExecTF), " bars");
      ClearPending(idx);
      return;
   }

   if(CountAllOpenPositions() >= MaxOpenTrades) return;
   if(CountPositionsOnSymbol(symbols[idx].name) != 0)
   {
      ClearPending(idx);
      return;
   }

   // Confirm on the last closed ExecTF bar (shift 1), never the forming bar
   if(!ExecBarConfirms(symbols[idx].name, symbols[idx].pendingSignal))
      return;

   int signal = symbols[idx].pendingSignal;
   ClearPending(idx);
   OpenTrade(idx, signal);
}

// Simple directional close that also takes the prior bar's high/low
bool ExecBarConfirms(string sym, int signal)
{
   double open1  = iOpen(sym, ExecTF, 1);
   double close1 = iClose(sym, ExecTF, 1);
   double high2  = iHigh(sym, ExecTF, 2);
   double low2   = iLow(sym, ExecTF, 2);
   if(open1 <= 0 || close1 <= 0 || high2 <= 0 || low2 <= 0) return false;

   if(signal == 1)
      return (close1 > open1 && close1 > high2);
   if(signal == -1)
      return (close1 < open1 && close1 < low2);
   return false;
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

//------------------- MARKET STRUCTURE (setup TF swings) -------------
bool IsSwingHigh(string sym, int shift, int strength)
{
   double h = iHigh(sym, EntryTF, shift);
   if(h <= 0) return false;
   for(int i = 1; i <= strength; i++)
   {
      if(iHigh(sym, EntryTF, shift + i) >= h) return false;
      if(iHigh(sym, EntryTF, shift - i) >= h) return false;
   }
   return true;
}

bool IsSwingLow(string sym, int shift, int strength)
{
   double l = iLow(sym, EntryTF, shift);
   if(l <= 0) return false;
   for(int i = 1; i <= strength; i++)
   {
      if(iLow(sym, EntryTF, shift + i) <= l) return false;
      if(iLow(sym, EntryTF, shift - i) <= l) return false;
   }
   return true;
}

// 1 = HH or HL (bullish), -1 = LH or LL (bearish), 0 = unclear
int GetMarketStructure(string sym)
{
   int strength = SwingStrength;
   if(strength < 1) strength = 1;
   int lookback = StructureLookback;
   if(lookback < strength * 4 + 5) lookback = strength * 4 + 5;

   double high1 = 0, high2 = 0, low1 = 0, low2 = 0;
   datetime timeHigh1 = 0, timeLow1 = 0;
   int highs = 0, lows = 0;

   // Closed bars only: from 'strength' so the right side of the pivot is complete
   for(int shift = strength; shift <= lookback; shift++)
   {
      if(highs < 2 && IsSwingHigh(sym, shift, strength))
      {
         double h = iHigh(sym, EntryTF, shift);
         datetime t = iTime(sym, EntryTF, shift);
         if(highs == 0) { high1 = h; timeHigh1 = t; }
         else             high2 = h;
         highs++;
      }
      if(lows < 2 && IsSwingLow(sym, shift, strength))
      {
         double l = iLow(sym, EntryTF, shift);
         datetime t = iTime(sym, EntryTF, shift);
         if(lows == 0) { low1 = l; timeLow1 = t; }
         else            low2 = l;
         lows++;
      }
      if(highs >= 2 && lows >= 2) break;
   }

   bool hh = (highs >= 2 && high1 > high2);
   bool lh = (highs >= 2 && high1 < high2);
   bool hl = (lows  >= 2 && low1  > low2);
   bool ll = (lows  >= 2 && low1  < low2);

   if((hh || hl) && !lh && !ll) return 1;
   if((lh || ll) && !hh && !hl) return -1;

   // Expanding or mixed range: use the most recent swing
   if((hh || hl) && (lh || ll))
   {
      if(timeHigh1 >= timeLow1)
         return (hh ? 1 : -1);
      return (hl ? 1 : -1);
   }
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

//------------------- FILLING MODE -----------------------------------
bool SetFillingForSymbol(string sym)
{
   uint mode = (uint)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((mode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((mode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
   return true;
}

double MoneyToPriceDistance(string sym, double lot, double money)
{
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0 || lot <= 0) return 0;
   return money * tickSize / (tickValue * lot);
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
   if(tickValue <= 0 || tickSize <= 0) return;

   double lot = risk / ((slDistance / tickSize) * tickValue);
   lot = NormalizeLot(sym, lot);
   if(lot < SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN)) return;

   SetFillingForSymbol(sym);

   double price, sl, tp;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   if(signal == 1)
   {
      price = SymbolInfoDouble(sym, SYMBOL_ASK);
      sl = NormalizeDouble(price - slDistance, digits);
      tp = NormalizeDouble(price + tpDistance, digits);
      if(trade.Buy(lot, sym, price, sl, tp, "SMC Buy"))
         Print(sym, " market BUY lot ", lot);
   }
   else
   {
      price = SymbolInfoDouble(sym, SYMBOL_BID);
      sl = NormalizeDouble(price + slDistance, digits);
      tp = NormalizeDouble(price - tpDistance, digits);
      if(trade.Sell(lot, sym, price, sl, tp, "SMC Sell"))
         Print(sym, " market SELL lot ", lot);
   }
}

//------------------- MANAGE OPEN POSITIONS (Trailing + BE) ----------
void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      long   type = PositionGetInteger(POSITION_TYPE);
      double profit = PositionGetDouble(POSITION_PROFIT);
      double lot = PositionGetDouble(POSITION_VOLUME);

      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

      if(UseBreakEven && profit >= BreakEvenTrigger)
      {
         double beOffset = MoneyToPriceDistance(sym, lot, BreakEvenProfit);
         if(beOffset > 0)
         {
            if(type == POSITION_TYPE_BUY)
            {
               double bePrice = NormalizeDouble(openPrice + beOffset, digits);
               if(currentSL < bePrice && bePrice < bid)
               {
                  if(trade.PositionModify(ticket, bePrice, currentTP))
                     currentSL = bePrice;
               }
            }
            else
            {
               double bePrice = NormalizeDouble(openPrice - beOffset, digits);
               if((currentSL > bePrice || currentSL == 0) && bePrice > ask)
               {
                  if(trade.PositionModify(ticket, bePrice, currentTP))
                     currentSL = bePrice;
               }
            }
         }
      }

      if(UseTrailingStop && profit >= TrailingStart)
      {
         double trailDist = MoneyToPriceDistance(sym, lot, TrailingStep);
         if(trailDist > 0)
         {
            if(type == POSITION_TYPE_BUY)
            {
               double newSL = NormalizeDouble(bid - trailDist, digits);
               if(newSL > currentSL && newSL < bid)
                  trade.PositionModify(ticket, newSL, currentTP);
            }
            else
            {
               double newSL = NormalizeDouble(ask + trailDist, digits);
               if((newSL < currentSL || currentSL == 0) && newSL > ask)
                  trade.PositionModify(ticket, newSL, currentTP);
            }
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

   if(step <= 0) return 0;
   lot = MathFloor(lot / step) * step;
   if(lot < minLot) return 0;
   if(lot > maxLot) lot = maxLot;
   return NormalizeDouble(lot, 2);
}

int CountPositionsOnSymbol(string sym)
{
   int count = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) == sym && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
   }
   return count;
}

int CountAllOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
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

   if(dailyStartBalance <= 0) return true;

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
   return false;
}
//+------------------------------------------------------------------+
