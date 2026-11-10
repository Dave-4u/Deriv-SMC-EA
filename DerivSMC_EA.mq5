//+------------------------------------------------------------------+
//|                                                  DerivSMC_EA.mq5 |
//|  Multi-Pair | CRT + Rejection + OrderBlock | Trailing + BE       |
//|  Works on Synthetics + Gold + Forex | Fixed $ Risk               |
//|  v1.26: spike filter, R-based exits, daily/symbol loss stops    |
//|  v1.27: structure TP, bigger RR, partial close + runner         |
//+------------------------------------------------------------------+
#property copyright "Dave-4u"
#property link      "https://github.com/Dave-4u/Deriv-SMC-EA"
#property version   "1.27"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//------------------- INPUTS ----------------------------------------
input group "=== MULTI-PAIR & RISK ==="
input string   SymbolsList           = "Volatility 75 Index,Volatility 100 Index,Boom 1000 Index,Crash 500 Index,XAUUSD";
input bool     SymbolsFromFile       = true;       // Read names from a .txt in MQL5\\Files
input string   SymbolsFile           = "DaveSymbols.txt"; // one name per line or comma-separated, # = comment
input double   RiskMoney             = 3.0;        // Default risk in $
input double   SpikeRiskMoney        = 2.0;        // Risk in $ for Boom/Crash/DEX/Jump (CustomRiskList still overrides)
input int      MaxOpenTrades         = 3;          // Positions + pending limits
input string   CustomRiskList        = "";         // Optional: Symbol:Risk,Symbol:Risk (e.g. XAUUSD:5,Volatility 75 Index:2.5)

input group "=== PROTECTION ==="
input double   DailyLossLimitPercent = 3.0;
input int      MagicNumber           = 20261109;
input int      MaxSpreadPoints       = 150;
input double   MaxDailyLossMoney     = 9.0;        // Stop new entries after this closed loss today ($, server day; 0 = off)
input int      ConsecLossPause       = 2;          // Losses in a row on one symbol before pausing it (0 = off)
input int      SymbolPauseHours      = 3;          // Pause length for that symbol
input bool     UseSpikeDirectionFilter = true;     // No SELL on Boom / DEX..UP, no BUY on Crash / DEX..DOWN

input group "=== STRATEGY SWITCHES ==="
input bool     EnableCRT             = true;
input bool     EnableRejectionBlock  = true;
input bool     EnableOrderBlock      = true;

input group "=== TIMEFRAMES ==="
input ENUM_TIMEFRAMES TrendTF        = PERIOD_H1;
input ENUM_TIMEFRAMES EntryTF        = PERIOD_M5;  // Setup timeframe (strategies + structure)
input ENUM_TIMEFRAMES ExecTF         = PERIOD_M1;  // Timing chart for market entry
input ENUM_TIMEFRAMES ConfirmTF      = PERIOD_M15; // Middle trend timeframe (must agree with TrendTF)

input group "=== TREND & STRUCTURE ==="
input int      EMA_Period            = 50;
input int      CooldownBars          = 12;
input bool     UseMarketStructure    = true;       // Require setup-TF structure to agree with trend
input int      StructureLookback     = 50;         // Bars on EntryTF to read swings
input int      SwingStrength         = 2;          // Pivot bars on each side
input bool     UseConfirmTFTrend     = true;       // Require ConfirmTF EMA trend to agree with TrendTF

input group "=== ENTRY FILTERS (v1.26) ==="
input bool     UseBigCandleFilter    = true;       // Skip after an oversized candle
input double   BigCandleATRMult      = 2.0;        // Last closed M1/M5 bar range > this x ATR(14) = skip
input double   MaxChaseATR           = 0.5;        // Skip if price is this x ATR beyond the setup zone (0 = off)

input group "=== ENTRY ALIGNMENT (v1.27) ==="
input bool     UseEntryAlignment     = true;       // Before ANY order: M1 must be moving the setup's way
input int      AlignFastEMA          = 9;          // M1 fast EMA (buy: fast > slow and bid > fast)
input int      AlignSlowEMA          = 21;         // M1 slow EMA
input int      AlignWaitBars         = 5;          // Not aligned: wait this many M1 bars, then drop the setup

input group "=== M1 ENTRY TIMING ==="
input bool     UseM1EntryTiming      = true;       // If false, enter at market when the setup appears
input int      SetupExpireM1Bars     = 15;         // Pending setup dies after this many new M1 bars

input group "=== TRADE MANAGEMENT ==="
input double   RR_Ratio              = 3.0;        // TP = this x SL distance when no structure target is used
input int      Slippage              = 30;

input group "=== STRUCTURE TAKE-PROFIT (v1.27) ==="
input bool     UseStructureTP        = true;       // TP at the next swing high/low on the setup chart (EntryTF)
input int      StructureTPLookback   = 100;        // Bars on the setup chart to look for the target swing
input double   MinTP_R               = 2.5;        // Swing used only if it is at least this x R away
input double   MaxTP_R               = 6.0;        // TP never further than this x R (also the runner TP)
input double   StructureTPBufferATR  = 0.1;        // Put TP this x ATR before the swing so it fills

input group "=== PARTIAL CLOSE & RUNNER (v1.27) ==="
input bool     UsePartialClose       = true;       // Bank part of the trade at PartialCloseAtR
input double   PartialCloseAtR       = 2.0;        // Close part when profit >= this x R
input double   PartialClosePercent   = 50.0;       // % of the volume to close (skipped if lot steps do not allow)
input bool     RunnerRemoveTP        = false;      // After partial: move TP out to MaxTP_R so the rest can run

input group "=== BREAK-EVEN (R = initial risk) ==="
input bool     UseBreakEven          = true;
input double   BreakEvenAtR          = 1.5;        // Move SL to BE when profit >= this x R
input double   BreakEvenLockR        = 0.3;        // Lock this x R (+ spread) beyond entry

input group "=== TRAILING STOP (R / ATR) ==="
input bool     UseTrailingStop       = true;
input double   TrailStartR           = 2.0;        // Start trailing when profit >= this x R
input double   TrailATRMult          = 2.0;        // Trail distance = this x ATR(TrailATRTF)
input ENUM_TIMEFRAMES TrailATRTF     = PERIOD_M5;  // Timeframe of the ATR used for the trail distance

