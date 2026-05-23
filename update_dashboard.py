"""
TraderHikes — Market Basecamp Data Pipeline
============================================
Smart scheduling — different jobs run at different times:

  10:00 AM IST  →  intraday update (CMP + index levels only)
  12:01 PM IST  →  intraday update (CMP + index levels only)
   2:00 PM IST  →  intraday update (CMP + index levels only)
   4:30 PM IST  →  full EOD run   (breadth + all steps)
   7:30 PM IST  →  FII/DII fetch  (NSE publishes ~6-7 PM)

GitHub Actions cron runs all times — the script decides
what to do based on the current IST hour.
"""

import os, sys, io, time, requests
import pandas as pd
import pytz
from datetime import datetime, timedelta

try:
    import yfinance as yf
except ImportError:
    os.system("pip install yfinance --quiet")
    import yfinance as yf

try:
    from supabase import create_client, Client
except ImportError:
    os.system("pip install supabase --quiet")
    from supabase import create_client, Client

# ════════════════════════════════════════════════════
# CONFIG
# ════════════════════════════════════════════════════
SUPABASE_URL         = os.environ.get("SUPABASE_URL", "https://kqndpeflwuztzhixibih.supabase.co")
SUPABASE_SERVICE_KEY = os.environ.get("SUPABASE_SERVICE_KEY")

if not SUPABASE_SERVICE_KEY:
    print("ERROR: SUPABASE_SERVICE_KEY not set"); sys.exit(1)

IST       = pytz.timezone("Asia/Kolkata")
NOW_IST   = datetime.now(IST)
TODAY     = NOW_IST.date()
TODAY_STR = TODAY.strftime("%Y-%m-%d")
HOUR_IST  = NOW_IST.hour
MINUTE_IST= NOW_IST.minute

sb: Client = create_client(SUPABASE_URL, SUPABASE_SERVICE_KEY)

# ── Determine run mode based on IST time ────────────
# 7-8 AM UTC  = 12:30-1:30 PM IST  → INTRADAY
# 9-10 AM UTC = 2:30-3:30 PM IST   → INTRADAY
# 11 AM UTC   = 4:30 PM IST        → FULL EOD
# 2 PM UTC    = 7:30 PM IST        → FII/DII

if HOUR_IST >= 19:        # 7 PM onwards
    RUN_MODE = "fii_dii"
elif HOUR_IST >= 16:      # 4 PM onwards
    RUN_MODE = "full_eod"
elif 9 <= HOUR_IST <= 15: # 9 AM - 3 PM
    RUN_MODE = "intraday"
else:
    RUN_MODE = "full_eod"  # default

# Allow manual override via environment variable
RUN_MODE = os.environ.get("RUN_MODE", RUN_MODE)

print(f"\n{'='*58}")
print(f"  Market Basecamp Pipeline — {TODAY_STR}")
print(f"  Time: {NOW_IST.strftime('%I:%M %p IST')} | Mode: {RUN_MODE.upper()}")
print(f"{'='*58}\n")


# ════════════════════════════════════════════════════
# STEP 0 — Fetch Nifty 500 list (full EOD only)
# ════════════════════════════════════════════════════
def fetch_nifty500_symbols():
    print("📋 Step 0: Fetching Nifty 500 list from NSE...")
    url = "https://archives.nseindia.com/content/indices/ind_nifty500list.csv"
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
        "Referer":    "https://www.nseindia.com/",
    }
    try:
        r = requests.get(url, headers=headers, timeout=30)
        r.raise_for_status()
        df = pd.read_csv(io.StringIO(r.text))
        if "Symbol" in df.columns:
            syms = df["Symbol"].str.strip().tolist()
            print(f"   ✓ {len(syms)} constituents downloaded\n")
            return syms
    except Exception as e:
        print(f"   ⚠️  NSE download failed: {e}. Using fallback.\n")
    return get_fallback_symbols()


