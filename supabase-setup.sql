-- ============================================================
-- TRADERHIKES DASHBOARD — SUPABASE DATABASE SETUP
-- Run this entire file in Supabase → SQL Editor → New query
-- ============================================================


-- ── 1. STUDENTS TABLE ─────────────────────────────────────
-- Stores each student's profile and access status.
-- Supabase Auth handles passwords automatically —
-- this table just adds the extra fields we need.

CREATE TABLE IF NOT EXISTS public.students (
  id            UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email         TEXT NOT NULL,
  full_name     TEXT,
  plan          TEXT NOT NULL DEFAULT 'active',
  -- 'active'   → paid, can log in
  -- 'inactive' → access revoked (e.g. payment lapsed)
  -- 'pending'  → invited but not yet registered
  enrolled_at   TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  access_until  TIMESTAMP WITH TIME ZONE,  -- NULL = lifetime access
  notes         TEXT  -- your private notes about this student
);

-- Allow students to read only their own row
ALTER TABLE public.students ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Students can read own profile"
  ON public.students FOR SELECT
  USING (auth.uid() = id);

-- You (the admin) can read/write all rows via service key
-- This is handled automatically when you use the service_role key


-- ── 2. OPEN TRADES TABLE ──────────────────────────────────
-- Your active positions. Students see this read-only.

CREATE TABLE IF NOT EXISTS public.open_trades (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at    TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at    TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

  -- Stock details
  symbol        TEXT NOT NULL,           -- e.g. 'DIXON'
  company_name  TEXT NOT NULL,           -- e.g. 'Dixon Technologies'
  sector        TEXT,                    -- e.g. 'Electronics Mfg'
  exchange      TEXT DEFAULT 'NSE',

  -- Trade details
  entry_date    DATE NOT NULL,
  entry_price   NUMERIC(12,2) NOT NULL,
  quantity      INTEGER NOT NULL,
  sl_price      NUMERIC(12,2) NOT NULL,  -- stop loss

  -- Live fields (you update these manually or via script later)
  cmp           NUMERIC(12,2),           -- current market price
  status        TEXT DEFAULT 'long',     -- 'long' | 'trail_sl' | 'watch'

  -- Optional teaching notes visible to students
  trade_notes   TEXT,   -- e.g. "Stage 2 breakout, tight base on weekly"
  chart_pattern TEXT    -- e.g. "VCP", "Flat base", "Cup with handle"
);

-- All logged-in students can read open trades (your trades = shared)
ALTER TABLE public.open_trades ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can read open trades"
  ON public.open_trades FOR SELECT
  TO authenticated
  USING (true);


-- ── 3. CLOSED TRADES TABLE ────────────────────────────────
-- Your completed trades. Students see full journey.

CREATE TABLE IF NOT EXISTS public.closed_trades (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

  -- Stock details
  symbol          TEXT NOT NULL,
  company_name    TEXT NOT NULL,
  sector          TEXT,
  exchange        TEXT DEFAULT 'NSE',

  -- Entry
  entry_date      DATE NOT NULL,
  avg_entry_price NUMERIC(12,2) NOT NULL,
  quantity        INTEGER NOT NULL,
  sl_price        NUMERIC(12,2),

  -- Partial exit (optional — fill if you booked partial profits)
  partial_exit_date   DATE,
  partial_exit_price  NUMERIC(12,2),
  partial_exit_qty    INTEGER,           -- how many shares sold partially
  partial_exit_pct    NUMERIC(5,2),      -- e.g. 40.00 means 40% of position

  -- Final exit
  exit_date       DATE NOT NULL,
  avg_exit_price  NUMERIC(12,2) NOT NULL,

  -- Computed (you can fill or we compute in dashboard)
  realised_pnl    NUMERIC(12,2),         -- in rupees
  return_pct      NUMERIC(8,2),          -- e.g. 17.90 means +17.9%
  holding_days    INTEGER,

  -- Teaching notes
  trade_notes     TEXT,
  exit_reason     TEXT   -- e.g. "SL hit", "Target reached", "Trailing SL"
);

-- All authenticated students can read closed trades
ALTER TABLE public.closed_trades ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can read closed trades"
  ON public.closed_trades FOR SELECT
  TO authenticated
  USING (true);


-- ── 4. MARKET BREADTH TABLE ───────────────────────────────
-- Daily snapshot. A Python script will update this nightly.
-- Students read the latest row.

