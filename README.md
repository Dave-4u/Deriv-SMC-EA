# Deriv-SMC-EA v1.23

**Multi-Pair MT5 Expert Advisor**  
Strategies: **CRT → Rejection Block → Order Block**  
with an H1 trend filter, setup-timeframe market structure, and 1-minute market-entry timing.

### New in v1.23
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