def get_fallback_symbols():
    return [
        "RELIANCE","TCS","HDFCBANK","INFY","ICICIBANK","HINDUNILVR","ITC","SBIN",
        "BAJFINANCE","BHARTIARTL","KOTAKBANK","LT","AXISBANK","ASIANPAINT","MARUTI",
        "TITAN","SUNPHARMA","NESTLEIND","WIPRO","ULTRACEMCO","POWERGRID","NTPC",
        "HCLTECH","TECHM","TATAMOTORS","BAJAJFINSV","DIVISLAB","DRREDDY","CIPLA",
        "ADANIPORTS","HINDALCO","JSWSTEEL","TATASTEEL","ONGC","COALINDIA","BPCL",
        "IOC","GRASIM","BRITANNIA","HEROMOTOCO","EICHERMOT","BAJAJ-AUTO","SHREECEM",
        "UPL","TATACONSUM","INDUSINDBK","SBILIFE","HDFCLIFE","ICICIGI","APOLLOHOSP",
        "PERSISTENT","MPHASIS","COFORGE","LTIM","KPITTECH","TATAELXSI","CYIENT",
        "ABB","SIEMENS","HAVELLS","POLYCAB","DIXON","KAYNES","CUMMINSIND","THERMAX",
        "TRENT","DMART","MARICO","DABUR","GODREJCP","COLPAL","EMAMILTD",
        "TORNTPHARM","ALKEM","IPCALAB","AUROPHARMA","GLENMARK","BIOCON","LAURUSLABS",
        "FEDERALBNK","BANDHANBNK","IDFCFIRSTB","CANBK","BANKBARODA","PNB",
        "CHOLAFIN","MUTHOOTFIN","CDSL","CAMS","MOTHERSON","BOSCHLTD","BALKRISIND",
        "APOLLOTYRE","MRF","PIDILITIND","AARTIIND","ATUL","DEEPAKNTR","SRF",
        "DLF","GODREJPROP","OBEROIRLTY","PRESTIGE","IRCTC","CONCOR","ZOMATO",
        "NMDC","VEDL","NATIONALUM","RATNAMANI","LICI","STARHEALTH","INDIGO",
    ]


# ════════════════════════════════════════════════════
# STEP 1 — Fetch CMP for open trades
# ════════════════════════════════════════════════════
def fetch_cmp_for_open_trades():
    print("📈 Step 1: Updating CMP for open trades...")
    trades = sb.table("open_trades").select(
        "id,symbol,entry_price,quantity,sl_price").execute().data

    if not trades:
        print("   No open trades. Skipping.\n"); return {}

    print(f"   Found {len(trades)} trade(s): {[t['symbol'] for t in trades]}")
    cmp_map = {}

    for t in trades:
        sym = t["symbol"].upper().strip()
        try:
            hist = yf.Ticker(f"{sym}.NS").history(period="5d", interval="1d")
            if hist.empty: continue
            closes = hist["Close"].dropna()
            cmp = round(float(closes.iloc[-1]), 2)
            prev_cmp = round(float(closes.iloc[-2]), 2) if len(closes) >= 2 else cmp
            cmp_map[t["id"]] = cmp
            pnl = round((cmp - t["entry_price"]) * t["quantity"], 2)
            pct = round((cmp - t["entry_price"]) / t["entry_price"] * 100, 2)
            day_pnl = round((cmp - prev_cmp) * t["quantity"], 2)
            print(f"   ✓ {sym}: ₹{cmp:,.2f} | P&L: {'+'if pnl>=0 else ''}₹{pnl:,.0f} ({pct:+.2f}%) | Day: {'+'if day_pnl>=0 else ''}₹{day_pnl:,.0f}")
            sb.table("open_trades").update({
                "cmp": cmp, "updated_at": datetime.now(IST).isoformat()
            }).eq("id", t["id"]).execute()
        except Exception as e:
            print(f"   ⚠️  {sym}: {e}")

    print(f"   Updated {len(cmp_map)} position(s).\n")
    return cmp_map


