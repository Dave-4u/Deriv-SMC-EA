# Deriv-SMC-EA v1.28

**Multi-Pair MT5 Expert Advisor**  
Strategies: **CRT → Rejection Block → Order Block**  
with an H1 trend filter, setup-timeframe market structure, and 1-minute market-entry timing.

### New in v1.28
- **TP follows the pair's structure, with no fixed R multiple.** The bot targets the next level price can realistically reach:
  1. the nearest **unbroken** swing high (buys) or swing low (sells) on the setup chart (`EntryTF`, M5), meaning a level no later candle has traded through yet, so liquidity still rests there (equal highs and lows count)
  2. if there is none, the same on `StructureTPHTF` (H1)
  3. then any swing on M5, then any swing on H1
  4. only if no structure level exists at all: `RR_Ratio` (3R)

  Levels closer than `MinTP_R` (2.5R) are skipped, and the bot looks further out. TP sits `StructureTPBufferATR` × ATR before the level so it fills.
- `MaxTP_R` now defaults to **0 = no cap, TP goes to structure**. It is kept only as an optional safety cap.
- Deep-limit TP uses the same structure target (at least where a market entry's TP would be).
- `RunnerRemoveTP` (off by default): after a real partial close, it moves the TP to the **next structure level beyond** the current TP, or to `MaxTP_R` if a cap is set.
- SL, lot size, and $ risk logic are unchanged.

### New in v1.27
- **Bigger targets**: `RR_Ratio` is now 3.0 (was 2.0).
- **Structure TP from the setup chart** (`UseStructureTP`): TP goes to the nearest swing high (buys) or swing low (sells) on the same chart the setup came from (`EntryTF`, M5), looking back `StructureTPLookback` (100) bars. The swing is only used if it is at least `MinTP_R` (2.5R) away. TP is set `StructureTPBufferATR` (0.1) × ATR before the swing so it fills, and it can be capped by `MaxTP_R` (see v1.28). If there is no such swing, TP = `RR_Ratio` × SL distance. The TP never changes the SL or the lot size, so the $ risk is the same.
- **Deep limit TP**: the TP is placed where a market entry's TP would have been (or further). That is at least `RR_Ratio` × the normal 1.5 ATR SL distance from the limit price, so a tight-stop limit gets a big R.
- **Let winners run**:
  - Break-even moves at `BreakEvenAtR` 1.5R (was 1.0) and locks `BreakEvenLockR` 0.3R (was 0.1).
  - Trailing starts at `TrailStartR` 2.0R (was 1.5) and trails `TrailATRMult` 2.0 (was 1.5) × ATR(`TrailATRTF`, M5 by default).
- **Partial close** (`UsePartialClose`): at `PartialCloseAtR` (2R) it closes `PartialClosePercent` (50%) and the rest keeps running.
  - It is skipped safely if the lot can't be split into min-lot steps (for example, a min-lot trade), or if the account is netting.
  - It runs once per trade and is remembered across restarts.
- **Runner TP** (`RunnerRemoveTP`, off by default): after a real partial close, the TP is moved further out (see v1.28).
- **Entry alignment** (`UseEntryAlignment`): this check runs right before ANY order (market or deep limit). For a BUY:
  - the last closed M1 bar is bullish and closes above the prior M1 high
  - M1 EMA `AlignFastEMA` (9) is above EMA `AlignSlowEMA` (21)
  - bid is above the 9 EMA
  - price is not more than `MaxChaseATR` × ATR past the setup zone

  A SELL is the mirror. If any rule fails, the setup waits up to `AlignWaitBars` (5) M1 bars, then it is dropped with the reason in the log.
- All v1.25/v1.26 safety stays the same: strict $ risk with the `OrderCalcProfit` check, broker min distance, invalid-stops cooldown, modify throttle and back-off, daily $ stop, symbol pause, spike filter, deep limit fallback.
- **Gold note**: if XAUUSD never trades, the min lot at a 1.5 ATR M5 stop probably risks more than $3. `CustomRiskList = XAUUSD:5` would allow it (at $5 risk).

### New in v1.26
- **Spike-direction filter** (`UseSpikeDirectionFilter`): no SELLs on Boom or DEX … UP, and no BUYs on Crash or DEX … DOWN. These are the trades that got run through their SL by spikes.
- **Smaller risk on spike symbols**: Boom, Crash, DEX and Jump use `SpikeRiskMoney` ($2). Other symbols keep `RiskMoney` ($3), and `CustomRiskList` still overrides both.
- **R-based exits**: R is the trade's initial risk (entry to the first SL).
  - Break-even moves when profit reaches `BreakEvenAtR` (1R) and locks `BreakEvenLockR` (0.1R) plus the spread.
  - Trailing starts at `TrailStartR` (1.5R) and trails `TrailATRMult` × ATR(EntryTF), so winners can run.
  - R is saved per ticket in a terminal global variable. If that is missing (for example after a restart on another terminal), it is read back from the opening order's SL in history.
  - The v1.25 modify safety still applies: minimum distance, throttle, and no resending a refused SL.
- **Deep limit at levels**: when even the min lot risks too much at market, the bot looks for a limit price in three places:
  - the setup candles
  - recent swing support (for buys) or resistance (for sells) on EntryTF, ConfirmTF (M15) and TrendTF (H1)
  - anywhere within `DeepLevelTolATR` × ATR of one of those levels

  The limit is moved back from the market to the broker's minimum distance instead of being rejected as "too close". Expiry and cancelling on a trend flip work as before.
- **Daily $ stop**: once the EA's closed P/L today (by server day, for this magic number) reaches -`MaxDailyLossMoney` ($9), it takes no new entries and cancels its pending limits until the next server day.
- **Per-symbol pause**: after `ConsecLossPause` (2) losses in a row on one symbol, that symbol is skipped for `SymbolPauseHours` (3). Losing streaks are rebuilt from history when the EA restarts.
- **M15 trend check**: the M15 EMA trend (`ConfirmTF`) must agree with H1 (`UseConfirmTFTrend`).
- `MaxOpenTrades` now defaults to 3, and pending limits count toward it.
- **No chasing**: skip if the last closed M1 or M5 bar is bigger than `BigCandleATRMult` (2) × ATR(14). Also skip if price is more than `MaxChaseATR` (0.5) × ATR beyond the setup zone in the trade direction.

### From v1.25
- Entries respect the broker's stop and freeze levels plus a spread buffer, with SL/TP rounded to tick size and placed on the correct side of bid/ask. If the SL has to be widened, the lot is recalculated so the trade still risks no more than `RiskMoney`. TP moves out to keep the same RR.
- Strict $ risk: the lot is based on the final SL measured from the real entry price (ask or bid, so spread is included) plus `Slippage`. It uses the larger of `TICK_VALUE_LOSS` and `TICK_VALUE`, rounds down to the volume step, and re-checks the loss at SL with `OrderCalcProfit`. If the loss is still above `RiskMoney`, the lot is reduced, and the trade is skipped if min lot still risks too much.
- Deep limit fallback (`UseDeepLimitFallback`, default on): when even the min lot would risk more than `RiskMoney` at market, the bot places a Buy/Sell Limit closer to the same SL, so that the min lot loses no more than `RiskMoney` at SL. TP is re-based to keep the RR. The order is placed only if the limit price is inside the setup zone (the CRT, rejection, or OB candles) and respects stop levels. It expires after `LimitExpireMinutes` (default 60), at the broker if the symbol supports expiry and otherwise cancelled by the bot, and it is deleted if the H1 trend flips. Pending orders count toward `MaxOpenTrades` and the one-per-symbol rule. Look for `deep limit fallback` lines in the log.
- A symbol whose entry is rejected with `[invalid stops]` pauses for `InvalidStopsCooldownMin` minutes, and the next try uses a wider buffer.
- Break-even and trailing are combined into one SL update that runs only when it locks at least `TrailMinImproveMoney` more. It is skipped when the TP is about to be hit, never resends an SL the broker refused, is throttled per ticket (`ModifyMinSeconds`), and backs off after rejections.

### From v1.24
- Reads a symbols `.txt` from `MQL5\Files` (default `DaveSymbols.txt`: one name per line or comma-separated, `#` comments). Falls back to SymbolsList if the file is missing or empty.

### Also in v1.23
- Keeps spaces in symbol names (`Volatility 75 Index` no longer becomes `Volatility75Index`)
- MQL5-safe position counting (max-open and one-per-symbol checks)
- Lot size is not rounded up past your `$` risk; the trade is skipped if min lot would exceed it
- Trailing stop and break-even use dollar amounts correctly (not raw price offsets)
- Uses each symbol's supported filling mode instead of always forcing IOC
- Market structure on the setup timeframe must agree with the H1 trend
- Setups enter at market after a confirming 1-minute bar (or immediately if you turn M1 timing off)

---

## Quick Setup

1. Download latest `DerivSMC_EA.mq5`
2. Put it in `MQL5/Experts`
3. Compile (F7) — should show **0 errors**
4. Attach to **one** chart only (the bot scans all symbols in the list)
5. Fill the symbols list and set your risk

---

## Important Inputs

### Multi-Pair & Risk
```
SymbolsList          = Volatility 75 Index,Volatility 100 Index,Boom 1000 Index,Crash 500 Index,XAUUSD
RiskMoney            = 3.0          // Default risk in $
MaxOpenTrades        = 10
```

You can also set individual risk using the format:
```
Symbol:Risk,Symbol:Risk
Example: Volatility 75 Index:3,XAUUSD:5,Boom 1000 Index:2.5
```

### Symbols file
```
SymbolsFromFile      = true         // Read names from a .txt in MQL5\Files
SymbolsFile          = DaveSymbols.txt
```

Put `DaveSymbols.txt` in the terminal's `MQL5\Files` folder (same file your other EA uses is fine). One symbol per line, or comma-separated; lines starting with `#` are ignored. The list is loaded only when the EA starts, so after you edit the file, remove it from the chart and attach it again. If the file is missing or empty, the bot uses `SymbolsList` instead.

### Timeframes, structure, and M1 timing
```
TrendTF              = H1           // Trend filter
EntryTF              = M5           // Setup timeframe (strategies + structure)
ExecTF               = M1           // Market-entry timing
UseMarketStructure   = true         // Structure must agree with the trend
UseM1EntryTiming     = true         // Wait for a confirming M1 bar
SetupExpireM1Bars    = 15           // Drop the setup if no M1 confirm in time
```

Set `UseM1EntryTiming` to false to enter at market as soon as the setup appears.

### Break-even & Trailing (v1.26, R = initial risk)
```
UseBreakEven         = true
BreakEvenAtR         = 1.0          // Move SL to BE at +1R
BreakEvenLockR       = 0.1          // Lock 0.1R + spread

UseTrailingStop      = true
TrailStartR          = 1.5          // Start trailing at +1.5R
TrailATRMult         = 1.5          // Trail 1.5 x ATR(EntryTF) behind price
```

### Risk, protection & filters (v1.26)
```
SpikeRiskMoney          = 2.0       // Risk for Boom/Crash/DEX/Jump
MaxOpenTrades           = 3         // Positions + pending limits
MaxDailyLossMoney       = 9.0       // Stop new entries after -$9 closed today (0 = off)
ConsecLossPause         = 2         // Losses in a row before pausing a symbol (0 = off)
SymbolPauseHours        = 3
UseSpikeDirectionFilter = true
ConfirmTF               = M15
UseConfirmTFTrend       = true
UseBigCandleFilter      = true
BigCandleATRMult        = 2.0
MaxChaseATR             = 0.5       // 0 = off
DeepLimitLookback       = 50        // Bars to search for swing levels
DeepLevelTolATR         = 0.2       // Limit may sit within 0.2 ATR of a level
DeepLimitRequireLevel   = true      // false = any price within the $ cap
```

### Recommended symbols (for now)
Live results suggest leaving out the **Step Indices**, **Range Break 200** and **DEX 900 UP** for now: their min lot is too big for a $3 stop, or they keep spiking against entries. To do that, delete or `#`-comment those lines in `DaveSymbols.txt`, for example:
```
# Step Index 200
# Range Break 200 Index
# DEX 900 UP Index
```
Edit the file yourself in `MQL5\Files`. The EA never changes it.

### Broker stop levels (v1.25)
```
StopsSpreadBuffer       = 1.0       // Spreads added to the broker min stop distance
ExtraStopBufferPoints   = 0         // Extra points on top
InvalidStopsCooldownMin = 30        // Pause a symbol after an [invalid stops] entry
ModifyMinSeconds        = 3         // Min seconds between SL updates per trade
ModifyMaxBackoffSec     = 300       // Max wait after repeated rejections
TrailMinImproveMoney    = 0.10      // Move SL only if it locks $0.10 more
```

### News Filter (Optional)
```
UseNewsFilter        = false        // Set to true if you want it
NewsMinutesBefore    = 30
NewsMinutesAfter     = 30
```

---

## Supported Markets
- All Deriv Synthetic Indices
- Gold (XAUUSD)
- Forex pairs (EURUSD, GBPUSD, etc.)
- Most CFD symbols on Deriv MT5

---

**Repository**: https://github.com/Dave-4u/Deriv-SMC-EA
