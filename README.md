# Deriv-SMC-EA v1.2

**Multi-Pair MT5 Expert Advisor**  
Strategies: **CRT → Rejection Block → Order Block**  
with H1 Trend Filter

### New in v1.2
- Fixed compilation error (`iATR`)
- **Trailing Stop**
- **Break-even** feature
- **Optional News Filter**
- Ability to set **different risk per pair**
- Works on **Deriv Synthetics + Gold + Forex pairs**

---

## Quick Setup

1. Download latest `DerivSMC_EA.mq5`
2. Put it in `MQL5/Experts`
3. Compile (F7) — should show **0 errors**
4. Attach to **one** M5 chart only
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