# ════════════════════════════════════════════════════
# STEP 2 — Fetch index levels
# ════════════════════════════════════════════════════
def fetch_index_levels():
    print("📊 Step 2: Fetching index levels...")
    indices = {
        "nifty50":       "^NSEI",
        "sensex":        "^BSESN",
        "nifty500":      "^CRSLDX",
        "nifty_midcap":  "^NSEMDCP50",
        "nifty_it":      "^CNXIT",
        "nifty_bank":    "^NSEBANK",
        "nifty_pharma":  "^CNXPHARMA",
        "nifty_auto":    "^CNXAUTO",
        "nifty_psubank": "^CNXPSUBANK",
        "nifty_metal":   "^CNXMETAL",
        "nifty_realty":  "^CNXREALTY",
        "nifty_fmcg":    "^CNXFMCG",
        "india_vix":     "^INDIAVIX",
    }
    levels, prev = {}, {}
    for name, sym in indices.items():
        try:
            closes = yf.Ticker(sym).history(period="5d", interval="1d")["Close"].dropna()
            if len(closes) >= 1: levels[name] = round(float(closes.iloc[-1]), 2)
            if len(closes) >= 2: prev[name]   = round(float(closes.iloc[-2]), 2)
            chg = levels.get(name,0) - prev.get(name,0)
            pct = chg / prev[name] * 100 if prev.get(name) else 0
            print(f"   ✓ {name.upper():16s}: {levels.get(name,0):>10,.2f}  ({pct:+.2f}%)")
        except Exception as e:
            print(f"   ⚠️  {name}: {e}")

    if levels:
        row = {"snapshot_date": TODAY_STR}
        for k, v in levels.items():
            if k != "india_vix": row[k] = v
        for k, v in prev.items():
            if k != "india_vix": row[f"{k}_prev"] = v
        try:
            sb.table("index_levels").upsert(row, on_conflict="snapshot_date").execute()
            print(f"   ✓ Index levels saved for {TODAY_STR}")
        except Exception as e:
            print(f"   ⚠️  Save failed: {e}")

    print()
    return levels


# ════════════════════════════════════════════════════
# STEP 3 — Save portfolio snapshot (EOD only)
# ════════════════════════════════════════════════════
def save_portfolio_snapshot(cmp_map, index_levels):
    print("💼 Step 3: Saving portfolio snapshot...")
    trades = sb.table("open_trades").select("*").execute().data

    prev_snaps = sb.table("portfolio_snapshots")\
        .select("total_capital,snapshot_date")\
        .order("snapshot_date", desc=True).limit(2).execute().data

    total_capital = 2500000
    for s in prev_snaps:
        if s["snapshot_date"] != TODAY_STR and s["total_capital"]:
            total_capital = s["total_capital"]; break

    deployed       = sum(t["entry_price"] * t["quantity"] for t in trades)
    unrealised_pnl = sum((t["cmp"] - t["entry_price"]) * t["quantity"]
                         for t in trades if t.get("cmp"))
    cash_available  = total_capital - deployed
    portfolio_value = deployed + unrealised_pnl + cash_available

    first = sb.table("portfolio_snapshots")\
        .select("portfolio_value,snapshot_date")\
        .order("snapshot_date", desc=False).limit(1).execute().data

    cumulative_return = 0.0
    if first and first[0]["snapshot_date"] != TODAY_STR and first[0]["portfolio_value"]:
        base = first[0]["portfolio_value"]
        if base > 0: cumulative_return = round((portfolio_value - base) / base * 100, 2)

    snap = {
        "snapshot_date":         TODAY_STR,
        "total_capital":         round(total_capital, 2),
        "deployed":              round(deployed, 2),
        "cash_available":        round(cash_available, 2),
        "portfolio_value":       round(portfolio_value, 2),
        "nifty500_level":        index_levels.get("nifty500"),
        "cumulative_return_pct": cumulative_return,
    }
    sb.table("portfolio_snapshots").upsert(snap, on_conflict="snapshot_date").execute()

    print(f"   ✓ Total Capital:    ₹{total_capital:>12,.0f}")
    print(f"   ✓ Deployed:         ₹{deployed:>12,.0f}")
    print(f"   ✓ Unrealised P&L: {'+'if unrealised_pnl>=0 else ''}₹{unrealised_pnl:>11,.0f}")
    print(f"   ✓ Portfolio Value:  ₹{portfolio_value:>12,.0f}")
    print(f"   ✓ Return: {cumulative_return:+.2f}%")
    print(f"   Snapshot saved for {TODAY_STR}.\n")


