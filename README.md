# Deriv-SMC-EA (Multi-Pair)

**MT5 Expert Advisor for Deriv Synthetic Indices**  
Strategies: CRT → Rejection Block → Order Block  
with mandatory H1 Trend Filter.

Now supports **multiple pairs** from a single chart.

---

## Key Features

- Multi-pair scanner (you choose which symbols)
- Fixed dollar risk (default **$3** per trade — easy to change)
- Max open trades across all pairs: **10**
- H1 Trend Filter + M5 setups
- Priority: CRT > Rejection Block > Order Block
- Daily loss protection still active

---

## How to Use (Updated)

### 1. Install
Same as before:
1. Download the latest `DerivSMC_EA.mq5`
2. Put it in `MQL5/Experts`
3. Restart MT5 / Refresh Navigator

### 2. Attach to ONE chart only
- Open any Synthetic chart (e.g. Volatility 75) on **M5**
- Drag the EA onto that chart
- You only need **one** chart running

### 3. Important Inputs (new ones)

| Input                  | Default Value                          | Meaning                              |
|------------------------|----------------------------------------|--------------------------------------|
| **Symbols**            | Volatility 75 Index,Volatility 100 Index,Boom 1000 Index,Crash 500 Index | List of pairs (comma separated)     |
| **RiskMoney**          | 3.0                                    | Maximum $ you want to risk per trade |
| **MaxOpenTrades**      | 10                                     | Maximum total open positions         |
| RiskPercent            | (disabled)                             | No longer used                       |
| DailyLossLimitPercent  | 3.0                                    | Still active                         |

**How to edit the pairs list:**
Just type the exact symbol names separated by commas (no spaces after comma is safer):
```
Volatility 75 Index,Volatility 100 Index,Boom 1000 Index,Crash 500 Index,Volatility 25 Index
```

### 4. Recommended Starting Symbols
- Volatility 75 Index
- Volatility 100 Index
- Boom 1000 Index
- Crash 500 Index
- Crash 1000 Index
- Volatility 50 Index

---

## Risk Notes (Small Account)

- Default risk is **$3** per trade
- You can change `RiskMoney` anytime in the inputs
- Max 10 open trades total across all pairs
- Daily loss limit still protects you

---

## Disclaimer
Trading involves risk. This EA is for educational purposes. Always test on Demo first.
