# ══════════════════════════════════════════════════════
# WATCHLIST ENRICHMENT — add to update_dashboard.py
# Called in full_eod run after sector breadth
# ══════════════════════════════════════════════════════

def enrich_watchlist():
    """
    For every stock in watchlist table:
    1. Fetch 1yr daily candles via yfinance
    2. Compute 21 EMA, 50 EMA (≈10w), 200 EMA
    3. Compute % distance from each EMA
    4. Flag in_buy_range:
         price <= 10% above 21 EMA  AND
         price <= 15% above 10w EMA AND
         price <= 70% above 200 EMA
    5. Map sector from sector_stocks
    6. Pull sector_score from latest sector_breadth
    7. Upsert into watchlist_enriched
    """
    print("📋 Enriching watchlist...")

    # Load watchlist symbols
    resp = sb.table("watchlist").select("*").execute()
    stocks = resp.data or []
    if not stocks:
        print("   ⚠️  watchlist table is empty. Upload CSV via Admin Panel.\n")
        return

    # Load sector mapping (symbol → sector_key)
    sec_resp = sb.table("sector_stocks").select("symbol,sector_key,sector_name").execute()
    sec_map  = {r["symbol"]: {"key": r["sector_key"], "name": r["sector_name"]}
                for r in (sec_resp.data or [])}

    # Load latest sector scores
    sb_resp = sb.table("sector_breadth").select(
        "sector_key,regime_score,regime_label,sector_name"
    ).order("date", desc=True).limit(100).execute()
    score_map = {}
    seen_sectors = set()
    for r in (sb_resp.data or []):
        if r["sector_key"] not in seen_sectors:
            score_map[r["sector_key"]] = {
                "score": r["regime_score"],
                "label": r["regime_label"],
                "name":  r["sector_name"],
            }
            seen_sectors.add(r["sector_key"])

    results = []
    BATCH = 20

    for i in range(0, len(stocks), BATCH):
        batch = stocks[i:i+BATCH]
        syms  = [s["symbol"].strip().upper() + ".NS" for s in batch]
        sym_map = {s["symbol"].strip().upper(): s for s in batch}

        try:
            raw = yf.download(syms, period="1y", progress=False,
                              group_by="ticker", auto_adjust=True)
        except Exception as e:
            print(f"   ⚠️  Batch {i//BATCH+1} download failed: {e}")
            continue

        for stock in batch:
            sym_clean = stock["symbol"].strip().upper()
            sym_ns    = sym_clean + ".NS"
            try:
                # Extract close series
                if len(syms) == 1:
                    cl = raw["Close"]
                    if isinstance(cl, pd.DataFrame): cl = cl.iloc[:,0]
                else:
                    if sym_ns not in raw.columns.get_level_values(0): continue
                    cl = raw[sym_ns]["Close"]
                    if isinstance(cl, pd.DataFrame): cl = cl.iloc[:,0]
                cl = cl.dropna()
                if len(cl) < 50:
                    print(f"   ⚠️  {sym_clean}: insufficient data ({len(cl)} bars)")
                    continue

                cur = float(cl.iloc[-1])

                # Compute EMAs
                ema21  = float(cl.ewm(span=21,  adjust=False).mean().iloc[-1])
                ema50  = float(cl.ewm(span=50,  adjust=False).mean().iloc[-1])
                ema200 = float(cl.ewm(span=200, adjust=False).mean().iloc[-1]) if len(cl)>=200 else float(cl.ewm(span=200, adjust=False).mean().iloc[-1])
                ema10w = ema50  # 10-week ≈ 50-day

                # % distance from each EMA (positive = above, negative = below)
                pct21  = round((cur - ema21)  / ema21  * 100, 2)
                pct10w = round((cur - ema10w) / ema10w * 100, 2)
                pct200 = round((cur - ema200) / ema200 * 100, 2)

                # Buy range criteria (Minervini VCP / Stage 2 proximity)
                # Within 10% of 21 EMA (tight consolidation near support)
                # Within 15% of 10-week EMA (base structure)
                # Within 70% of 200 EMA (above long-term trend, not extended)
                in_buy_range = (
                    -5 <= pct21  <= 10  and   # not more than 5% below or 10% above 21 EMA
                    pct10w       <= 15  and   # within 15% of 10-week
                    0  <= pct200 <= 70        # above 200 EMA but not more than 70% extended
                )

                # Sector mapping
                sec     = sec_map.get(sym_clean, {})
                sec_key = sec.get("key")
                sec_nm  = sec.get("name")
                scores  = score_map.get(sec_key, {}) if sec_key else {}

                # Use CMP from yfinance if not available in CSV
                latest_price = float(stock.get("cur_price") or cur)
                latest_chg   = float(stock.get("price_change") or 0)
                latest_chgpct= float(stock.get("price_chg_pct") or 0)

                results.append({
                    "symbol":          sym_clean,
                    "company_name":    stock.get("company_name"),
                    "cur_price":       round(cur, 2),       # always use latest yf price
                    "price_change":    round(latest_chg, 2),
                    "price_chg_pct":   round(latest_chgpct, 2),
                    "rs_rating":       int(stock.get("rs_rating") or 0),
                    "ema_21":          round(ema21, 2),
                    "ema_50":          round(ema50, 2),
                    "ema_200":         round(ema200, 2),
                    "ema_10w":         round(ema10w, 2),
                    "pct_from_21ema":  pct21,
                    "pct_from_10wema": pct10w,
                    "pct_from_200ema": pct200,
                    "in_buy_range":    in_buy_range,
                    "sector_key":      sec_key,
                    "sector_name":     sec_nm,
                    "sector_score":    scores.get("score"),
                    "sector_label":    scores.get("label"),
                    "enriched_date":   TODAY,
                })

                status = "✅ BUY RANGE" if in_buy_range else "  —"
                print(f"   {status} {sym_clean}: 21EMA {pct21:+.1f}% | 10w {pct10w:+.1f}% | 200d {pct200:+.1f}%")

            except Exception as e:
                print(f"   ⚠️  {sym_clean}: {e}")
                continue

    if results:
        # Upsert in batches
        for i in range(0, len(results), 50):
            sb.table("watchlist_enriched").upsert(
                results[i:i+50], on_conflict="symbol"
            ).execute()
        in_range = sum(1 for r in results if r["in_buy_range"])
        print(f"   ✓ {len(results)} stocks enriched | {in_range} in buy range\n")
    else:
        print("   ⚠️  No results to save\n")
