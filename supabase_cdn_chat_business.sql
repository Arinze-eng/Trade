-- CDN CHAT Business Features Migration
-- Subscriptions, Earnings, Wallet, Referrals, Boosted Status, Sponsored Ads

-- ========== 1. User Tiers (Subscription Types) ==========
DO $$ BEGIN
  CREATE TYPE public.user_tier AS ENUM ('free', 'basic_premium', 'pro');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

ALTER TABLE public.profiles 
  ADD COLUMN IF NOT EXISTS tier public.user_tier DEFAULT 'free',
  ADD COLUMN IF NOT EXISTS subscription_started_at TIMESTAMP WITH TIME ZONE,
  ADD COLUMN IF NOT EXISTS subscription_ends_at TIMESTAMP WITH TIME ZONE,
  ADD COLUMN IF NOT EXISTS daily_earnings NUMERIC(12,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_earnings NUMERIC(12,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS streak_days INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_streak_date DATE,
  ADD COLUMN IF NOT EXISTS referral_code TEXT UNIQUE,
  ADD COLUMN IF NOT EXISTS referred_by UUID REFERENCES public.profiles(id),
  ADD COLUMN IF NOT EXISTS referral_count INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS is_ad_free BOOLEAN DEFAULT false;

-- Generate referral codes for existing users
UPDATE public.profiles 
SET referral_code = upper(substring(replace(gen_random_uuid()::text, '-', '') from 1 for 8))
WHERE referral_code IS NULL;

-- ========== 2. Earnings Table ==========
CREATE TABLE IF NOT EXISTS public.earnings (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
  amount NUMERIC(12,2) NOT NULL,
  source TEXT NOT NULL, -- 'status_view', 'message_sent', 'referral', 'streak_bonus'
  reference_id TEXT, -- status_id, message_id, etc.
  metadata JSONB,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_earnings_user_date ON public.earnings(user_id, created_at DESC);

-- ========== 3. Wallet / Transactions Table ==========
CREATE TABLE IF NOT EXISTS public.transactions (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
  type TEXT NOT NULL, -- 'earning', 'cash_out', 'boost_payment', 'subscription'
  amount NUMERIC(12,2) NOT NULL,
  balance_before NUMERIC(12,2) DEFAULT 0,
  balance_after NUMERIC(12,2) DEFAULT 0,
  status TEXT DEFAULT 'completed', -- 'completed', 'pending', 'failed'
  description TEXT,
  metadata JSONB,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_transactions_user ON public.transactions(user_id, created_at DESC);

-- ========== 4. Cash Out Requests ==========
CREATE TABLE IF NOT EXISTS public.cash_out_requests (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
  amount NUMERIC(12,2) NOT NULL,
  method TEXT NOT NULL, -- 'bank', 'mobile_money', 'opay'
  account_details JSONB, -- {bank, account_number, account_name, phone}
  status TEXT DEFAULT 'pending', -- 'pending', 'approved', 'completed', 'rejected'
  processed_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ========== 5. Boosted Statuses ==========
ALTER TABLE public.status ADD COLUMN IF NOT EXISTS is_boosted BOOLEAN DEFAULT false;
ALTER TABLE public.status ADD COLUMN IF NOT EXISTS boost_views_target INTEGER DEFAULT 0;
ALTER TABLE public.status ADD COLUMN IF NOT EXISTS boost_views_delivered INTEGER DEFAULT 0;

CREATE TABLE IF NOT EXISTS public.sponsored_status_slots (
  id BIGSERIAL PRIMARY KEY,
  brand_name TEXT NOT NULL,
  image_url TEXT,
  cta_text TEXT DEFAULT 'Learn More',
  cta_url TEXT,
  impressions_bought INTEGER NOT NULL,
  impressions_delivered INTEGER DEFAULT 0,
  cost_per_impression NUMERIC(10,2) NOT NULL,
  total_cost NUMERIC(10,2) NOT NULL,
  status TEXT DEFAULT 'active',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ========== 6. Sponsored Channels ==========
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS is_sponsored BOOLEAN DEFAULT false;
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS monthly_retainer NUMERIC(10,2);
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS sponsor_name TEXT;

-- ========== 7. Referral Tracking ==========
CREATE TABLE IF NOT EXISTS public.referrals (
  id BIGSERIAL PRIMARY KEY,
  referrer_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
  referred_user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
  referral_code TEXT NOT NULL,
  status TEXT DEFAULT 'pending', -- 'pending', 'active', 'paid'
  messages_sent INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  paid_at TIMESTAMP WITH TIME ZONE
);

-- ========== 8. Subscriptions Table ==========
CREATE TABLE IF NOT EXISTS public.subscriptions (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
  tier public.user_tier NOT NULL,
  amount NUMERIC(10,2) NOT NULL,
  payment_provider TEXT, -- 'flutterwave', 'paystack'
  payment_reference TEXT,
  status TEXT DEFAULT 'active',
  start_date TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  end_date TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ========== RLS Policies ==========
ALTER TABLE public.earnings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_out_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referrals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own earnings" ON public.earnings;
DROP POLICY IF EXISTS "System can insert earnings" ON public.earnings;
CREATE POLICY "Users can view own earnings" ON public.earnings FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "System can insert earnings" ON public.earnings FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can view own transactions" ON public.transactions;
DROP POLICY IF EXISTS "Users can insert own transactions" ON public.transactions;
CREATE POLICY "Users can view own transactions" ON public.transactions FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own transactions" ON public.transactions FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can view own cash out requests" ON public.cash_out_requests;
DROP POLICY IF EXISTS "Users can create cash out requests" ON public.cash_out_requests;
CREATE POLICY "Users can view own cash out requests" ON public.cash_out_requests FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can create cash out requests" ON public.cash_out_requests FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Referrals viewable by referrer" ON public.referrals;
CREATE POLICY "Referrals viewable by referrer" ON public.referrals FOR SELECT USING (auth.uid() = referrer_id);

DROP POLICY IF EXISTS "Users can view own subscriptions" ON public.subscriptions;
CREATE POLICY "Users can view own subscriptions" ON public.subscriptions FOR SELECT USING (auth.uid() = user_id);

-- ========== Functions ==========

-- Get daily earnings for a user today
CREATE OR REPLACE FUNCTION public.get_daily_earnings(p_user_id UUID)
RETURNS NUMERIC(12,2)
LANGUAGE sql
AS $$
  SELECT COALESCE(SUM(amount), 0) 
  FROM public.earnings 
  WHERE user_id = p_user_id 
    AND created_at::date = CURRENT_DATE;
$$;

-- Get total balance (sum of earnings - cash outs)
CREATE OR REPLACE FUNCTION public.get_user_balance(p_user_id UUID)
RETURNS NUMERIC(12,2)
LANGUAGE sql
AS $$
  SELECT COALESCE(
    (SELECT SUM(amount) FROM public.earnings WHERE user_id = p_user_id), 0
  ) - COALESCE(
    (SELECT SUM(amount) FROM public.transactions WHERE user_id = p_user_id AND type = 'cash_out' AND status = 'completed'), 0
  );
$$;

-- Record earning (with daily cap check)
CREATE OR REPLACE FUNCTION public.record_earning(
  p_user_id UUID,
  p_amount NUMERIC,
  p_source TEXT,
  p_reference_id TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_daily_total NUMERIC(12,2);
  v_daily_cap CONSTANT NUMERIC(12,2) := 2000;
  v_new_balance NUMERIC(12,2);
  v_tier public.user_tier;
BEGIN
  -- Check user tier (free users earn nothing)
  SELECT tier INTO v_tier FROM public.profiles WHERE id = p_user_id;
  IF v_tier = 'free' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Free users cannot earn');
  END IF;

  -- Check daily cap
  v_daily_total := COALESCE(
    (SELECT SUM(amount) FROM public.earnings 
     WHERE user_id = p_user_id AND created_at::date = CURRENT_DATE), 
    0
  );
  
  IF v_daily_total + p_amount > v_daily_cap THEN
    p_amount := GREATEST(v_daily_cap - v_daily_total, 0);
    IF p_amount <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'Daily cap reached');
    END IF;
  END IF;

  -- Insert earning
  INSERT INTO public.earnings (user_id, amount, source, reference_id)
  VALUES (p_user_id, p_amount, p_source, p_reference_id);

  -- Update profile daily_earnings and total_earnings
  UPDATE public.profiles 
  SET daily_earnings = daily_earnings + p_amount,
      total_earnings = total_earnings + p_amount
  WHERE id = p_user_id;

  -- Record transaction
  v_new_balance := public.get_user_balance(p_user_id);
  INSERT INTO public.transactions (user_id, type, amount, balance_after, description)
  VALUES (p_user_id, 'earning', p_amount, v_new_balance, p_source);

  RETURN jsonb_build_object('success', true, 'amount', p_amount);
END;
$$;

-- Update streak
CREATE OR REPLACE FUNCTION public.update_streak(p_user_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_last_date DATE;
  v_streak INTEGER;
BEGIN
  SELECT last_streak_date, streak_days INTO v_last_date, v_streak 
  FROM public.profiles WHERE id = p_user_id;
  
  IF v_last_date IS NULL OR v_last_date < CURRENT_DATE - 1 THEN
    -- Reset streak (more than 1 day gap)
    v_streak := 1;
  ELSIF v_last_date = CURRENT_DATE - 1 THEN
    -- Consecutive day
    v_streak := v_streak + 1;
  END IF;
  -- Same day: no change

  UPDATE public.profiles 
  SET last_streak_date = CURRENT_DATE,
      streak_days = v_streak
  WHERE id = p_user_id;
  
  RETURN v_streak;
END;
$$;

-- Award streak bonus (if >= 50 messages sent today)
CREATE OR REPLACE FUNCTION public.award_streak_bonus(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_msg_count INTEGER;
  v_already_awarded BOOLEAN;
BEGIN
  -- Check if already awarded today
  SELECT EXISTS(
    SELECT 1 FROM public.earnings 
    WHERE user_id = p_user_id 
      AND created_at::date = CURRENT_DATE 
      AND source = 'streak_bonus'
  ) INTO v_already_awarded;
  
  IF v_already_awarded THEN
    RETURN jsonb_build_object('success', false, 'error', 'Already awarded today');
  END IF;

  -- Count messages sent today
  SELECT COUNT(*) INTO v_msg_count
  FROM public.messages
  WHERE sender_id = p_user_id 
    AND created_at::date = CURRENT_DATE;

  IF v_msg_count >= 50 THEN
    -- Award ₦20 streak bonus
    PERFORM public.record_earning(p_user_id, 20, 'streak_bonus');
    -- Update streak
    PERFORM public.update_streak(p_user_id);
    RETURN jsonb_build_object('success', true, 'bonus', 20);
  END IF;

  RETURN jsonb_build_object('success', false, 'error', 'Not enough messages');
END;
$$;

-- Grant access to functions
GRANT EXECUTE ON FUNCTION public.get_daily_earnings TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_balance TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_earning TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_streak TO authenticated;
GRANT EXECUTE ON FUNCTION public.award_streak_bonus TO authenticated;