# ════════════════════════════════════════════════════
# STEP 4 — Market breadth (EOD only)
# ════════════════════════════════════════════════════
def calculate_market_breadth(symbols, index_levels):
    print(f"📡 Step 4: Market breadth on {len(symbols)} stocks...")
    above_21=above_50=above_200=advancing=declining=new_high=new_low=processed=0
    BATCH = 20

    for i in range(0, len(symbols), BATCH):
        batch = symbols[i:i+BATCH]
        bn = i//BATCH+1; total_b = (len(symbols)+BATCH-1)//BATCH
        print(f"   Batch {bn}/{total_b}: {', '.join(batch[:4])}{'...' if len(batch)>4 else ''}")
        tickers = " ".join(f"{s}.NS" for s in batch)
        try:
            data = yf.download(tickers, period="1y", interval="1d",
                group_by="ticker", auto_adjust=True, progress=False, threads=True)
            for sym in batch:
                t = f"{sym}.NS"
                try:
                    close = data[t]["Close"].dropna() if len(batch)>1 else data["Close"].dropna()
                    if len(close) < 21: continue
                    last = float(close.iloc[-1])
                    prev = float(close.iloc[-2]) if len(close)>=2 else last
                    e21  = float(close.ewm(span=21, adjust=False).mean().iloc[-1])
                    e50  = float(close.ewm(span=50, adjust=False).mean().iloc[-1]) if len(close)>=50 else None
                    e200 = float(close.ewm(span=200,adjust=False).mean().iloc[-1]) if len(close)>=200 else None
                    if last > e21:  above_21  += 1
                    if e50  and last > e50:  above_50  += 1
                    if e200 and last > e200: above_200 += 1
                    if last > prev*1.001:  advancing += 1
                    elif last < prev*0.999: declining += 1
                    hi52 = float(close.max()); lo52 = float(close.min())
                    if last >= hi52*0.995: new_high += 1
                    if last <= lo52*1.005: new_low  += 1
                    processed += 1
                except: continue
        except Exception as e:
            print(f"   ⚠️  Batch error: {e}"); continue
        if i+BATCH < len(symbols): time.sleep(1)

    if processed == 0:
        print("   ⚠️  No stocks processed.\n"); return

    p21  = round(above_21/processed*100, 2)
    p50  = round(above_50/processed*100, 2)
    p200 = round(above_200/processed*100, 2)

    print(f"\n   ── Nifty 500 Breadth ────────────────")
    print(f"   Processed:      {processed} stocks")
    print(f"   Above 21  EMA:  {p21}%  ({above_21})")
    print(f"   Above 50  EMA:  {p50}%  ({above_50})")
    print(f"   Above 200 EMA:  {p200}% ({above_200})")
    print(f"   Advancing:      {advancing} | Declining: {declining}")
    print(f"   A/D Ratio:      {advancing/max(declining,1):.2f}")
    print(f"   52W Highs:      {new_high} | 52W Lows: {new_low}")

    sb.table("market_breadth").upsert({
        "snapshot_date":       TODAY_STR,
        "pct_above_21ema":     p21,
        "pct_above_50ema":     p50,
        "pct_above_200ema":    p200,
        "total_stocks":        processed,
        "above_21ema_count":   above_21,
        "above_50ema_count":   above_50,
        "above_200ema_count":  above_200,
        "advancing":           advancing,
        "declining":           declining,
        "new_52w_highs":       new_high,
        "new_52w_lows":        new_low,
        "nifty50_close":       index_levels.get("nifty50"),
        "india_vix":           index_levels.get("india_vix"),
    }, on_conflict="snapshot_date").execute()

    print(f"   Breadth saved for {TODAY_STR}.\n")