CREATE TABLE IF NOT EXISTS public.market_breadth (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  snapshot_date   DATE NOT NULL UNIQUE,  -- one row per day
  created_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

  -- EMA breadth (% of NSE stocks above each EMA)
  pct_above_21ema  NUMERIC(5,2),
  pct_above_50ema  NUMERIC(5,2),
  pct_above_200ema NUMERIC(5,2),

  -- Stock count
  total_stocks     INTEGER DEFAULT 1847,
  above_21ema_count  INTEGER,
  above_50ema_count  INTEGER,
  above_200ema_count INTEGER,

  -- Advance / Decline
  advancing        INTEGER,
  declining        INTEGER,
  unchanged        INTEGER,

  -- 52-Week breakouts
  new_52w_highs    INTEGER,
  new_52w_lows     INTEGER,

  -- Index levels (for context)
  nifty50_close    NUMERIC(10,2),
  india_vix        NUMERIC(6,2),
  fii_flow_cr      NUMERIC(12,2)    -- FII net flow in crores (+ = buying)
);

-- All authenticated students can read
ALTER TABLE public.market_breadth ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can read market breadth"
  ON public.market_breadth FOR SELECT
  TO authenticated
  USING (true);


-- ── 5. PORTFOLIO SNAPSHOTS ────────────────────────────────
-- Daily portfolio value snapshot for equity curve chart.

CREATE TABLE IF NOT EXISTS public.portfolio_snapshots (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  snapshot_date   DATE NOT NULL UNIQUE,
  total_capital   NUMERIC(14,2),      -- your total capital that day
  deployed        NUMERIC(14,2),      -- amount in open trades
  cash_available  NUMERIC(14,2),      -- free cash
  portfolio_value NUMERIC(14,2),      -- deployed + unrealised PnL
  nifty500_level  NUMERIC(10,2),      -- for benchmark comparison
  cumulative_return_pct  NUMERIC(8,2) -- e.g. 24.80 = +24.8% since start
);

-- All authenticated students can read
ALTER TABLE public.portfolio_snapshots ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can read portfolio snapshots"
  ON public.portfolio_snapshots FOR SELECT
  TO authenticated
  USING (true);


-- ── 6. ADMIN CHECK FUNCTION ───────────────────────────────
-- Helper to verify if a user is you (the admin).
-- Used by the admin form to allow writes.
-- We identify you by your email address.

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN AS $$
BEGIN
  RETURN (
    SELECT email FROM auth.users WHERE id = auth.uid()
  ) = 'YOUR_EMAIL@GMAIL.COM';  -- ← REPLACE WITH YOUR EMAIL BEFORE RUNNING
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ── 7. ADMIN WRITE POLICIES ───────────────────────────────
-- Only you can insert/update/delete trades.

CREATE POLICY "Admin can insert open trades"
  ON public.open_trades FOR INSERT
  WITH CHECK (public.is_admin());

CREATE POLICY "Admin can update open trades"
  ON public.open_trades FOR UPDATE
  USING (public.is_admin());

CREATE POLICY "Admin can delete open trades"
  ON public.open_trades FOR DELETE
  USING (public.is_admin());

CREATE POLICY "Admin can insert closed trades"
  ON public.closed_trades FOR INSERT
  WITH CHECK (public.is_admin());

CREATE POLICY "Admin can update closed trades"
  ON public.closed_trades FOR UPDATE
  USING (public.is_admin());

CREATE POLICY "Admin can insert breadth data"
  ON public.market_breadth FOR INSERT
  WITH CHECK (public.is_admin());

CREATE POLICY "Admin can update breadth data"
  ON public.market_breadth FOR UPDATE
  USING (public.is_admin());

CREATE POLICY "Admin can insert portfolio snapshots"
  ON public.portfolio_snapshots FOR INSERT
  WITH CHECK (public.is_admin());


-- ── 8. SAMPLE DATA ────────────────────────────────────────
-- Remove these INSERT statements once you have real data.
-- They let you see the dashboard working immediately.

INSERT INTO public.open_trades
  (symbol, company_name, sector, entry_date, entry_price, quantity, sl_price, cmp, status, trade_notes, chart_pattern)
VALUES
  ('DIXON',      'Dixon Technologies',  'Electronics Mfg',   '2026-04-10', 11240, 20,  10600, 13480, 'long',     'Stage 2 breakout on weekly. Strong earnings.',           'Flat base'),
  ('TATAELXSI',  'Tata Elxsi',          'IT Engineering',    '2026-04-15', 6820,  30,  6500,  7945,  'long',     'Relative strength leader in IT. Tight weekly range.',    'VCP'),
  ('POLYCAB',    'Polycab India',        'Cables & Wires',    '2026-04-18', 5340,  25,  5100,  5920,  'long',     'Beneficiary of infra capex. Above all EMAs.',            'Stage 2'),
  ('ZOMATO',     'Zomato',              'Food Tech / QSR',   '2026-04-08', 198,   500, 185,   231,   'trail_sl', 'Trailing SL moved up to cost. Let profits run.',         'Breakout'),
  ('ABB',        'ABB India',           'Capital Goods',     '2026-04-12', 7120,  15,  6800,  7890,  'long',     'Capital goods sector leading. Institutional buying.',    'Flat base'),
  ('BPCL',       'BPCL',                'Oil & Gas PSU',     '2026-04-20', 348,   300, 328,   331,   'watch',    'Watching closely. Below entry. Sector weak.',            'Failed breakout'),
  ('HDFCBANK',   'HDFC Bank',           'Private Banking',   '2026-04-22', 1680,  100, 1600,  1643,  'watch',    'Bank Nifty weak. Monitoring. SL at 1600.',               'Pullback');


