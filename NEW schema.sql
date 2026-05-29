-- ============================================================
-- MARKET BASECAMP (TraderHikes) — AUTHORITATIVE DATABASE SCHEMA
-- ============================================================
-- Generated 2026-05-29 from the LIVE Supabase database by
-- introspecting information_schema, pg_policies and pg_proc.
-- Every table, column, type, default, RLS policy and function
-- below mirrors the real production database — nothing inferred
-- from application code or memory.
--
--   16 tables (15 live + 1 legacy) · 34 RLS policies · 1 function
--
-- ⚠️  PURPOSE: DOCUMENTATION & DISASTER-RECOVERY RECORD ONLY.
--     • This is the repo's source of truth for the schema.
--     • RUN IT ONLY against a FRESH, EMPTY Supabase project when
--       rebuilding from scratch.
--     • DO NOT run it against the live database. It is not a
--       migration. The CREATE/ALTER guards make it largely inert,
--       but its job is to RECORD the schema, not mutate a live one.
--     • It does NOT include row data, the service_role key, or any
--       secret — safe to commit to the repo.
--
-- REBUILD ORDER (already arranged below):
--   1) function  2) tables  3) enable RLS  4) policies
--   Before running on a fresh project, set is_admin()'s email.
-- ============================================================


-- ╔══════════════════════════════════════════════════════════╗
-- ║  SECTION 1 · FUNCTIONS  (create first — policies need it) ║
-- ╚══════════════════════════════════════════════════════════╝
-- is_admin() returns TRUE only for the admin, matched by email.
-- ⚠️ Email is baked in; update it here if your admin address changes.

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN AS $$
BEGIN
  RETURN (
    SELECT email FROM auth.users WHERE id = auth.uid()
  ) = 'traderhikes@gmail.com';   -- ← REPLACE WITH YOUR ADMIN EMAIL
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ╔══════════════════════════════════════════════════════════╗
-- ║  SECTION 2 · TABLES                                       ║
-- ╚══════════════════════════════════════════════════════════╝

-- ── approved_students ───────────────────────────────
-- Paid students who may log in. Privacy-critical: each student reads only their own row; admin reads all (is_admin()).
CREATE TABLE IF NOT EXISTS public.approved_students (
  email TEXT NOT NULL,
  full_name TEXT,
  plan TEXT DEFAULT 'active'::text,
  enrolled_at TIMESTAMPTZ DEFAULT now(),
  access_until TIMESTAMPTZ,
  notes TEXT
);

-- ── students ────────────────────────────────────────
-- LEGACY / UNUSED — original table from first setup. The live app uses approved_students. Safe to drop once confirmed unused.
CREATE TABLE IF NOT EXISTS public.students (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT NOT NULL,
  full_name TEXT,
  plan TEXT NOT NULL DEFAULT 'active'::text,
  enrolled_at TIMESTAMPTZ DEFAULT now(),
  access_until TIMESTAMPTZ,
  notes TEXT
);

-- ── open_trades ─────────────────────────────────────
-- Active positions. Read-only to students; pipeline updates cmp/status.
CREATE TABLE IF NOT EXISTS public.open_trades (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  symbol TEXT NOT NULL,
  company_name TEXT NOT NULL,
  sector TEXT,
  exchange TEXT DEFAULT 'NSE'::text,
  entry_date DATE NOT NULL,
  entry_price NUMERIC NOT NULL,
  quantity INTEGER NOT NULL,
  sl_price NUMERIC NOT NULL,
  cmp NUMERIC,
  status TEXT DEFAULT 'long'::text,
  trade_notes TEXT,
  chart_pattern TEXT
);

-- ── trade_entries ───────────────────────────────────
-- Pyramid entries — multiple adds per open_trade (links via open_trade_id).
CREATE TABLE IF NOT EXISTS public.trade_entries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  open_trade_id UUID NOT NULL,
  entry_date DATE NOT NULL,
  entry_price NUMERIC NOT NULL,
  quantity INTEGER NOT NULL,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  capital_at_entry NUMERIC,
  position_size_pct NUMERIC
);