# ════════════════════════════════════════════════════
# STEP 5 — FII/DII Activity (7:30 PM run only)
# ════════════════════════════════════════════════════
def fetch_fii_dii():
    print("🏦 Step 5: Fetching FII/DII activity from NSE...")

    # NSE publishes provisional FII/DII data daily after market close
    # Official source: NSE India — FII/DII activity report
    url = "https://www.nseindia.com/api/fiidiiTradeReact"
    headers = {
        "User-Agent":      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        "Accept":          "application/json, text/plain, */*",
        "Accept-Language": "en-US,en;q=0.9",
        "Referer":         "https://www.nseindia.com/market-data/fii-dii-trade-history",
        "X-Requested-With":"XMLHttpRequest",
    }

    try:
        # NSE requires a session cookie — get it first
        session = requests.Session()
        session.get("https://www.nseindia.com", headers=headers, timeout=15)
        time.sleep(2)

        r = session.get(url, headers=headers, timeout=20)
        r.raise_for_status()
        data = r.json()

        if not data or not isinstance(data, list):
            raise ValueError("Unexpected response format")

        # Most recent entry (index 0 = today or most recent trading day)
        latest = data[0]

        # NSE field names
        date_str     = latest.get("date", TODAY_STR)
        fii_buy      = float(latest.get("fiiBuy",  0) or 0)
        fii_sell     = float(latest.get("fiiSell", 0) or 0)
        dii_buy      = float(latest.get("diiBuy",  0) or 0)
        dii_sell     = float(latest.get("diiSell", 0) or 0)
        fii_net      = round(fii_buy - fii_sell, 2)
        dii_net      = round(dii_buy - dii_sell, 2)

        # Parse date
        try:
            activity_date = datetime.strptime(date_str, "%d-%b-%Y").strftime("%Y-%m-%d")
        except:
            activity_date = TODAY_STR

        print(f"   Date:     {activity_date}")
        print(f"   FII Net:  {'+'if fii_net>=0 else ''}₹{fii_net:,.2f} Cr  "
              f"(Buy: ₹{fii_buy:,.2f} | Sell: ₹{fii_sell:,.2f})")
        print(f"   DII Net:  {'+'if dii_net>=0 else ''}₹{dii_net:,.2f} Cr  "
              f"(Buy: ₹{dii_buy:,.2f} | Sell: ₹{dii_sell:,.2f})")

        # Get Nifty close for context
        nifty_close = None
        try:
            closes = yf.Ticker("^NSEI").history(period="2d")["Close"].dropna()
            if not closes.empty: nifty_close = round(float(closes.iloc[-1]), 2)
        except: pass

        sb.table("fii_dii_activity").upsert({
            "activity_date": activity_date,
            "fii_cash_net":  fii_net,
            "fii_cash_buy":  fii_buy,
            "fii_cash_sell": fii_sell,
            "dii_cash_net":  dii_net,
            "dii_cash_buy":  dii_buy,
            "dii_cash_sell": dii_sell,
            "nifty_close":   nifty_close,
            "source":        "NSE",
            "updated_at":    datetime.now(IST).isoformat(),
        }, on_conflict="activity_date").execute()

        print(f"   ✓ FII/DII data saved for {activity_date}.\n")

    except Exception as e:
        print(f"   ⚠️  NSE API failed: {e}")
        print(f"   Trying alternative source (StockEdge / BSE)...\n")
        fetch_fii_dii_fallback()


