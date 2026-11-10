# Deriv-SMC-EA v1.25

**Multi-Pair MT5 Expert Advisor**  
Strategies: **CRT → Rejection Block → Order Block**  
with an H1 trend filter, setup-timeframe market structure, and 1-minute market-entry timing.

### New in v1.25
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

### Trailing & Break-even
```
UseTrailingStop      = true
TrailingStart        = 1.0          // Start trailing after $1 profit
TrailingStep         = 0.5          // Trail by $0.5

UseBreakEven         = true
BreakEvenTrigger     = 1.5          // Move SL to BE after $1.5 profit
BreakEvenProfit      = 0.2          // Lock $0.2 profit
```

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