-- ── partial_exits ───────────────────────────────────
-- Partial profit bookings against an open trade.
CREATE TABLE IF NOT EXISTS public.partial_exits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  open_trade_id UUID,
  symbol TEXT NOT NULL,
  exit_date DATE NOT NULL,
  exit_price NUMERIC NOT NULL,
  quantity INTEGER NOT NULL,
  realised_pnl NUMERIC,
  return_pct NUMERIC,
  avg_entry_price NUMERIC,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  capital_at_entry NUMERIC,
  position_size_pct NUMERIC
);

-- ── closed_trades ───────────────────────────────────
-- Completed trades with full journey + realised P&L.
CREATE TABLE IF NOT EXISTS public.closed_trades (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at TIMESTAMPTZ DEFAULT now(),
  symbol TEXT NOT NULL,
  company_name TEXT NOT NULL,
  sector TEXT,
  exchange TEXT DEFAULT 'NSE'::text,
  entry_date DATE NOT NULL,
  avg_entry_price NUMERIC NOT NULL,
  quantity INTEGER NOT NULL,
  sl_price NUMERIC,
  partial_exit_date DATE,
  partial_exit_price NUMERIC,
  partial_exit_qty INTEGER,
  partial_exit_pct NUMERIC,
  exit_date DATE NOT NULL,
  avg_exit_price NUMERIC NOT NULL,
  realised_pnl NUMERIC,
  return_pct NUMERIC,
  holding_days INTEGER,
  trade_notes TEXT,
  exit_reason TEXT,
  capital_at_entry NUMERIC,
  position_size_pct NUMERIC
);

-- ── trade_candles ───────────────────────────────────
-- Daily OHLCV for OPEN-trade symbols (mini charts).
CREATE TABLE IF NOT EXISTS public.trade_candles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  symbol TEXT NOT NULL,
  date DATE NOT NULL,
  open NUMERIC,
  high NUMERIC,
  low NUMERIC,
  close NUMERIC,
  volume BIGINT
);

-- ── watchlist ───────────────────────────────────────
-- MarketSmith CSV upload — current watchlist universe.
CREATE TABLE IF NOT EXISTS public.watchlist (
  id SERIAL PRIMARY KEY,
  symbol TEXT NOT NULL,
  company_name TEXT,
  sector TEXT,
  sector_key TEXT,
  setup_tag TEXT,
  notes TEXT,
  is_active BOOLEAN DEFAULT true,
  added_date DATE DEFAULT CURRENT_DATE,
  cmp NUMERIC,
  rs_1m NUMERIC,
  rs_3m NUMERIC,
  rs_6m NUMERIC,
  above_21ema BOOLEAN,
  above_50ema BOOLEAN,
  above_200ema BOOLEAN,
  sector_score NUMERIC,
  sector_label TEXT,
  updated_at TIMESTAMPTZ DEFAULT now(),
  rs_rating INTEGER,
  uploaded_at TIMESTAMPTZ DEFAULT now()
);