def fetch_fii_dii_fallback():
    """
    Fallback: fetch FII/DII from BSE India which has a more stable API.
    """
    try:
        url = "https://api.bseindia.com/BseIndiaAPI/api/FIIDIIData/w"
        headers = {
            "User-Agent": "Mozilla/5.0",
            "Referer":    "https://www.bseindia.com/",
        }
        r = requests.get(url, headers=headers, timeout=15)
        r.raise_for_status()
        data = r.json()

        if not data: raise ValueError("Empty BSE response")

        # BSE format varies — try to extract first row
        row = data[0] if isinstance(data, list) else data
        fii_net = float(row.get("FII", row.get("fiiNet", 0)) or 0)
        dii_net = float(row.get("DII", row.get("diiNet", 0)) or 0)

        print(f"   ✓ FII Net (BSE): ₹{fii_net:,.2f} Cr")
        print(f"   ✓ DII Net (BSE): ₹{dii_net:,.2f} Cr")

        sb.table("fii_dii_activity").upsert({
            "activity_date": TODAY_STR,
            "fii_cash_net":  fii_net,
            "dii_cash_net":  dii_net,
            "source":        "BSE",
            "updated_at":    datetime.now(IST).isoformat(),
        }, on_conflict="activity_date").execute()

        print(f"   ✓ FII/DII saved from BSE fallback.\n")

    except Exception as e2:
        print(f"   ⚠️  Both NSE and BSE failed: {e2}")
        print(f"   FII/DII will need manual entry for today.\n")


# ════════════════════════════════════════════════════
# STEP 5b — Fetch OHLC candles for open trades
# ════════════════════════════════════════════════════
def fetch_candles_for_open_trades():
    print("🕯️  Step 5b: Fetching OHLC candles for open trades...")

    trades = sb.table("open_trades").select("id,symbol,entry_date").execute().data
    if not trades:
        print("   No open trades. Skipping.\n"); return

    for t in trades:
        sym = t["symbol"].upper().strip()
        try:
            # Fetch 180 days of daily OHLC — enough for any chart view
            ticker = yf.Ticker(f"{sym}.NS")
            hist   = ticker.history(period="180d", interval="1d", auto_adjust=True)

            if hist.empty:
                print(f"   ⚠️  No candle data for {sym}"); continue

            rows = []
            for dt, row in hist.iterrows():
                date_str = dt.strftime("%Y-%m-%d")
                rows.append({
                    "symbol": sym,
                    "date":   date_str,
                    "open":   round(float(row["Open"]),  2),
                    "high":   round(float(row["High"]),  2),
                    "low":    round(float(row["Low"]),   2),
                    "close":  round(float(row["Close"]), 2),
                    "volume": int(row["Volume"]) if row["Volume"] else 0,
                })

            # Upsert all rows — update existing, insert new
            # Supabase upsert in batches of 100
            batch_size = 100
            for i in range(0, len(rows), batch_size):
                sb.table("trade_candles").upsert(
                    rows[i:i+batch_size],
                    on_conflict="symbol,date"
                ).execute()

            print(f"   ✓ {sym}: {len(rows)} candles saved "
                  f"({rows[0]['date']} → {rows[-1]['date']})")

        except Exception as e:
            print(f"   ⚠️  {sym}: {e}")

    print()


# ════════════════════════════════════════════════════
# MAIN — Smart dispatch based on RUN_MODE
# ════════════════════════════════════════════════════
if __name__ == "__main__":
    try:
        if RUN_MODE == "intraday":
            print("⚡ INTRADAY MODE — CMP + Index Levels only\n")
            fetch_cmp_for_open_trades()
            fetch_index_levels()

        elif RUN_MODE == "fii_dii":
            print("🏦 FII/DII MODE — Fetching institutional flow data\n")
            fetch_fii_dii()

        else:
            # Full EOD run
            print("🌙 FULL EOD MODE — All steps\n")
            symbols = fetch_nifty500_symbols()
            fetch_cmp_for_open_trades()
            index_levels = fetch_index_levels()
            save_portfolio_snapshot({}, index_levels)
            calculate_market_breadth(symbols, index_levels)
            fetch_candles_for_open_trades()   # ← new candle step

        print("="*58)
        print(f"✅ {RUN_MODE.upper()} complete!")
        print(f"   {NOW_IST.strftime('%d %b %Y · %I:%M %p IST')}")
        print("="*58 + "\n")

    except Exception as e:
        print(f"\n❌ Pipeline failed: {e}")
        import traceback; traceback.print_exc()
        sys.exit(1)