input group "=== BROKER STOP LEVELS (v1.25) ==="
input double   StopsSpreadBuffer     = 1.0;        // Spreads added to the broker min stop distance
input int      ExtraStopBufferPoints = 0;          // Extra points added to the min stop distance
input int      InvalidStopsCooldownMin = 30;      // Pause a symbol this long after an [invalid stops] entry
input bool     UseDeepLimitFallback  = true;       // If min lot risks > $ at market, place a limit nearer the SL
input int      LimitExpireMinutes    = 60;         // Deep limit lifetime (broker expiry or manual cancel)
input int      DeepLimitLookback     = 50;         // Bars on EntryTF/ConfirmTF/TrendTF to find swing levels
input double   DeepLevelTolATR       = 0.2;        // Limit may sit within this x ATR of a swing level
input bool     DeepLimitRequireLevel = true;       // Limit only at the setup zone or a swing level
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
   int      atrExecHandle;  // v1.26: ATR(14) on ExecTF for the big-candle filter
   int      emaConfHandle;  // v1.26: EMA on ConfirmTF
   int      atrTrailHandle; // v1.27: ATR(14) on TrailATRTF
   int      emaFastXHandle; // v1.27: fast EMA on ExecTF (alignment)
   int      emaSlowXHandle; // v1.27: slow EMA on ExecTF (alignment)
   int      alignWait;      // v1.27: M1 bars waited for alignment (0 = not waiting)
   bool     alignFailed;    // v1.27: last OpenTrade stopped only because not aligned
   string   alignReason;    // v1.27: why it was not aligned
   int      consecLosses;   // v1.26: losses in a row
   datetime pausedUntil;    // v1.26: per-symbol loss pause
   int      pendingSignal;
   int      pendingAgeM1;
   datetime blockedUntil;   // v1.25: cooldown after [invalid stops] on entry
   int      stopsFails;     // v1.25: consecutive [invalid stops] entry rejections
   int      pendingType;    // v1.25: 1 = CRT, 2 = Rejection Block, 3 = Order Block
   double   zoneLo;         // v1.25: setup zone used by the deep limit fallback
   double   zoneHi;
};

// v1.25: per-ticket SL modify throttle
struct ModifyState
{
   ulong    ticket;
   datetime nextAllowed;
   double   lastRejectedSL;
   int      fails;
   double   riskDist;       // v1.26: initial entry-to-SL distance (0 = not read yet, -1 = unknown)
   int      partialFails;   // v1.27: failed partial-close attempts
};
ModifyState modStates[];
bool       dailyStopActive = false;
bool       plDirty = true;
double     todayClosedPL = 0;
datetime   lastPLCalc = 0;

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
      symbols[symbolCount].risk = (IsSpikeSymbol(baseSymbols[i]) ? SpikeRiskMoney : RiskMoney);
      symbols[symbolCount].lastBar = 0;
      symbols[symbolCount].lastExecBar = 0;
      symbols[symbolCount].cooldown = 0;
      symbols[symbolCount].atrHandle = INVALID_HANDLE;
      symbols[symbolCount].emaHandle = INVALID_HANDLE;
      symbols[symbolCount].atrExecHandle = INVALID_HANDLE;
      symbols[symbolCount].emaConfHandle = INVALID_HANDLE;
      symbols[symbolCount].atrTrailHandle = INVALID_HANDLE;
      symbols[symbolCount].emaFastXHandle = INVALID_HANDLE;
      symbols[symbolCount].emaSlowXHandle = INVALID_HANDLE;
      symbols[symbolCount].alignWait = 0;
      symbols[symbolCount].alignFailed = false;
      symbols[symbolCount].alignReason = "";
      symbols[symbolCount].consecLosses = 0;
      symbols[symbolCount].pausedUntil = 0;
      symbols[symbolCount].pendingSignal = 0;
      symbols[symbolCount].pendingAgeM1 = 0;
      symbols[symbolCount].blockedUntil = 0;
      symbols[symbolCount].stopsFails = 0;
      symbols[symbolCount].pendingType = 0;
      symbols[symbolCount].zoneLo = 0;
      symbols[symbolCount].zoneHi = 0;

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
      int atrXHandle = iATR(baseSymbols[i], ExecTF, 14);
      int emaCHandle = iMA(baseSymbols[i], ConfirmTF, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
      int atrTHandle = iATR(baseSymbols[i], TrailATRTF, 14);
      int emaFXHandle = iMA(baseSymbols[i], ExecTF, (AlignFastEMA > 0 ? AlignFastEMA : 9),  0, MODE_EMA, PRICE_CLOSE);
      int emaSXHandle = iMA(baseSymbols[i], ExecTF, (AlignSlowEMA > 0 ? AlignSlowEMA : 21), 0, MODE_EMA, PRICE_CLOSE);

      if(atrHandle == INVALID_HANDLE || emaHandle == INVALID_HANDLE ||
         atrXHandle == INVALID_HANDLE || emaCHandle == INVALID_HANDLE ||
         atrTHandle == INVALID_HANDLE || emaFXHandle == INVALID_HANDLE ||
         emaSXHandle == INVALID_HANDLE)
      {
         Print("Failed to create handles for ", baseSymbols[i]);
         if(atrHandle  != INVALID_HANDLE) IndicatorRelease(atrHandle);
         if(emaHandle  != INVALID_HANDLE) IndicatorRelease(emaHandle);
         if(atrXHandle != INVALID_HANDLE) IndicatorRelease(atrXHandle);
         if(emaCHandle != INVALID_HANDLE) IndicatorRelease(emaCHandle);
         if(atrTHandle != INVALID_HANDLE) IndicatorRelease(atrTHandle);
         if(emaFXHandle != INVALID_HANDLE) IndicatorRelease(emaFXHandle);
         if(emaSXHandle != INVALID_HANDLE) IndicatorRelease(emaSXHandle);
         continue;
      }

      symbols[symbolCount].atrHandle = atrHandle;
      symbols[symbolCount].emaHandle = emaHandle;
      symbols[symbolCount].atrExecHandle = atrXHandle;
      symbols[symbolCount].emaConfHandle = emaCHandle;
      symbols[symbolCount].atrTrailHandle = atrTHandle;
      symbols[symbolCount].emaFastXHandle = emaFXHandle;
      symbols[symbolCount].emaSlowXHandle = emaSXHandle;
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

   RebuildLossPauses();

   Print("=== DerivSMC_EA v1.27 Started ===");
   Print("Symbols loaded: ", symbolCount,
         " | from file=", (SymbolsFromFile ? SymbolsFile : "SymbolsList"),
         " | Structure=", UseMarketStructure,
         " | M1 timing=", UseM1EntryTiming,
         " | ConfirmTF=", (UseConfirmTFTrend ? EnumToString(ConfirmTF) : "off"),
         " | spike filter=", UseSpikeDirectionFilter,
         " | max daily loss $", MaxDailyLossMoney,
         " | RR ", RR_Ratio, " | structure TP=", UseStructureTP,
         " (", MinTP_R, "-", MaxTP_R, "R) | partial=", UsePartialClose,
         " @", PartialCloseAtR, "R ", PartialClosePercent, "%",
         " | alignment=", UseEntryAlignment, " (wait ", AlignWaitBars, " M1 bars)");
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
      if(symbols[i].atrExecHandle != INVALID_HANDLE) IndicatorRelease(symbols[i].atrExecHandle);
      if(symbols[i].emaConfHandle != INVALID_HANDLE) IndicatorRelease(symbols[i].emaConfHandle);
      if(symbols[i].atrTrailHandle != INVALID_HANDLE) IndicatorRelease(symbols[i].atrTrailHandle);
      if(symbols[i].emaFastXHandle != INVALID_HANDLE) IndicatorRelease(symbols[i].emaFastXHandle);
      if(symbols[i].emaSlowXHandle != INVALID_HANDLE) IndicatorRelease(symbols[i].emaSlowXHandle);
   }
   Print("DerivSMC_EA removed");
}