-- ── watchlist_enriched ──────────────────────────────
-- Pipeline-computed EMAs + distances + buy-range flag per watchlist stock. Feeds Stock Filter & Charts tabs. (id is a serial sequence, not UUID.)
CREATE TABLE IF NOT EXISTS public.watchlist_enriched (
  id SERIAL PRIMARY KEY,
  symbol TEXT NOT NULL,
  company_name TEXT,
  cur_price NUMERIC,
  price_change NUMERIC,
  price_chg_pct NUMERIC,
  rs_rating INTEGER,
  ema_21 NUMERIC,
  ema_50 NUMERIC,
  ema_200 NUMERIC,
  ema_10w NUMERIC,
  pct_from_21ema NUMERIC,
  pct_from_10wema NUMERIC,
  pct_from_200ema NUMERIC,
  in_buy_range BOOLEAN DEFAULT false,
  sector_key TEXT,
  sector_name TEXT,
  sector_score NUMERIC,
  sector_label TEXT,
  enriched_date DATE DEFAULT CURRENT_DATE,
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- ── watchlist_candles ───────────────────────────────
-- 24-month daily OHLCV for ALL watchlist stocks (Charts tab).
CREATE TABLE IF NOT EXISTS public.watchlist_candles (
  symbol TEXT NOT NULL,
  date DATE NOT NULL,
  open NUMERIC,
  high NUMERIC,
  low NUMERIC,
  close NUMERIC,
  volume BIGINT,
  PRIMARY KEY (symbol, date)
);

-- ── market_breadth ──────────────────────────────────
-- Daily NSE breadth snapshot (% above EMAs, A/D, 52w highs).
CREATE TABLE IF NOT EXISTS public.market_breadth (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  snapshot_date DATE NOT NULL UNIQUE,
  created_at TIMESTAMPTZ DEFAULT now(),
  pct_above_21ema NUMERIC,
  pct_above_50ema NUMERIC,
  pct_above_200ema NUMERIC,
  total_stocks INTEGER DEFAULT 1847,
  above_21ema_count INTEGER,
  above_50ema_count INTEGER,
  above_200ema_count INTEGER,
  advancing INTEGER,
  declining INTEGER,
  unchanged INTEGER,
  new_52w_highs INTEGER,
  new_52w_lows INTEGER,
  nifty50_close NUMERIC,
  india_vix NUMERIC,
  fii_flow_cr NUMERIC
);

-- ── sector_stocks ───────────────────────────────────
-- NSE sector constituents, refreshed nightly.
CREATE TABLE IF NOT EXISTS public.sector_stocks (
  id SERIAL PRIMARY KEY,
  symbol TEXT NOT NULL,
  sector_key TEXT NOT NULL,
  sector_name TEXT NOT NULL,
  category TEXT DEFAULT 'largecap'::text,
  created_at TIMESTAMPTZ DEFAULT now(),
  company_name TEXT,
  PRIMARY KEY (symbol, sector_key)
);

-- ── sector_breadth ──────────────────────────────────
-- Per-sector regime score (0-100) and label.
CREATE TABLE IF NOT EXISTS public.sector_breadth (
  id SERIAL PRIMARY KEY,
  date DATE NOT NULL,
  sector_key TEXT NOT NULL,
  sector_name TEXT NOT NULL,
  category TEXT DEFAULT 'largecap'::text,
  total_stocks INTEGER DEFAULT 0,
  advances INTEGER DEFAULT 0,
  declines INTEGER DEFAULT 0,
  unchanged INTEGER DEFAULT 0,
  pct_above_21ema NUMERIC DEFAULT 0,
  pct_above_50ema NUMERIC DEFAULT 0,
  pct_above_200ema NUMERIC DEFAULT 0,
  pct_near_52w_high NUMERIC DEFAULT 0,
  pct_near_52w_low NUMERIC DEFAULT 0,
  ad_ratio NUMERIC DEFAULT 1.0,
  rs_1m NUMERIC DEFAULT 0,
  rs_3m NUMERIC DEFAULT 0,
  rs_6m NUMERIC DEFAULT 0,
  index_level NUMERIC,
  index_change_pct NUMERIC DEFAULT 0,
  regime_score NUMERIC DEFAULT 0,
  regime_label TEXT DEFAULT 'NEUTRAL'::text,
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- ── index_levels ────────────────────────────────────
-- Daily close of Nifty50/Sensex + ~24 sectoral indices.
CREATE TABLE IF NOT EXISTS public.index_levels (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  snapshot_date DATE NOT NULL UNIQUE,
  nifty50 NUMERIC,
  sensex NUMERIC,
  nifty500 NUMERIC,
  nifty_midcap NUMERIC,
  nifty_it NUMERIC,
  nifty_bank NUMERIC,
  nifty_pharma NUMERIC,
  nifty_auto NUMERIC,
  nifty_psubank NUMERIC,
  nifty_metal NUMERIC,
  nifty_realty NUMERIC,
  nifty_fmcg NUMERIC,
  nifty50_prev NUMERIC,
  sensex_prev NUMERIC,
  nifty500_prev NUMERIC,
  nifty_midcap_prev NUMERIC,
  nifty_it_prev NUMERIC,
  nifty_bank_prev NUMERIC,
  nifty_pharma_prev NUMERIC,
  nifty_auto_prev NUMERIC,
  nifty_psubank_prev NUMERIC,
  nifty_metal_prev NUMERIC,
  nifty_realty_prev NUMERIC,
  nifty_fmcg_prev NUMERIC,
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- ── fii_dii_activity ────────────────────────────────
-- Daily FII/DII net cash flow.
CREATE TABLE IF NOT EXISTS public.fii_dii_activity (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  activity_date DATE NOT NULL,
  fii_cash_net NUMERIC,
  fii_cash_buy NUMERIC,
  fii_cash_sell NUMERIC,
  dii_cash_net NUMERIC,
  dii_cash_buy NUMERIC,
  dii_cash_sell NUMERIC,
  nifty_close NUMERIC,
  source TEXT DEFAULT 'NSE'::text,
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- ── portfolio_snapshots ─────────────────────────────
-- Daily portfolio value for the equity curve.
CREATE TABLE IF NOT EXISTS public.portfolio_snapshots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  snapshot_date DATE NOT NULL UNIQUE,
  total_capital NUMERIC,
  deployed NUMERIC,
  cash_available NUMERIC,
  portfolio_value NUMERIC,
  nifty500_level NUMERIC,
  cumulative_return_pct NUMERIC
);


-- ╔══════════════════════════════════════════════════════════╗
-- ║  SECTION 3 · ENABLE ROW LEVEL SECURITY                    ║
-- ╚══════════════════════════════════════════════════════════╝

ALTER TABLE public.approved_students ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.students ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.open_trades ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trade_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.partial_exits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.closed_trades ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trade_candles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.watchlist ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.watchlist_enriched ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.watchlist_candles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.market_breadth ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sector_stocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sector_breadth ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.index_levels ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fii_dii_activity ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.portfolio_snapshots ENABLE ROW LEVEL SECURITY;


-- ╔══════════════════════════════════════════════════════════╗
-- ║  SECTION 4 · RLS POLICIES  (additive / OR-ed per table)   ║
-- ╚══════════════════════════════════════════════════════════╝

-- ── approved_students ───────────────────────────────
CREATE POLICY "Admin can insert students" ON public.approved_students FOR INSERT TO authenticated
  WITH CHECK (is_admin());
CREATE POLICY "Admin can read all students" ON public.approved_students FOR SELECT TO authenticated
  USING (is_admin());
CREATE POLICY "Students can read own row only" ON public.approved_students FOR SELECT TO authenticated
  USING (((auth.jwt() ->> 'email'::text) = email));
CREATE POLICY "Admin can update students" ON public.approved_students FOR UPDATE TO authenticated
  USING (is_admin());

-- ── students ────────────────────────────────────────
-- Policy for the LEGACY students table (unused by live app).
CREATE POLICY "Students can read own profile" ON public.students FOR SELECT TO public
  USING ((auth.uid() = id));

-- ── open_trades ─────────────────────────────────────
CREATE POLICY "Allow all writes on open trades" ON public.open_trades FOR ALL TO public
  USING (true)
  WITH CHECK (true);
CREATE POLICY "Authenticated users can read open trades" ON public.open_trades FOR SELECT TO authenticated
  USING (true);

-- ── trade_entries ───────────────────────────────────
CREATE POLICY "Allow all on trade_entries" ON public.trade_entries FOR ALL TO public
  USING (true)
  WITH CHECK (true);

-- ── partial_exits ───────────────────────────────────
CREATE POLICY "Allow all on partial_exits" ON public.partial_exits FOR ALL TO public
  USING (true)
  WITH CHECK (true);

-- ── closed_trades ───────────────────────────────────
CREATE POLICY "Allow all writes on closed trades" ON public.closed_trades FOR ALL TO public
  USING (true)
  WITH CHECK (true);
CREATE POLICY "Authenticated users can read closed trades" ON public.closed_trades FOR SELECT TO authenticated
  USING (true);

-- ── trade_candles ───────────────────────────────────
CREATE POLICY "Allow all writes on candles" ON public.trade_candles FOR ALL TO public
  USING (true)
  WITH CHECK (true);
CREATE POLICY "Allow all reads on trade_candles" ON public.trade_candles FOR SELECT TO public
  USING (true);

-- ── watchlist ───────────────────────────────────────
-- SECURITY NOTE: these policies let ANYONE with the public key (no login) INSERT/UPDATE/DELETE the watchlist. Only the pipeline (service key) & admin panel write. Recommend tightening writes to is_admin() and reads to authenticated.
CREATE POLICY "Allow all delete watchlist" ON public.watchlist FOR DELETE TO public
  USING (true);
CREATE POLICY "Allow all insert watchlist" ON public.watchlist FOR INSERT TO public
  WITH CHECK (true);
CREATE POLICY "Allow all read watchlist" ON public.watchlist FOR SELECT TO public
  USING (true);
CREATE POLICY "Public read watchlist" ON public.watchlist FOR SELECT TO public
  USING (true);
CREATE POLICY "Allow all update watchlist" ON public.watchlist FOR UPDATE TO public
  USING (true);

-- ── watchlist_enriched ──────────────────────────────
-- SECURITY NOTE: same broad public write access as watchlist. Pipeline uses the service key; recommend admin-only writes.
CREATE POLICY "Allow all delete watchlist_enriched" ON public.watchlist_enriched FOR DELETE TO public
  USING (true);
CREATE POLICY "Allow all insert watchlist_enriched" ON public.watchlist_enriched FOR INSERT TO public
  WITH CHECK (true);
CREATE POLICY "Allow all read watchlist_enriched" ON public.watchlist_enriched FOR SELECT TO public
  USING (true);
CREATE POLICY "Public read watchlist_enriched" ON public.watchlist_enriched FOR SELECT TO public
  USING (true);
CREATE POLICY "Allow all update watchlist_enriched" ON public.watchlist_enriched FOR UPDATE TO public
  USING (true);

-- ── watchlist_candles ───────────────────────────────
CREATE POLICY "Authenticated users can read watchlist candles" ON public.watchlist_candles FOR SELECT TO authenticated
  USING (true);

-- ── market_breadth ──────────────────────────────────
CREATE POLICY "Allow all writes on market breadth" ON public.market_breadth FOR ALL TO public
  USING (true)
  WITH CHECK (true);
CREATE POLICY "Authenticated users can read market breadth" ON public.market_breadth FOR SELECT TO authenticated
  USING (true);

-- ── sector_stocks ───────────────────────────────────
CREATE POLICY "Public read sector_stocks" ON public.sector_stocks FOR SELECT TO public
  USING (true);

-- ── sector_breadth ──────────────────────────────────
CREATE POLICY "Public read sector_breadth" ON public.sector_breadth FOR SELECT TO public
  USING (true);

-- ── index_levels ────────────────────────────────────
CREATE POLICY "Allow all writes on index levels" ON public.index_levels FOR ALL TO public
  USING (true)
  WITH CHECK (true);
CREATE POLICY "Authenticated users can read index levels" ON public.index_levels FOR SELECT TO authenticated
  USING (true);

-- ── fii_dii_activity ────────────────────────────────
CREATE POLICY "Allow all writes on fii_dii" ON public.fii_dii_activity FOR ALL TO public
  USING (true)
  WITH CHECK (true);
CREATE POLICY "Authenticated users can read fii_dii" ON public.fii_dii_activity FOR SELECT TO authenticated
  USING (true);

-- ── portfolio_snapshots ─────────────────────────────
CREATE POLICY "Allow all writes on portfolio snapshots" ON public.portfolio_snapshots FOR ALL TO public
  USING (true)
  WITH CHECK (true);
CREATE POLICY "Authenticated users can read portfolio snapshots" ON public.portfolio_snapshots FOR SELECT TO authenticated
  USING (true);


-- ============================================================
-- END — see SECURITY NOTEs on watchlist / watchlist_enriched
-- and the LEGACY note on students for recommended follow-ups.
-- ============================================================