INSERT INTO public.closed_trades
  (symbol, company_name, sector, entry_date, avg_entry_price, quantity, sl_price,
   partial_exit_date, partial_exit_price, partial_exit_qty, partial_exit_pct,
   exit_date, avg_exit_price, realised_pnl, return_pct, holding_days,
   trade_notes, exit_reason)
VALUES
  ('ASTRAL',    'Astral Poly Technik', 'Pipes & Fittings', '2026-04-12', 1820, 100, 1680,
   '2026-04-24', 2020, 40, 40.00,
   '2026-05-02', 2145, 32500, 17.90, 20,
   'Textbook Stage 2 breakout. Booked 40% at first target, held rest.', 'Target reached'),

  ('PERSISTENT','Persistent Systems',  'Mid-cap IT',       '2026-04-08', 4650, 40,  4300,
   '2026-04-20', 5050, 20, 50.00,
   '2026-04-29', 5290, 25600, 13.76, 21,
   'IT sector leader. Partial at +8.6%, rode rest to +13.8%.', 'Trailing SL hit'),

  ('CAMS',      'CAMS',                'Fintech BFSI',     '2026-04-15', 3340, 50,  3100,
   '2026-04-28', 3600, 18, 35.00,
   '2026-05-05', 3780, 22000, 13.17, 20,
   'Fintech sector strength. Clean Stage 2 move.', 'Target reached'),

  ('TITAN',     'Titan Company',       'Consumer Disc.',   '2026-04-20', 3210, 60,  3000,
   '2026-05-01', 3380, 18, 30.00,
   '2026-05-08', 3480, 16200,  8.41, 18,
   'Consumer discretionary. Partial profit at +5%, SL trailed up.', 'Trailing SL hit'),

  ('NYKAA',     'Nykaa (FSN E-Com)',   'Beauty E-Commerce','2026-04-22', 182,  800, 170,
   NULL, NULL, NULL, NULL,
   '2026-04-26', 171,  -8800, -6.04, 4,
   'Failed breakout. Cut quickly per plan. Loss within risk parameters.', 'SL hit'),

  ('LTFOODS',   'LT Foods',            'FMCG / Agri',      '2026-04-18', 244,  500, 225,
   NULL, NULL, NULL, NULL,
   '2026-04-23', 228,  -8000, -6.56, 5,
   'Sector weakness. SL respected. Position closed.', 'SL hit');


-- Today's market breadth snapshot
INSERT INTO public.market_breadth
  (snapshot_date, pct_above_21ema, pct_above_50ema, pct_above_200ema,
   above_21ema_count, above_50ema_count, above_200ema_count,
   advancing, declining, unchanged, new_52w_highs, new_52w_lows,
   nifty50_close, india_vix, fii_flow_cr)
VALUES
  (CURRENT_DATE, 72.4, 58.1, 64.7,
   1337, 1073, 1195,
   1240, 607, 0, 142, 18,
   24612, 12.45, 2840);


-- Portfolio snapshots (last 90 days — just a few sample rows)
-- In production, a nightly script adds one row per day automatically
INSERT INTO public.portfolio_snapshots
  (snapshot_date, total_capital, deployed, cash_available, portfolio_value, nifty500_level, cumulative_return_pct)
VALUES
  ('2026-02-17', 2500000, 1500000, 1000000, 2520000, 20400, 0.80),
  ('2026-03-01', 2500000, 1700000,  800000, 2580000, 20800, 3.20),
  ('2026-03-15', 2500000, 1600000,  900000, 2540000, 20200, 1.60),
  ('2026-04-01', 2500000, 1800000,  700000, 2640000, 21200, 5.60),
  ('2026-04-15', 2500000, 1840000,  660000, 2700000, 21800, 8.00),
  ('2026-05-01', 2500000, 1840000,  660000, 2780000, 22400, 11.20),
  (CURRENT_DATE, 2500000, 1840000,  660000, 2836140, 22840, 13.45);


-- ── DONE ─────────────────────────────────────────────────
-- After running this script:
-- 1. Replace 'YOUR_EMAIL@GMAIL.COM' above with your actual email
-- 2. Create your admin account in Supabase → Authentication → Users
-- 3. Deploy the login page and admin form (see other files)
-- ─────────────────────────────────────────────────────────