//------------------- MAIN TICK --------------------------------------
void OnTick()
{
   ManageOpenPositions();
   ManagePendingOrders();

   static datetime lastGVClean = 0;
   if(TimeCurrent() - lastGVClean >= 3600)
   {
      lastGVClean = TimeCurrent();
      CleanupRiskGlobals();
   }

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

      if(UseConfirmTFTrend && GetConfirmTrend(i) != trend)
      {
         ClearPending(i);
         continue; // M15 does not agree with H1: skip this setup bar
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
      int setupType = 0;
      if(EnableCRT)
      {
         signal = DetectCRT(sym, trend);
         if(signal != 0) setupType = 1;
      }
      if(signal == 0 && EnableRejectionBlock)
      {
         signal = DetectRejectionBlock(sym, trend);
         if(signal != 0) setupType = 2;
      }
      if(signal == 0 && EnableOrderBlock)
      {
         signal = DetectOrderBlock(sym, trend);
         if(signal != 0) setupType = 3;
      }

      if(signal == 0 && symbols[i].alignWait > 0) continue;   // v1.27: keep waiting for alignment
      if(signal == 0 || SpikeDirectionBlocked(sym, signal))
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

      symbols[i].pendingType = setupType;
      double zLo = 0, zHi = 0;
      GetSetupZone(sym, setupType, zLo, zHi);
      symbols[i].zoneLo = zLo;
      symbols[i].zoneHi = zHi;

      if(!UseM1EntryTiming)
      {
         symbols[i].alignWait = 0;
         OpenTrade(i, signal);
         continue;
      }

      symbols[i].pendingSignal = signal;
      symbols[i].pendingAgeM1  = 0;
      symbols[i].alignWait     = 0;
      Print(sym, " setup ", (signal == 1 ? "BUY" : "SELL"),
            " on ", EnumToString(EntryTF),
            " — waiting for ", EnumToString(ExecTF), " confirmation");
   }
}

bool IsSymbolBlocked(int idx)
{
   datetime now = TimeCurrent();
   if(symbols[idx].blockedUntil > 0 && now < symbols[idx].blockedUntil) return true;
   if(symbols[idx].pausedUntil  > 0 && now < symbols[idx].pausedUntil)  return true;
   return false;
}

void ClearPending(int idx)
{
   symbols[idx].pendingSignal = 0;
   symbols[idx].pendingAgeM1  = 0;
   symbols[idx].alignWait     = 0;
}

void TryTimedEntry(int idx)
{
   if(symbols[idx].pendingSignal == 0) return;

   // v1.27: setup is waiting for M1 alignment (see EntryAligned)
   if(symbols[idx].alignWait > 0)
   {
      symbols[idx].alignWait++;
      if(symbols[idx].alignWait > AlignWaitBars)
      {
         Print(symbols[idx].name, " setup ", (symbols[idx].pendingSignal == 1 ? "BUY" : "SELL"),
               " dropped: market not aligned after ", AlignWaitBars, " ", EnumToString(ExecTF),
               " bars (last: ", symbols[idx].alignReason, ")");
         ClearPending(idx);
         return;
      }
      if(IsSymbolBlocked(idx)) { ClearPending(idx); return; }
      if(CountAllOpenPositions() >= MaxOpenTrades) return;
      if(CountPositionsOnSymbol(symbols[idx].name) != 0) { ClearPending(idx); return; }
      int wsig = symbols[idx].pendingSignal;
      OpenTrade(idx, wsig);
      if(!symbols[idx].alignFailed) ClearPending(idx);   // placed, or skipped for a non-alignment reason
      return;
   }

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

//------------------- v1.26 HELPERS ----------------------------------
string UpperName(string sym)
{
   string u = sym;
   StringToUpper(u);
   return u;
}

bool IsSpikeSymbol(string sym)
{
   string u = UpperName(sym);
   return (StringFind(u, "BOOM") >= 0 || StringFind(u, "CRASH") >= 0 ||
           StringFind(u, "DEX") >= 0  || StringFind(u, "JUMP") >= 0);
}

// true = this direction trades against the symbol's spikes
bool SpikeDirectionBlocked(string sym, int signal)
{
   if(!UseSpikeDirectionFilter) return false;
   string u = UpperName(sym);
   bool dex = (StringFind(u, "DEX") >= 0);
   if(signal == -1 && (StringFind(u, "BOOM") >= 0 || (dex && StringFind(u, "UP") >= 0)))
      return true;
   if(signal == 1 && (StringFind(u, "CRASH") >= 0 || (dex && StringFind(u, "DOWN") >= 0)))
      return true;
   return false;
}

int FindSymbolIndex(string sym)
{
   for(int i = 0; i < symbolCount; i++)
      if(symbols[i].name == sym) return i;
   return -1;
}

double GetBufVal(int handle, int shift)
{
   if(handle == INVALID_HANDLE) return 0;
   double b[];
   if(CopyBuffer(handle, 0, shift, 1, b) < 1) return 0;
   return b[0];
}

// ConfirmTF (M15) EMA trend: close above/below a rising/falling EMA
int GetConfirmTrend(int idx)
{
   double ema[];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(symbols[idx].emaConfHandle, 0, 0, 3, ema) < 3) return 0;
   double close1 = iClose(symbols[idx].name, ConfirmTF, 1);
   if(close1 <= 0) return 0;
   if(close1 > ema[1] && ema[1] >= ema[2]) return 1;
   if(close1 < ema[1] && ema[1] <= ema[2]) return -1;
   return 0;
}

// Last closed M1 or setup-TF bar much bigger than normal = spike/news candle
bool IsBigCandle(int idx)
{
   if(!UseBigCandleFilter || BigCandleATRMult <= 0) return false;
   string sym = symbols[idx].name;

   double atrX = GetBufVal(symbols[idx].atrExecHandle, 1);
   double rX   = iHigh(sym, ExecTF, 1) - iLow(sym, ExecTF, 1);
   if(atrX > 0 && rX > BigCandleATRMult * atrX)
   {
      Print(sym, " skipped: big ", EnumToString(ExecTF), " candle (range ",
            DoubleToString(rX / atrX, 1), "x ATR)");
      return true;
   }
   double atrE = GetBufVal(symbols[idx].atrHandle, 1);
   double rE   = iHigh(sym, EntryTF, 1) - iLow(sym, EntryTF, 1);
   if(atrE > 0 && rE > BigCandleATRMult * atrE)
   {
      Print(sym, " skipped: big ", EnumToString(EntryTF), " candle (range ",
            DoubleToString(rE / atrE, 1), "x ATR)");
      return true;
   }
   return false;
}

// Price already ran too far past the setup zone in the trade direction
bool IsChasing(int idx, int signal, double bid, double ask, double atrE)
{
   if(MaxChaseATR <= 0 || atrE <= 0) return false;
   double zLo = symbols[idx].zoneLo;
   double zHi = symbols[idx].zoneHi;
   if(zLo <= 0 || zHi <= 0) return false;
   double lim = MaxChaseATR * atrE;
   if(signal == 1 && ask > zHi + lim)
   {
      Print(symbols[idx].name, " skipped: chasing BUY (ask ", ask, " > zone high ", zHi, " + ",
            DoubleToString(MaxChaseATR, 2), " ATR)");
      return true;
   }
   if(signal == -1 && bid < zLo - lim)
   {
      Print(symbols[idx].name, " skipped: chasing SELL (bid ", bid, " < zone low ", zLo, " - ",
            DoubleToString(MaxChaseATR, 2), " ATR)");
      return true;
   }
   return false;
}

