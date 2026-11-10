//+------------------------------------------------------------------+
//|                                                  DerivSMC_EA.mq5 |
//|  Multi-Pair | CRT + Rejection + OrderBlock | Trailing + BE       |
//|  Works on Synthetics + Gold + Forex | Fixed $ Risk               |
//|  v1.25: broker stop levels respected; trailing modify throttle  |
//+------------------------------------------------------------------+
#property copyright "Dave-4u"
#property link      "https://github.com/Dave-4u/Deriv-SMC-EA"
#property version   "1.25"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//------------------- INPUTS ----------------------------------------
input group "=== MULTI-PAIR & RISK ==="
input string   SymbolsList           = "Volatility 75 Index,Volatility 100 Index,Boom 1000 Index,Crash 500 Index,XAUUSD";
input bool     SymbolsFromFile       = true;       // Read names from a .txt in MQL5\\Files
input string   SymbolsFile           = "DaveSymbols.txt"; // one name per line or comma-separated, # = comment
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

input group "=== BROKER STOP LEVELS (v1.25) ==="
input double   StopsSpreadBuffer     = 1.0;        // Spreads added to the broker min stop distance
input int      ExtraStopBufferPoints = 0;          // Extra points added to the min stop distance
input int      InvalidStopsCooldownMin = 30;       // Pause a symbol this long after an [invalid stops] entry
input int      ModifyMinSeconds      = 3;          // Min seconds between SL modify attempts per ticket
input int      ModifyMaxBackoffSec   = 300;        // Max wait after repeated modify rejections
input double   TrailMinImproveMoney  = 0.10;       // Only move SL if it locks at least this much more ($)

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
   datetime blockedUntil;   // v1.25: cooldown after [invalid stops] on entry
   int      stopsFails;     // v1.25: consecutive [invalid stops] entry rejections
};

// v1.25: per-ticket SL modify throttle
struct ModifyState
{
   ulong    ticket;
   datetime nextAllowed;
   double   lastRejectedSL;
   int      fails;
};
ModifyState modStates[];

SymbolData symbols[];
int        symbolCount = 0;
double     dailyStartBalance = 0;
datetime   dailyStartDate = 0;


//------------------- SYMBOL FILE (MQL5\Files) -----------------------
void SymAddTokens(string line, string &out[])
{
   StringReplace(line, "\r", "");
   StringTrimLeft(line);
   StringTrimRight(line);
   if(StringLen(line) == 0 || StringGetCharacter(line, 0) == '#') return;
   string parts[];
   int k = StringSplit(line, ',', parts);
   for(int i = 0; i < k; i++)
   {
      string t = parts[i];
      StringTrimLeft(t);
      StringTrimRight(t);
      if(StringLen(t) == 0) continue;
      int sz = ArraySize(out);
      ArrayResize(out, sz + 1);
      out[sz] = t;
   }
}

int LoadSymbolsFile(string fname, string &out[])
{
   ArrayResize(out, 0);
   int h = FileOpen(fname, FILE_READ | FILE_BIN);
   if(h == INVALID_HANDLE)
   {
      Print("SYMBOLS cannot open ", fname, " err=", GetLastError());
      return 0;
   }
   uchar raw[];
   int len = (int)FileSize(h);
   if(len > 0) FileReadArray(h, raw, 0, len);
   FileClose(h);
   len = ArraySize(raw);
   if(len == 0) return 0;

   string text = "";
   if(len >= 2 && raw[0] == 0xFF && raw[1] == 0xFE)            // UTF-16 LE
   {
      for(int i = 2; i + 1 < len; i += 2)
      {
         ushort c = (ushort)(raw[i] | (raw[i + 1] << 8));
         text += ShortToString(c);
      }
   }
   else if(len >= 2 && raw[0] == 0xFE && raw[1] == 0xFF)       // UTF-16 BE
   {
      for(int i = 2; i + 1 < len; i += 2)
      {
         ushort c = (ushort)((raw[i] << 8) | raw[i + 1]);
         text += ShortToString(c);
      }
   }
   else
   {
      int start = (len >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF) ? 3 : 0;
      text = CharArrayToString(raw, start, len - start, CP_UTF8);
   }

   string lines[];
   int nl = StringSplit(text, '\n', lines);
   for(int i = 0; i < nl; i++)
      SymAddTokens(lines[i], out);
   return ArraySize(out);
}

