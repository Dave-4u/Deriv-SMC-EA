# Deriv-SMC-EA

**MT5 Expert Advisor for Deriv Synthetic Indices**  
Strategies: **Candle Range Theory (CRT)**, **Rejection Block**, **Order Block**  
with mandatory **H1 Trend Filter**. Optimized for small accounts.

---

## Features

- H1 Trend Filter (50 EMA + basic structure)
- M5 Setup Detection:
  1. CRT (highest priority)
  2. Rejection Block
  3. Order Block
- Strict alignment: only trade when setup direction matches H1 trend
- Risk per trade: 0.75% of balance (adjustable)
- Daily loss limit: 3%
- Cooldown when trend is misaligned
- Works on Deriv Synthetic Indices (Volatility, Boom, Crash, etc.)

---

## Quick Setup Instructions (Deriv MT5)

### 1. Download the EA
- Go to this repository
- Click the green **Code** button → **Download ZIP**
- Or clone it:
  ```bash
  git clone https://github.com/Dave-4u/Deriv-SMC-EA.git
  ```

### 2. Install on Deriv MT5
1. Open **Deriv MT5**
2. Click **File** → **Open Data Folder**
3. Go into `MQL5` → `Experts`
4. Copy `DerivSMC_EA.mq5` into the `Experts` folder
5. Close and reopen MetaEditor (or restart MT5)
6. In Navigator panel (Ctrl+N) you should now see **DerivSMC_EA**

### 3. Attach to Chart
1. Open any Deriv Synthetic chart (recommended: Volatility 75, Volatility 100, Boom 1000, Crash 500, etc.)
2. Set timeframe to **M5**
3. Drag **DerivSMC_EA** onto the chart
4. In the inputs tab, leave defaults for first test (or adjust risk)
5. Make sure **Allow Algo Trading** is enabled (button in toolbar)
6. Click OK

### 4. Important Settings (Inputs)

| Input                    | Default     | Recommendation for small account |
|--------------------------|-------------|----------------------------------|
| RiskPercent              | 0.75        | Keep between 0.5 – 1.0           |
| DailyLossLimitPercent    | 3.0         | Do not increase                  |
| MagicNumber              | 20261109    | Change if running multiple EAs   |
| MaxSpreadPoints          | 50          | Adjust per symbol                |
| EnableCRT                | true        | Keep on                          |
| EnableRejectionBlock     | true        | Keep on                          |
| EnableOrderBlock         | true        | Keep on                          |

### 5. Recommended Symbols (Deriv)
- Volatility 75 Index
- Volatility 100 Index
- Boom 1000 Index
- Crash 500 / Crash 1000 Index
- Volatility 25 / 50 (1s versions also work)

### 6. First Run Checklist
- [ ] Run on **Demo** account first for at least 3–7 days
- [ ] Confirm H1 trend filter is working (check Experts log)
- [ ] Start with RiskPercent = 0.5% if account is very small
- [ ] Never leave it unattended without daily loss limit

---

## How the Logic Works

1. Every new M5 candle the EA checks H1 trend.
2. If trend is Neutral → no trades.
3. Scans for CRT → Rejection Block → Order Block (in that priority).
4. Only takes the setup if its direction matches the H1 trend.
5. Places market order with calculated lot size based on Stop Loss distance and RiskPercent.
6. Sets Stop Loss and Take Profit automatically.

---

## Disclaimer

This EA is for educational and research purposes.  
Past performance does not guarantee future results.  
Trading synthetic indices involves significant risk of loss.  
Only trade with money you can afford to lose.

---

**Repository**: https://github.com/Dave-4u/Deriv-SMC-EA  
Built for small accounts with strict risk control.