//------------------- CLOSED P/L, DAILY STOP, LOSS PAUSE (v1.26) ------
// Closed P/L today (server day) for this EA's magic
double TodayClosedPL()
{
   long nowL = (long)TimeCurrent();
   datetime dayStart = (datetime)(nowL - nowL % 86400);
   if(!HistorySelect(dayStart, TimeCurrent() + 60)) return 0;
   double pl = 0;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != MagicNumber) continue;
      long dtype = HistoryDealGetInteger(d, DEAL_TYPE);
      if(dtype != DEAL_TYPE_BUY && dtype != DEAL_TYPE_SELL) continue;
      pl += HistoryDealGetDouble(d, DEAL_PROFIT)
          + HistoryDealGetDouble(d, DEAL_SWAP)
          + HistoryDealGetDouble(d, DEAL_COMMISSION);
   }
   return pl;
}

// Count a closed deal toward the per-symbol consecutive-loss pause
void ProcessClosedDeal(ulong deal, bool live)
{
   if(deal == 0) return;
   if(HistoryDealGetInteger(deal, DEAL_MAGIC) != MagicNumber) return;
   long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY) return;

   string sym = HistoryDealGetString(deal, DEAL_SYMBOL);
   int idx = FindSymbolIndex(sym);
   if(idx < 0) return;

   double pl = HistoryDealGetDouble(deal, DEAL_PROFIT)
             + HistoryDealGetDouble(deal, DEAL_SWAP)
             + HistoryDealGetDouble(deal, DEAL_COMMISSION);
   datetime t = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);

   if(pl < 0)
   {
      symbols[idx].consecLosses++;
      if(ConsecLossPause > 0 && symbols[idx].consecLosses >= ConsecLossPause)
      {
         symbols[idx].pausedUntil = t + SymbolPauseHours * 3600;
         symbols[idx].consecLosses = 0;
         if(live || symbols[idx].pausedUntil > TimeCurrent())
            Print(sym, " paused after ", ConsecLossPause, " losses in a row until ",
                  TimeToString(symbols[idx].pausedUntil, TIME_DATE | TIME_MINUTES), " (server)");
      }
   }
   else
      symbols[idx].consecLosses = 0;
}

// Rebuild loss streaks/pauses from recent history (survives EA restart)
void RebuildLossPauses()
{
   datetime now = TimeCurrent();
   int back = 2 * 86400;
   if(SymbolPauseHours * 3600 * 2 > back) back = SymbolPauseHours * 3600 * 2;
   if(!HistorySelect(now - back, now + 60)) return;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d > 0) ProcessClosedDeal(d, false);
   }
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   ProcessClosedDeal(trans.deal, true);
   plDirty = true;
}

//------------------- INITIAL RISK PER TICKET (v1.26) -----------------
string RiskGVName(ulong ticket)
{
   return "DSMC_" + IntegerToString(MagicNumber) + "_R_" + IntegerToString((long)ticket);
}

// v1.27: flags per ticket: partial close done (_P_), runner TP moved (_T_)
string PartialGVName(ulong ticket)
{
   return "DSMC_" + IntegerToString(MagicNumber) + "_P_" + IntegerToString((long)ticket);
}

string RunnerGVName(ulong ticket)
{
   return "DSMC_" + IntegerToString(MagicNumber) + "_T_" + IntegerToString((long)ticket);
}

void StoreInitialRisk(ulong ticket, double dist)
{
   if(ticket == 0 || dist <= 0) return;
   GlobalVariableSet(RiskGVName(ticket), dist);
}

// Initial entry-to-SL distance: terminal global variable, else the SL of the
// opening order in history, else the current SL if it is still on the loss side
double GetInitialRiskDist(ulong ticket, ulong posId, double openPrice, double currentSL, long type)
{
   string gv = RiskGVName(ticket);
   if(GlobalVariableCheck(gv))
   {
      double v = GlobalVariableGet(gv);
      if(v > 0) return v;
   }

   double dist = 0;
   if(HistorySelectByPosition(posId > 0 ? posId : ticket))
   {
      int n = HistoryDealsTotal();
      for(int i = 0; i < n; i++)
      {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0) continue;
         if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
         ulong ord = (ulong)HistoryDealGetInteger(d, DEAL_ORDER);
         double osl = 0;
         if(ord > 0) osl = HistoryOrderGetDouble(ord, ORDER_SL);
         if(osl > 0) dist = MathAbs(openPrice - osl);
         break;
      }
   }
   if(dist <= 0 && currentSL > 0)
   {
      if(type == POSITION_TYPE_BUY && currentSL < openPrice)   dist = openPrice - currentSL;
      if(type == POSITION_TYPE_SELL && currentSL > openPrice)  dist = currentSL - openPrice;
   }
   if(dist > 0) GlobalVariableSet(gv, dist);
   return dist;
}