//------------------- INITIALIZATION ---------------------------------
int OnInit()
{
   // Load symbols from MQL5\Files .txt when enabled; keep spaces in names
   string baseSymbols[];
   int baseCount = 0;
   if(SymbolsFromFile && StringLen(SymbolsFile) > 0)
   {
      baseCount = LoadSymbolsFile(SymbolsFile, baseSymbols);
      if(baseCount > 0)
         Print("SYMBOLS from file ", SymbolsFile, ": ", baseCount, " names");
      else
         Print("SYMBOLS file ", SymbolsFile, " missing/empty (put it in MQL5\\Files) - falling back to SymbolsList");
   }
   if(baseCount <= 0)
   {
      baseCount = StringSplit(SymbolsList, ',', baseSymbols);
      for(int i = 0; i < baseCount; i++)
      {
         StringTrimLeft(baseSymbols[i]);
         StringTrimRight(baseSymbols[i]);
      }
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
      symbols[symbolCount].blockedUntil = 0;
      symbols[symbolCount].stopsFails = 0;

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

   Print("=== DerivSMC_EA v1.25 Started ===");
   Print("Symbols loaded: ", symbolCount,
         " | from file=", (SymbolsFromFile ? SymbolsFile : "SymbolsList"),
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

      if(IsSymbolBlocked(i))
      {
         ClearPending(i);
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

bool IsSymbolBlocked(int idx)
{
   return (symbols[idx].blockedUntil > 0 && TimeCurrent() < symbols[idx].blockedUntil);
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

   if(IsSymbolBlocked(idx))
   {
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

//------------------- PRICE / STOP-LEVEL HELPERS (v1.25) --------------
double SymTickSize(string sym)
{
   double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0) ts = SymbolInfoDouble(sym, SYMBOL_POINT);
   return ts;
}

// Round a price to the symbol tick size. dir: -1 = down, 1 = up, 0 = nearest
double RoundToTick(string sym, double price, int dir)
{
   double ts = SymTickSize(sym);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   if(ts <= 0) return NormalizeDouble(price, digits);
   double n = price / ts;
   double r;
   if(dir < 0)      r = MathFloor(n + 1e-7);
   else if(dir > 0) r = MathCeil(n - 1e-7);
   else             r = MathRound(n);
   return NormalizeDouble(r * ts, digits);
}

// Min distance between price and SL/TP the broker will accept, plus a buffer
double MinStopDistance(string sym, double bid, double ask, int extraMult)
{
   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);
   long   stops  = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   long   freeze = SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   long   lvl    = (stops > freeze ? stops : freeze);
   double spread = ask - bid;
   if(spread < 0) spread = 0;

   double dist = (double)lvl * point
               + spread * StopsSpreadBuffer
               + (double)ExtraStopBufferPoints * point;
   if(extraMult > 1) dist *= extraMult;

   double minTicks = 2.0 * SymTickSize(sym);
   if(dist < minTicks) dist = minTicks;
   return dist;
}

// Money lost per 1.0 lot per 1.0 price unit (uses loss tick value when available)
double LossPerPriceUnit(string sym)
{
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tvLoss   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   double tv       = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double useTv    = (tvLoss > tv ? tvLoss : tv);   // the larger = the safer estimate
   if(tickSize <= 0 || useTv <= 0) return 0;
   return useTv / tickSize;
}

// Worst-case loss ($, positive) if 'lot' is filled at 'entry' (+ slippage) and stopped at 'sl'
double LossAtSL(string sym, int signal, double lot, double entry, double sl)
{
   double point    = SymbolInfoDouble(sym, SYMBOL_POINT);
   double slipDist = (double)Slippage * point;   // allowed fill deviation
   double worstEntry = (signal == 1 ? entry + slipDist : entry - slipDist);
   double dist = MathAbs(worstEntry - sl);

   double perUnit = LossPerPriceUnit(sym);
   double lossTv  = (perUnit > 0 ? dist * perUnit * lot : 0);

   double lossCalc = 0;
   double profit   = 0;
   ENUM_ORDER_TYPE ot = (signal == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(OrderCalcProfit(ot, sym, lot, worstEntry, sl, profit))
      lossCalc = MathAbs(profit);

   if(perUnit <= 0 && lossCalc <= 0) return -1;   // cannot measure -> caller skips
   return MathMax(lossTv, lossCalc);
}

//------------------- OPEN TRADE -------------------------------------
bool OpenTrade(int idx, int signal)
{
   string sym = symbols[idx].name;
   double risk = symbols[idx].risk;
   if(risk <= 0) return false;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(symbols[idx].atrHandle, 0, 1, 1, atr) < 1) return false;
   if(atr[0] <= 0) return false;

   MqlTick tick;
   if(!SymbolInfoTick(sym, tick) || tick.bid <= 0 || tick.ask <= 0) return false;
   double bid = tick.bid;
   double ask = tick.ask;

   double slDistance = atr[0] * 1.5;

   // Broker min distance (stops/freeze level + spread buffer); grows after rejections
   int mult = 1 + symbols[idx].stopsFails;
   if(mult > 4) mult = 4;
   double minDist = MinStopDistance(sym, bid, ask, mult);
   if(slDistance < minDist)
   {
      Print(sym, " SL ", DoubleToString(slDistance, 8), " inside broker min ",
            DoubleToString(minDist, 8), " - widening SL, lot is recomputed for $", risk);
      slDistance = minDist;
   }

   double price, sl, tp;
   if(signal == 1)
   {
      price = ask;
      sl = RoundToTick(sym, price - slDistance, -1);        // round away from price
      double slD = price - sl;
      double tpD = MathMax(slD * RR_Ratio, minDist);
      tp = RoundToTick(sym, price + tpD, 1);
      // Correct side checks (buy SL/TP are triggered by bid)
      if(sl > bid - minDist) sl = RoundToTick(sym, bid - minDist, -1);
      if(sl >= bid || tp <= ask) { Print(sym, " BUY skipped: stops on wrong side"); return false; }
   }
   else
   {
      price = bid;
      sl = RoundToTick(sym, price + slDistance, 1);
      double slD = sl - price;
      double tpD = MathMax(slD * RR_Ratio, minDist);
      tp = RoundToTick(sym, price - tpD, -1);
      // Sell SL/TP are triggered by ask
      if(sl < ask + minDist) sl = RoundToTick(sym, ask + minDist, 1);
      if(sl <= ask || tp >= bid || tp <= 0) { Print(sym, " SELL skipped: stops on wrong side"); return false; }
   }

   // ---- Lot from the FINAL stop, then hard-verify the $ loss ----
   double perUnit = LossPerPriceUnit(sym);
   if(perUnit <= 0) return false;
   double point    = SymbolInfoDouble(sym, SYMBOL_POINT);
   double riskDist = MathAbs(price - sl) + (double)Slippage * point;   // entry side incl. spread + slippage
   if(riskDist <= 0) return false;

   double lot = NormalizeLot(sym, risk / (riskDist * perUnit));   // rounded DOWN to volume step
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(lot <= 0 || lot < minLot)
   {
      Print(sym, " skipped: min lot would risk more than $", risk);
      return false;
   }

   double loss = LossAtSL(sym, signal, lot, price, sl);
   int guard = 0;
   while(loss > risk && guard < 1000)
   {
      lot = NormalizeLot(sym, lot - step);
      if(lot <= 0 || lot < minLot) break;
      loss = LossAtSL(sym, signal, lot, price, sl);
      guard++;
   }
   if(lot <= 0 || lot < minLot || loss < 0 || loss > risk)
   {
      Print(sym, " skipped: cannot keep loss at SL <= $", risk, " (loss=", DoubleToString(loss, 2), ")");
      return false;
   }

   SetFillingForSymbol(sym);

   bool ok;
   if(signal == 1) ok = trade.Buy(lot, sym, price, sl, tp, "SMC Buy");
   else            ok = trade.Sell(lot, sym, price, sl, tp, "SMC Sell");

   uint rc = trade.ResultRetcode();
   if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL))
   {
      Print(sym, " market ", (signal == 1 ? "BUY" : "SELL"), " lot ", lot,
            " sl ", sl, " tp ", tp, " max loss $", DoubleToString(loss, 2));
      symbols[idx].stopsFails = 0;
      symbols[idx].blockedUntil = 0;
      return true;
   }

   if(rc == TRADE_RETCODE_INVALID_STOPS)
   {
      symbols[idx].stopsFails++;
      symbols[idx].blockedUntil = TimeCurrent() + InvalidStopsCooldownMin * 60;
      Print(sym, " entry rejected [invalid stops] (", symbols[idx].stopsFails,
            "x) - pausing ", InvalidStopsCooldownMin, " min, next try uses a wider stop buffer");
   }
   else
      Print(sym, " entry failed: ", rc, " ", trade.ResultRetcodeDescription());
   return false;
}

//------------------- MODIFY THROTTLE (v1.25) -------------------------
int ModStateIndex(ulong ticket)
{
   int n = ArraySize(modStates);
   for(int i = 0; i < n; i++)
      if(modStates[i].ticket == ticket) return i;
   ArrayResize(modStates, n + 1);
   modStates[n].ticket = ticket;
   modStates[n].nextAllowed = 0;
   modStates[n].lastRejectedSL = 0;
   modStates[n].fails = 0;
   return n;
}

// Drop throttle entries for positions that are closed
void PruneModStates()
{
   int n = ArraySize(modStates);
   for(int i = n - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(modStates[i].ticket)) continue;
      int last = ArraySize(modStates) - 1;
      if(i != last) modStates[i] = modStates[last];
      ArrayResize(modStates, last);
   }
}

//------------------- MANAGE OPEN POSITIONS (Trailing + BE) ----------
void ManageOpenPositions()
{
   if(!UseBreakEven && !UseTrailingStop) return;
   PruneModStates();
   datetime now = TimeCurrent();

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

      bool wantBE    = (UseBreakEven && profit >= BreakEvenTrigger);
      bool wantTrail = (UseTrailingStop && profit >= TrailingStart);
      if(!wantBE && !wantTrail) continue;

      int ms = ModStateIndex(ticket);
      if(now < modStates[ms].nextAllowed) continue;   // throttle / backoff

      MqlTick tick;
      if(!SymbolInfoTick(sym, tick) || tick.bid <= 0 || tick.ask <= 0) continue;
      double bid = tick.bid;
      double ask = tick.ask;

      double ts      = SymTickSize(sym);
      double point   = SymbolInfoDouble(sym, SYMBOL_POINT);
      double minDist = MinStopDistance(sym, bid, ask, 1);
      double freezeD = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL) * point;
      double minImprove = MoneyToPriceDistance(sym, lot, TrailMinImproveMoney);
      if(minImprove < ts) minImprove = ts;

      double newSL = 0;

      if(type == POSITION_TYPE_BUY)
      {
         // TP about to be hit (or inside freeze/stops zone): leave the position alone
         if(currentTP > 0 && currentTP - bid < minDist) continue;
         if(currentSL > 0 && freezeD > 0 && bid - currentSL <= freezeD) continue;

         double cand = currentSL;
         if(wantBE)
         {
            double beOffset = MoneyToPriceDistance(sym, lot, BreakEvenProfit);
            if(beOffset > 0)
            {
               double be = RoundToTick(sym, openPrice + beOffset, -1);
               if(be > cand) cand = be;
            }
         }
         if(wantTrail)
         {
            double trailDist = MoneyToPriceDistance(sym, lot, TrailingStep);
            if(trailDist > 0)
            {
               double tr = RoundToTick(sym, bid - trailDist, -1);
               if(tr > cand) cand = tr;
            }
         }
         double maxSL = RoundToTick(sym, bid - minDist, -1);   // must stay below bid by min dist
         if(cand > maxSL) cand = maxSL;
         if(currentTP > 0 && currentTP - cand < minDist) continue;  // too close to TP: stop trailing
         if(cand <= 0) continue;
         if(currentSL > 0 && cand - currentSL < minImprove) continue;
         newSL = cand;
      }
      else
      {
         if(currentTP > 0 && ask - currentTP < minDist) continue;
         if(currentSL > 0 && freezeD > 0 && currentSL - ask <= freezeD) continue;

         double cand = currentSL;   // 0 = no SL yet
         if(wantBE)
         {
            double beOffset = MoneyToPriceDistance(sym, lot, BreakEvenProfit);
            if(beOffset > 0)
            {
               double be = RoundToTick(sym, openPrice - beOffset, 1);
               if(cand == 0 || be < cand) cand = be;
            }
         }
         if(wantTrail)
         {
            double trailDist = MoneyToPriceDistance(sym, lot, TrailingStep);
            if(trailDist > 0)
            {
               double tr = RoundToTick(sym, ask + trailDist, 1);
               if(cand == 0 || tr < cand) cand = tr;
            }
         }
         double minSL = RoundToTick(sym, ask + minDist, 1);    // must stay above ask by min dist
         if(cand > 0 && cand < minSL) cand = minSL;
         if(cand <= 0) continue;
         if(currentTP > 0 && cand - currentTP < minDist) continue;
         if(currentSL > 0 && currentSL - cand < minImprove) continue;
         newSL = cand;
      }

      // Never re-send an SL the broker already refused, or the current one
      if(MathAbs(newSL - currentSL) < ts * 0.5) continue;
      if(modStates[ms].lastRejectedSL > 0 && MathAbs(newSL - modStates[ms].lastRejectedSL) < ts * 0.5)
         continue;

      bool ok = trade.PositionModify(ticket, newSL, currentTP);
      uint rc = trade.ResultRetcode();
      if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_NO_CHANGES))
      {
         modStates[ms].fails = 0;
         modStates[ms].lastRejectedSL = 0;
         modStates[ms].nextAllowed = now + ModifyMinSeconds;
      }
      else
      {
         modStates[ms].fails++;
         modStates[ms].lastRejectedSL = newSL;
         int f = modStates[ms].fails;
         if(f > 10) f = 10;
         int wait = (int)MathMin((double)ModifyMaxBackoffSec, (double)ModifyMinSeconds * MathPow(2.0, f));
         if(wait < 1) wait = 1;
         modStates[ms].nextAllowed = now + wait;
         Print(sym, " #", ticket, " SL modify to ", newSL, " rejected (", rc, " ",
               trade.ResultRetcodeDescription(), ") - next try in ", wait, "s");
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
   lot = MathFloor(lot / step + 1e-7) * step;   // round down only, never up past risk
   if(lot < minLot) return 0;
   if(lot > maxLot) lot = maxLot;
   int volDigits = 0;
   double s = step;
   while(volDigits < 8 && MathAbs(s - MathRound(s)) > 1e-8)
   {
      s *= 10.0;
      volDigits++;
   }
   return NormalizeDouble(lot, volDigits);
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