// Remove risk globals whose position/order no longer exists
void CleanupRiskGlobals()
{
   string base = "DSMC_" + IntegerToString(MagicNumber) + "_";
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
   {
      string nm = GlobalVariableName(i);
      string prefix = "";
      if(StringFind(nm, base + "R_") == 0)      prefix = base + "R_";
      else if(StringFind(nm, base + "P_") == 0) prefix = base + "P_";
      else if(StringFind(nm, base + "T_") == 0) prefix = base + "T_";
      if(prefix == "") continue;
      ulong t = (ulong)StringToInteger(StringSubstr(nm, StringLen(prefix)));
      if(t == 0) continue;
      if(PositionSelectByTicket(t) || OrderSelect(t)) continue;
      GlobalVariableDel(nm);
   }
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

//------------------- TAKE-PROFIT TARGET (v1.27) ----------------------
// TP distance from 'entry'. rD = 1R (entry-to-SL distance used for sizing the target).
// If UseStructureTP: the nearest swing high (buy) / swing low (sell) on the SETUP
// chart (EntryTF, closed bars) that is at least MinTP_R away, minus a small buffer,
// capped at MaxTP_R. Otherwise / no valid swing: RR_Ratio x rD. Never < minDist.
// The TP only decides where profit is taken; it never changes the SL or the lot.
double TargetDistance(string sym, int signal, double entry, double rD, double atrE, double minDist)
{
   if(rD <= 0) return minDist;
   double rrD  = rD * RR_Ratio;
   double tpD  = rrD;
   string src  = "RR " + DoubleToString(RR_Ratio, 1);

   if(UseStructureTP)
   {
      double buf = StructureTPBufferATR * atrE;
      if(buf < 0) buf = 0;
      double minD = MinTP_R * rD;
      double maxD = (MaxTP_R > 0 ? MaxTP_R * rD : 0);
      double levels[];
      ArrayResize(levels, 0);
      CollectSwingLevels(sym, EntryTF, (signal == -1), StructureTPLookback, levels);  // highs for buys, lows for sells
      double best = 0;
      int n = ArraySize(levels);
      for(int i = 0; i < n; i++)
      {
         double d = (signal == 1 ? (levels[i] - buf) - entry : entry - (levels[i] + buf));
         if(d <= 0 || d < minD) continue;          // not beyond entry, or too close
         if(best == 0 || d < best) best = d;       // nearest qualifying swing
      }
      if(best > 0)
      {
         tpD = best;
         src = "swing " + EnumToString(EntryTF);
         if(maxD > 0 && tpD > maxD) { tpD = maxD; src += " capped " + DoubleToString(MaxTP_R, 1) + "R"; }
      }
   }
   if(signal == -1 && tpD >= entry) tpD = entry * 0.5;   // sell TP must stay above 0
   if(tpD < minDist) tpD = minDist;
   Print(sym, " TP target: ", src, " = ", DoubleToString(tpD / rD, 2), "R");
   return tpD;
}

//------------------- ENTRY ALIGNMENT (v1.27) ------------------------
// Market must be moving the setup's way right before an order is sent.
// BUY (SELL mirrored): last closed M1 bar is bullish and closes above the prior
// M1 high (ExecBarConfirms), M1 fast EMA > slow EMA, bid > fast EMA, and price
// is not more than MaxChaseATR x ATR past the setup zone (IsChasing).
bool EntryAligned(int idx, int signal, double bid, double ask, double atrE, string &why)
{
   why = "";
   string sym = symbols[idx].name;
   if(!ExecBarConfirms(sym, signal))
   {
      why = (signal == 1 ? "last M1 bar not a bullish close above the prior high"
                         : "last M1 bar not a bearish close below the prior low");
      return false;
   }
   double f = GetBufVal(symbols[idx].emaFastXHandle, 1);
   double s = GetBufVal(symbols[idx].emaSlowXHandle, 1);
   if(f <= 0 || s <= 0) { why = "M1 EMA not ready"; return false; }
   if(signal == 1 && !(f > s && bid > f))
   {
      why = "M1 EMA" + IntegerToString(AlignFastEMA) + "/" + IntegerToString(AlignSlowEMA) + " not bullish or bid below fast EMA";
      return false;
   }
   if(signal == -1 && !(f < s && ask < f))
   {
      why = "M1 EMA" + IntegerToString(AlignFastEMA) + "/" + IntegerToString(AlignSlowEMA) + " not bearish or ask above fast EMA";
      return false;
   }
   if(IsChasing(idx, signal, bid, ask, atrE))
   {
      why = "price too far past the setup zone";
      return false;
   }
   return true;
}

//------------------- OPEN TRADE -------------------------------------
bool OpenTrade(int idx, int signal)
{
   string sym = symbols[idx].name;
   double risk = symbols[idx].risk;
   symbols[idx].alignFailed = false;   // v1.27: set true only by the alignment gate below
   if(risk <= 0) return false;
   if(SpikeDirectionBlocked(sym, signal)) return false;
   if(IsBigCandle(idx)) return false;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(symbols[idx].atrHandle, 0, 1, 1, atr) < 1) return false;
   if(atr[0] <= 0) return false;

   MqlTick tick;
   if(!SymbolInfoTick(sym, tick) || tick.bid <= 0 || tick.ask <= 0) return false;
   double bid = tick.bid;
   double ask = tick.ask;

   // v1.27: alignment gate before ANY order (market entry and deep limit)
   if(UseEntryAlignment)
   {
      string why = "";
      if(!EntryAligned(idx, signal, bid, ask, atr[0], why))
      {
         symbols[idx].alignFailed = true;
         symbols[idx].alignReason = why;
         if(symbols[idx].alignWait == 0)
         {
            symbols[idx].pendingSignal = signal;
            symbols[idx].pendingAgeM1  = 0;
            symbols[idx].alignWait     = 1;
            Print(sym, " ", (signal == 1 ? "BUY" : "SELL"), " not aligned (", why,
                  ") - waiting up to ", AlignWaitBars, " ", EnumToString(ExecTF), " bars");
         }
         else
            Print(sym, " still not aligned (", why, ") - wait ", symbols[idx].alignWait, "/", AlignWaitBars);
         return false;
      }
      if(symbols[idx].alignWait > 0)
         Print(sym, " aligned after ", symbols[idx].alignWait, " ", EnumToString(ExecTF), " bars");
   }

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
      // Correct side (buy SL/TP are triggered by bid)
      if(sl > bid - minDist) sl = RoundToTick(sym, bid - minDist, -1);
      double slD = price - sl;
      double tpD = TargetDistance(sym, signal, price, slD, atr[0], minDist);   // v1.27: structure / RR
      tp = RoundToTick(sym, price + tpD, 1);
      if(sl >= bid || tp <= ask) { Print(sym, " BUY skipped: stops on wrong side"); return false; }
   }
   else
   {
      price = bid;
      sl = RoundToTick(sym, price + slDistance, 1);
      // Correct side (sell SL/TP are triggered by ask)
      if(sl < ask + minDist) sl = RoundToTick(sym, ask + minDist, 1);
      double slD = sl - price;
      double tpD = TargetDistance(sym, signal, price, slD, atr[0], minDist);
      tp = RoundToTick(sym, price - tpD, -1);
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
      return TryDeepLimit(idx, signal, sl, bid, ask, minDist, atr[0]);

   double loss = LossAtSL(sym, signal, lot, price, sl);
   int guard = 0;
   while(loss > risk && guard < 1000)
   {
      lot = NormalizeLot(sym, lot - step);
      if(lot <= 0 || lot < minLot) break;
      loss = LossAtSL(sym, signal, lot, price, sl);
      guard++;
   }
   if(loss >= 0 && (lot <= 0 || lot < minLot))
      return TryDeepLimit(idx, signal, sl, bid, ask, minDist, atr[0]);
   if(lot <= 0 || lot < minLot || loss < 0 || loss > risk)
   {
      Print(sym, " skipped: cannot keep loss at SL <= $", risk, " (loss=", DoubleToString(loss, 2), ")");
      return false;
   }

   if(IsChasing(idx, signal, bid, ask, atr[0])) return false;

   SetFillingForSymbol(sym);

   bool ok;
   if(signal == 1) ok = trade.Buy(lot, sym, price, sl, tp, "SMC Buy");
   else            ok = trade.Sell(lot, sym, price, sl, tp, "SMC Sell");

   uint rc = trade.ResultRetcode();
   if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL))
   {
      double fill = trade.ResultPrice();
      if(fill <= 0) fill = price;
      StoreInitialRisk(trade.ResultOrder(), MathAbs(fill - sl));
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

//------------------- DEEP LIMIT FALLBACK (v1.25, levels in v1.26) ----
// Setup zone of the bars the detector used (EntryTF, closed bars)
void GetSetupZone(string sym, int setupType, double &lo, double &hi)
{
   int bars = 1;                       // 2 = Rejection Block: setup candle only
   if(setupType == 1) bars = 2;        // CRT: range candle + sweep candle
   if(setupType == 3) bars = 3;        // Order Block: 3-bar swing
   lo = 0; hi = 0;
   for(int b = 1; b <= bars; b++)
   {
      double h = iHigh(sym, EntryTF, b);
      double l = iLow(sym, EntryTF, b);
      if(h <= 0 || l <= 0) continue;
      if(hi == 0 || h > hi) hi = h;
      if(lo == 0 || l < lo) lo = l;
   }
}

// Swing lows (lows=true) or swing highs on any timeframe, closed bars only
void CollectSwingLevels(string sym, ENUM_TIMEFRAMES tf, bool lows, int lookback, double &levels[])
{
   int strength = SwingStrength;
   if(strength < 1) strength = 1;
   if(lookback < strength * 2 + 1) lookback = strength * 2 + 1;
   for(int shift = strength; shift <= lookback; shift++)
   {
      double v = (lows ? iLow(sym, tf, shift) : iHigh(sym, tf, shift));
      if(v <= 0) continue;
      bool isSwing = true;
      for(int k = 1; k <= strength; k++)
      {
         double a = (lows ? iLow(sym, tf, shift + k) : iHigh(sym, tf, shift + k));
         double b = (lows ? iLow(sym, tf, shift - k) : iHigh(sym, tf, shift - k));
         if(a <= 0 || b <= 0) { isSwing = false; break; }
         if(lows  && (a <= v || b <= v)) { isSwing = false; break; }
         if(!lows && (a >= v || b >= v)) { isSwing = false; break; }
      }
      if(!isSwing) continue;
      int n = ArraySize(levels);
      ArrayResize(levels, n + 1);
      levels[n] = v;
   }
}

// Keep the candidate nearest to the market (most likely to fill)
void ConsiderDeepPrice(int signal, double cand, string src, double &best, string &bestSrc)
{
   if(cand <= 0) return;
   if(best == 0 || (signal == 1 && cand > best) || (signal == -1 && cand < best))
   {
      best = cand;
      bestSrc = src;
   }
}

// Min lot is too big for RiskMoney at market: place a limit closer to the same SL
// so that min lot loses <= RiskMoney at SL, at the setup zone or a swing level.
bool TryDeepLimit(int idx, int signal, double sl, double bid, double ask, double minDist, double atrE)
{
   string sym  = symbols[idx].name;
   double risk = symbols[idx].risk;
   double zLo  = symbols[idx].zoneLo;
   double zHi  = symbols[idx].zoneHi;
   string side = (signal == 1 ? "BUY LIMIT" : "SELL LIMIT");

   if(!UseDeepLimitFallback)
   {
      Print(sym, " skipped: min lot would risk more than $", risk);
      return false;
   }

   double minLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double lot     = NormalizeLot(sym, minLot);
   double perUnit = LossPerPriceUnit(sym);
   double point   = SymbolInfoDouble(sym, SYMBOL_POINT);
   double ts      = SymTickSize(sym);
   if(lot <= 0 || perUnit <= 0 || ts <= 0) return false;

   // Largest entry-to-SL distance min lot may have (minus slippage allowance)
   double allowDist = risk / (lot * perUnit) - (double)Slippage * point;
   if(allowDist < minDist)
   {
      Print(sym, " deep limit fallback: allowed SL distance ", DoubleToString(allowDist, 8),
            " is inside broker min ", DoubleToString(minDist, 8), " - skipped");
      return false;
   }

   // Valid price range: far enough from SL, within the $ cap, far enough from market
   double loP, hiP;
   if(signal == 1)
   {
      loP = sl + minDist;
      hiP = MathMin(sl + allowDist, ask - minDist);
   }
   else
   {
      hiP = sl - minDist;
      loP = MathMax(sl - allowDist, bid + minDist);
   }
   if(hiP < loP)
   {
      Print(sym, " deep limit fallback: no room between SL ", sl, " and market for a ",
            side, " - skipped");
      return false;
   }

   double best = 0;
   string bestSrc = "";
   double tol = DeepLevelTolATR * atrE;
   if(tol < 0) tol = 0;

   // a) setup candles (CRT / rejection / OB range)
   if(zLo > 0 && zHi > zLo)
   {
      double a = MathMax(zLo, loP);
      double b = MathMin(zHi, hiP);
      if(a <= b) ConsiderDeepPrice(signal, (signal == 1 ? b : a), "setup zone", best, bestSrc);
   }

   // b) swing support (buys) / resistance (sells) on EntryTF, ConfirmTF and TrendTF
   double levels[];
   ArrayResize(levels, 0);
   bool lows = (signal == 1);
   CollectSwingLevels(sym, EntryTF,   lows, DeepLimitLookback, levels);
   CollectSwingLevels(sym, ConfirmTF, lows, DeepLimitLookback, levels);
   CollectSwingLevels(sym, TrendTF,   lows, DeepLimitLookback, levels);
   int nl = ArraySize(levels);
   for(int i = 0; i < nl; i++)
   {
      double a = MathMax(levels[i] - tol, loP);
      double b = MathMin(levels[i] + tol, hiP);
      if(a <= b) ConsiderDeepPrice(signal, (signal == 1 ? b : a), "swing level " + DoubleToString(levels[i], 5), best, bestSrc);
   }

   // c) optional: any price inside the valid range
   if(!DeepLimitRequireLevel)
      ConsiderDeepPrice(signal, (signal == 1 ? hiP : loP), "risk cap", best, bestSrc);

   if(best <= 0)
   {
      Print(sym, " deep limit fallback: no setup zone or swing level in valid range [",
            DoubleToString(loP, 5), " - ", DoubleToString(hiP, 5), "] - skipped");
      return false;
   }

   // Round toward the SL (less risk, further from market)
   double lp = (signal == 1 ? RoundToTick(sym, best, -1) : RoundToTick(sym, best, 1));

   // Re-verify actual loss; step toward the SL (never past min distance) if needed
   double loss = LossAtSL(sym, signal, lot, lp, sl);
   int guard = 0;
   while(loss > risk && guard < 1000)
   {
      lp = (signal == 1 ? lp - ts : lp + ts);
      lp = RoundToTick(sym, lp, 0);
      loss = LossAtSL(sym, signal, lot, lp, sl);
      guard++;
   }
   if(loss < 0 || loss > risk || MathAbs(lp - sl) < minDist)
   {
      Print(sym, " deep limit fallback: cannot keep loss <= $", risk, " - skipped");
      return false;
   }
   if(signal == 1 && lp > ask - minDist)
   {
      Print(sym, " deep limit fallback: ", side, " ", lp, " too close to ask ", ask, " - skipped");
      return false;
   }
   if(signal == -1 && lp < bid + minDist)
   {
      Print(sym, " deep limit fallback: ", side, " ", lp, " too close to bid ", bid, " - skipped");
      return false;
   }

   // Same SL. v1.27: TP from the limit price, sized on the NORMAL market-entry
   // SL distance (so a tight limit stop gets a big R), never smaller than the
   // market-entry TP would have been.
   double slD = MathAbs(lp - sl);
   double baseSlD = (signal == 1 ? ask - sl : sl - bid);   // SL distance a market entry had
   if(baseSlD < slD) baseSlD = slD;
   double mktPrice = (signal == 1 ? ask : bid);
   double gap      = MathAbs(mktPrice - lp);                    // limit sits this far behind market
   double mktTpD   = TargetDistance(sym, signal, mktPrice, baseSlD, atrE, minDist);
   double tpD      = mktTpD + gap;                              // same TP price a market entry would get
   if(tpD < baseSlD * RR_Ratio) tpD = baseSlD * RR_Ratio;       // and at least RR x the normal SL distance
   if(tpD < minDist) tpD = minDist;
   double tp  = (signal == 1 ? RoundToTick(sym, lp + tpD, 1) : RoundToTick(sym, lp - tpD, -1));
   if(tp <= 0) return false;

   // Expiry: broker-side if supported, otherwise GTC + manual cancel in ManagePendingOrders
   ENUM_ORDER_TYPE_TIME tt = ORDER_TIME_GTC;
   datetime expiry = 0;
   int expMode = (int)SymbolInfoInteger(sym, SYMBOL_EXPIRATION_MODE);
   if(LimitExpireMinutes > 0 && (expMode & SYMBOL_EXPIRATION_SPECIFIED) == SYMBOL_EXPIRATION_SPECIFIED)
   {
      tt  = ORDER_TIME_SPECIFIED;
      expiry = TimeCurrent() + LimitExpireMinutes * 60;
   }

   trade.SetTypeFilling(ORDER_FILLING_RETURN);   // pending orders
   bool ok;
   if(signal == 1) ok = trade.BuyLimit(lot, lp, sym, sl, tp, tt, expiry, "SMC DeepLimit");
   else            ok = trade.SellLimit(lot, lp, sym, sl, tp, tt, expiry, "SMC DeepLimit");
   uint rc = trade.ResultRetcode();
   SetFillingForSymbol(sym);

   if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
   {
      StoreInitialRisk(trade.ResultOrder(), slD);
      Print(sym, " deep limit fallback: ", side, " ", lp, " at ", bestSrc, " lot ", lot,
            " sl ", sl, " tp ", tp, " (", DoubleToString(tpD / slD, 1), "R) max loss $", DoubleToString(loss, 2),
            (tt == ORDER_TIME_SPECIFIED ? " (broker expiry)" : " (manual expiry)"));
      symbols[idx].stopsFails = 0;
      return true;
   }
   if(rc == TRADE_RETCODE_INVALID_STOPS || rc == TRADE_RETCODE_INVALID_PRICE)
   {
      symbols[idx].stopsFails++;
      symbols[idx].blockedUntil = TimeCurrent() + InvalidStopsCooldownMin * 60;
   }
   Print(sym, " deep limit fallback: ", side, " failed ", rc, " ", trade.ResultRetcodeDescription());
   return false;
}

// Cancel our pending limits: too old, H1 trend flipped, daily stop, or symbol paused
void ManagePendingOrders()
{
   static datetime lastRun = 0;
   datetime now = TimeCurrent();
   if(now == lastRun) return;    // at most once per second
   lastRun = now;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      if(OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      long otype = OrderGetInteger(ORDER_TYPE);
      if(otype != ORDER_TYPE_BUY_LIMIT && otype != ORDER_TYPE_SELL_LIMIT) continue;

      string sym = OrderGetString(ORDER_SYMBOL);
      datetime setup = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      int dir = (otype == ORDER_TYPE_BUY_LIMIT ? 1 : -1);

      string why = "";
      if(LimitExpireMinutes > 0 && now - setup >= LimitExpireMinutes * 60)
         why = "expired";
      else if(dailyStopActive)
         why = "daily loss stop";
      else
      {
         int s = FindSymbolIndex(sym);
         if(s >= 0)
         {
            if(symbols[s].pausedUntil > 0 && now < symbols[s].pausedUntil)
               why = "symbol paused";
            else if(GetTrendDirection(s) == -dir)
               why = "trend flipped";
         }
      }
      if(why == "") continue;
      if(trade.OrderDelete(ticket))
      {
         GlobalVariableDel(RiskGVName(ticket));
         Print(sym, " deep limit fallback: order #", ticket, " deleted (", why, ")");
      }
   }
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
   modStates[n].riskDist = 0;
   modStates[n].partialFails = 0;
   return n;
}

// Drop throttle entries (and risk globals) for positions that are closed
void PruneModStates()
{
   int n = ArraySize(modStates);
   for(int i = n - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(modStates[i].ticket)) continue;
      GlobalVariableDel(RiskGVName(modStates[i].ticket));
      GlobalVariableDel(PartialGVName(modStates[i].ticket));
      GlobalVariableDel(RunnerGVName(modStates[i].ticket));
      int last = ArraySize(modStates) - 1;
      if(i != last) modStates[i] = modStates[last];
      ArrayResize(modStates, last);
   }
}

//------------------- MANAGE OPEN POSITIONS (R-based BE + ATR trail) --
void ManageOpenPositions()
{
   PruneModStates();
   if(!UseBreakEven && !UseTrailingStop && !UsePartialClose) return;
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
      double lot = PositionGetDouble(POSITION_VOLUME);
      ulong  posId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);

      int ms = ModStateIndex(ticket);
      if(modStates[ms].riskDist == 0)
      {
         double rd = GetInitialRiskDist(ticket, posId, openPrice, currentSL, type);
         modStates[ms].riskDist = (rd > 0 ? rd : -1);
         if(rd <= 0)
            Print(sym, " #", ticket, " initial risk unknown - BE/trailing off for this trade");
      }
      double rDist = modStates[ms].riskDist;
      if(rDist <= 0) continue;
      if(now < modStates[ms].nextAllowed) continue;   // throttle / backoff

      MqlTick tick;
      if(!SymbolInfoTick(sym, tick) || tick.bid <= 0 || tick.ask <= 0) continue;
      double bid = tick.bid;
      double ask = tick.ask;

      double profitDist = (type == POSITION_TYPE_BUY ? bid - openPrice : openPrice - ask);
      double profitR = profitDist / rDist;

      double ts      = SymTickSize(sym);
      double point   = SymbolInfoDouble(sym, SYMBOL_POINT);
      double spread  = ask - bid;
      if(spread < 0) spread = 0;
      double minDist = MinStopDistance(sym, bid, ask, 1);
      double freezeD = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL) * point;

      // ---- v1.27: partial close at PartialCloseAtR (banks profit, never adds risk) ----
      bool partialDone = GlobalVariableCheck(PartialGVName(ticket));
      if(UsePartialClose && !partialDone && profitR >= PartialCloseAtR &&
         PartialClosePercent > 0 && PartialClosePercent < 100)
      {
         double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
         double vStep  = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
         double closeVol = NormalizeLot(sym, lot * PartialClosePercent / 100.0);   // rounded down
         double rest = lot - closeVol;
         if(closeVol <= 0 || vStep <= 0 || rest < minLot - vStep * 0.01)
         {
            GlobalVariableSet(PartialGVName(ticket), 2);   // 2 = skipped, volume too small to split
            Print(sym, " #", ticket, " partial close skipped: lot ", lot, " cannot be split (min ", minLot,
                  ", step ", vStep, ") - full position keeps running");
         }
         else
         {
            bool hedging = (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
            if(!hedging)
            {
               // CTrade partial close is hedging-only; never send an opposite deal on netting
               GlobalVariableSet(PartialGVName(ticket), 4);   // 4 = skipped, netting account
               Print(sym, " #", ticket, " partial close skipped: account is not hedging - full position keeps running");
               continue;
            }
            SetFillingForSymbol(sym);
            bool pok = trade.PositionClosePartial(ticket, closeVol, (ulong)Slippage);
            uint prc = trade.ResultRetcode();
            if(pok && (prc == TRADE_RETCODE_DONE || prc == TRADE_RETCODE_DONE_PARTIAL || prc == TRADE_RETCODE_PLACED))
            {
               GlobalVariableSet(PartialGVName(ticket), 1);
               Print(sym, " #", ticket, " partial close ", closeVol, " of ", lot, " at ",
                     DoubleToString(profitR, 2), "R - rest runs");
            }
            else
            {
               modStates[ms].partialFails++;
               Print(sym, " #", ticket, " partial close failed (", prc, " ", trade.ResultRetcodeDescription(),
                     ") try ", modStates[ms].partialFails);
               if(modStates[ms].partialFails >= 3)
                  GlobalVariableSet(PartialGVName(ticket), 3);  // 3 = gave up, stop retrying
            }
         }
         modStates[ms].nextAllowed = now + ModifyMinSeconds;   // re-read the position next pass
         continue;
      }

      // ---- v1.27: runner TP: after a real partial close, push TP out to MaxTP_R ----
      if(RunnerRemoveTP && MaxTP_R > 0 && currentTP > 0 &&
         GlobalVariableCheck(PartialGVName(ticket)) && GlobalVariableGet(PartialGVName(ticket)) == 1 &&
         !GlobalVariableCheck(RunnerGVName(ticket)))
      {
         double farTP = (type == POSITION_TYPE_BUY ? RoundToTick(sym, openPrice + MaxTP_R * rDist, 1)
                                                   : RoundToTick(sym, openPrice - MaxTP_R * rDist, -1));
         bool further = (type == POSITION_TYPE_BUY ? farTP > currentTP + ts * 0.5
                                                   : (farTP < currentTP - ts * 0.5 && farTP > 0));
         bool tpFrozen = (freezeD > 0 && MathAbs((type == POSITION_TYPE_BUY ? bid : ask) - currentTP) <= freezeD);
         if(!further)
            GlobalVariableSet(RunnerGVName(ticket), 1);   // TP already at/after MaxTP_R
         else if(!tpFrozen)
         {
            bool tok = trade.PositionModify(ticket, currentSL, farTP);
            uint trc = trade.ResultRetcode();
            if(tok && (trc == TRADE_RETCODE_DONE || trc == TRADE_RETCODE_NO_CHANGES))
            {
               GlobalVariableSet(RunnerGVName(ticket), 1);
               modStates[ms].fails = 0;
               modStates[ms].nextAllowed = now + ModifyMinSeconds;
               Print(sym, " #", ticket, " runner TP moved to ", farTP, " (", DoubleToString(MaxTP_R, 1), "R)");
            }
            else
            {
               modStates[ms].fails++;
               int f2 = modStates[ms].fails;
               if(f2 > 10) f2 = 10;
               int w2 = (int)MathMin((double)ModifyMaxBackoffSec, (double)ModifyMinSeconds * MathPow(2.0, f2));
               if(w2 < 1) w2 = 1;
               modStates[ms].nextAllowed = now + w2;
               if(modStates[ms].fails >= 5) GlobalVariableSet(RunnerGVName(ticket), 2);   // give up on TP move
               Print(sym, " #", ticket, " runner TP move rejected (", trc, " ",
                     trade.ResultRetcodeDescription(), ") - next try in ", w2, "s");
            }
            continue;
         }
      }

      bool wantBE    = (UseBreakEven && profitR >= BreakEvenAtR);
      bool wantTrail = (UseTrailingStop && profitR >= TrailStartR);
      if(!wantBE && !wantTrail) continue;
      double minImprove = MoneyToPriceDistance(sym, lot, TrailMinImproveMoney);
      if(minImprove < ts) minImprove = ts;

      double beLock = BreakEvenLockR * rDist + spread;
      double trailDist = 0;
      int si = FindSymbolIndex(sym);
      if(si >= 0) trailDist = TrailATRMult * GetBufVal(symbols[si].atrTrailHandle, 1);
      if(trailDist <= 0) wantTrail = false;

      double newSL = 0;

      if(type == POSITION_TYPE_BUY)
      {
         // TP about to be hit (or inside freeze/stops zone): leave the position alone
         if(currentTP > 0 && currentTP - bid < minDist) continue;
         if(currentSL > 0 && freezeD > 0 && bid - currentSL <= freezeD) continue;

         double cand = currentSL;
         if(wantBE)
         {
            double be = RoundToTick(sym, openPrice + beLock, -1);
            if(be > cand) cand = be;
         }
         if(wantTrail)
         {
            double tr = RoundToTick(sym, bid - trailDist, -1);
            if(tr > cand) cand = tr;
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
            double be = RoundToTick(sym, openPrice - beLock, 1);
            if(cand == 0 || be < cand) cand = be;
         }
         if(wantTrail)
         {
            double tr = RoundToTick(sym, ask + trailDist, 1);
            if(cand == 0 || tr < cand) cand = tr;
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
   // v1.25: our pending (deep limit) orders count too -> one per symbol
   for(int j = OrdersTotal()-1; j >= 0; j--)
   {
      ulong ot = OrderGetTicket(j);
      if(ot == 0 || !OrderSelect(ot)) continue;
      if(OrderGetString(ORDER_SYMBOL) == sym && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
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
   // v1.25: pending orders count toward MaxOpenTrades
   for(int j = OrdersTotal()-1; j >= 0; j--)
   {
      ulong ot = OrderGetTicket(j);
      if(ot == 0 || !OrderSelect(ot)) continue;
      if(OrderGetInteger(ORDER_MAGIC) == MagicNumber)
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
      plDirty = true;
   }

   bool   stop = false;
   string why  = "";

   if(dailyStartBalance > 0)
   {
      double lossPct = (dailyStartBalance - AccountInfoDouble(ACCOUNT_BALANCE)) / dailyStartBalance * 100.0;
      if(lossPct >= DailyLossLimitPercent)
      {
         stop = true;
         why  = "balance down " + DoubleToString(lossPct, 2) + "%";
      }
   }

   // v1.26: closed P/L today for this EA (server day)
   if(!stop && MaxDailyLossMoney > 0)
   {
      datetime nowT = TimeCurrent();
      if(plDirty || nowT - lastPLCalc >= 10)
      {
         todayClosedPL = TodayClosedPL();
         lastPLCalc = nowT;
         plDirty = false;
      }
      if(todayClosedPL <= -MaxDailyLossMoney)
      {
         stop = true;
         why  = "closed P/L today $" + DoubleToString(todayClosedPL, 2);
      }
   }

   if(stop && !dailyStopActive)
      Print("Daily loss stop hit (", why, "). No new entries until the next server day.");
   if(!stop && dailyStopActive)
      Print("Daily loss stop cleared - new server day.");
   dailyStopActive = stop;
   return !stop;
}

bool IsNewsTime()
{
   return false;
}
//+------------------------------------------------------------------+
