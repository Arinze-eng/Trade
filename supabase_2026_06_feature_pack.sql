-- ============================================================
-- CDN-NETCHAT 2026-06 Feature Pack
-- Adds: Tiered referral rules, signup anti-abuse (email+device+ip),
--       Basic-tier admin grant/revoke, Flutterwave callback support,
--       Pro-only discovery RPC, helper RPCs.
--
-- Idempotent — safe to re-run.
-- ============================================================

-- ---------- 1. Anti-abuse: signup fingerprint table ----------
-- Track every signup attempt with email + device fingerprint + ip.
-- If any of (email, device_fingerprint, ip) has already been used to register,
-- new signup is blocked. Phone is intentionally excluded.

CREATE TABLE IF NOT EXISTS public.signup_fingerprints (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  email_lower TEXT NOT NULL,
  device_fingerprint TEXT,
  ip_address TEXT,
  user_agent TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_signup_fp_email
  ON public.signup_fingerprints (email_lower);
CREATE INDEX IF NOT EXISTS idx_signup_fp_device
  ON public.signup_fingerprints (device_fingerprint)
  WHERE device_fingerprint IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_signup_fp_ip
  ON public.signup_fingerprints (ip_address)
  WHERE ip_address IS NOT NULL;

ALTER TABLE public.signup_fingerprints ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can view own fingerprint" ON public.signup_fingerprints;
CREATE POLICY "Users can view own fingerprint" ON public.signup_fingerprints
  FOR SELECT TO authenticated USING (auth.uid() = user_id);

-- Anyone (including anon during signup) can check if a fingerprint already exists,
-- but cannot read who owns it.
CREATE OR REPLACE FUNCTION public.is_signup_fingerprint_used(
  p_email TEXT,
  p_device_fingerprint TEXT,
  p_ip TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email TEXT := lower(btrim(COALESCE(p_email, '')));
  v_device TEXT := NULLIF(btrim(COALESCE(p_device_fingerprint, '')), '');
  v_ip TEXT := NULLIF(btrim(COALESCE(p_ip, '')), '');
BEGIN
  IF v_email = '' AND v_device IS NULL AND v_ip IS NULL THEN
    RETURN FALSE;
  END IF;

  RETURN EXISTS (
    SELECT 1 FROM public.signup_fingerprints sf
    WHERE
      (v_email <> '' AND sf.email_lower = v_email)
      OR (v_device IS NOT NULL AND sf.device_fingerprint = v_device)
      OR (v_ip IS NOT NULL AND sf.ip_address = v_ip)
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.is_signup_fingerprint_used(text,text,text) TO anon, authenticated;

-- Record fingerprint after a successful signup (called from app post-signup).
CREATE OR REPLACE FUNCTION public.record_signup_fingerprint(
  p_device_fingerprint TEXT,
  p_ip TEXT,
  p_user_agent TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_email TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT lower(email) INTO v_email FROM public.profiles WHERE id = v_uid;
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'Profile not found';
  END IF;

  INSERT INTO public.signup_fingerprints
    (user_id, email_lower, device_fingerprint, ip_address, user_agent)
  VALUES
    (v_uid, v_email,
     NULLIF(btrim(COALESCE(p_device_fingerprint,'')), ''),
     NULLIF(btrim(COALESCE(p_ip,'')), ''),
     NULLIF(btrim(COALESCE(p_user_agent,'')), ''))
  ON CONFLICT DO NOTHING;
END;
$$;
GRANT EXECUTE ON FUNCTION public.record_signup_fingerprint(text,text,text) TO authenticated;


-- ---------- 2. Referral helpers ----------
-- Increment referral_count helper (called from app).
CREATE OR REPLACE FUNCTION public.increment_referral_count(p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE public.profiles
  SET referral_count = COALESCE(referral_count, 0) + 1
  WHERE id = p_user_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.increment_referral_count(uuid) TO authenticated;

-- Apply referral atomically — used during signup. Prevents self-referral and
-- prevents applying the same referrer twice. Marks profile.referred_by.
CREATE OR REPLACE FUNCTION public.apply_referral_code(p_referral_code TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_referrer UUID;
  v_already UUID;
  v_code TEXT := upper(btrim(COALESCE(p_referral_code, '')));
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;
  IF v_code = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Empty code');
  END IF;

  SELECT id INTO v_referrer
  FROM public.profiles
  WHERE upper(referral_code) = v_code
  LIMIT 1;

  IF v_referrer IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid code');
  END IF;
  IF v_referrer = v_uid THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cannot self-refer');
  END IF;

  -- Already has a referrer?
  SELECT referred_by INTO v_already FROM public.profiles WHERE id = v_uid;
  IF v_already IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Already referred');
  END IF;

  UPDATE public.profiles SET referred_by = v_referrer WHERE id = v_uid;

  INSERT INTO public.referrals (referrer_id, referred_user_id, referral_code, status)
  VALUES (v_referrer, v_uid, v_code, 'pending');

  UPDATE public.profiles
  SET referral_count = COALESCE(referral_count, 0) + 1
  WHERE id = v_referrer;

  RETURN jsonb_build_object('success', true, 'referrer_id', v_referrer);
END;
$$;
GRANT EXECUTE ON FUNCTION public.apply_referral_code(text) TO authenticated;


-- ---------- 3. Tiered referral rewards ----------
-- Stages (lifetime):
--    1 successful referral  -> ₦100 wallet credit
--    5 successful referrals -> ₦500 wallet credit
--   10 successful referrals -> 7-day Basic Premium subscription
-- A "successful" referral = referred user has sent >= 10 messages.

CREATE TABLE IF NOT EXISTS public.referral_milestones_awarded (
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  milestone INTEGER NOT NULL, -- 1, 5, 10
  awarded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, milestone)
);
ALTER TABLE public.referral_milestones_awarded ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can view own milestones" ON public.referral_milestones_awarded;
CREATE POLICY "Users can view own milestones" ON public.referral_milestones_awarded
  FOR SELECT TO authenticated USING (auth.uid() = user_id);

-- Count successful referrals (referred user sent >= 10 messages)
CREATE OR REPLACE FUNCTION public.count_successful_referrals(p_user_id UUID)
RETURNS INTEGER
LANGUAGE sql
AS $$
  SELECT COALESCE(COUNT(*), 0)::int
  FROM public.referrals r
  WHERE r.referrer_id = p_user_id
    AND (r.status IN ('active','paid')
         OR (
           SELECT COUNT(*) FROM public.messages m
           WHERE m.sender_id = r.referred_user_id
         ) >= 10
        );
$$;
GRANT EXECUTE ON FUNCTION public.count_successful_referrals(uuid) TO authenticated;

-- Evaluate & award referral milestones for a referrer.
-- Returns awarded milestones array.
CREATE OR REPLACE FUNCTION public.evaluate_referral_milestones(p_referrer_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INT;
  v_awarded JSONB := '[]'::jsonb;
  v_already_1 BOOLEAN;
  v_already_5 BOOLEAN;
  v_already_10 BOOLEAN;
BEGIN
  v_count := public.count_successful_referrals(p_referrer_id);

  SELECT EXISTS(SELECT 1 FROM public.referral_milestones_awarded
                WHERE user_id = p_referrer_id AND milestone = 1) INTO v_already_1;
  SELECT EXISTS(SELECT 1 FROM public.referral_milestones_awarded
                WHERE user_id = p_referrer_id AND milestone = 5) INTO v_already_5;
  SELECT EXISTS(SELECT 1 FROM public.referral_milestones_awarded
                WHERE user_id = p_referrer_id AND milestone = 10) INTO v_already_10;

  -- Milestone 1: ₦100
  IF v_count >= 1 AND NOT v_already_1 THEN
    PERFORM public.record_earning(p_referrer_id, 100, 'referral_milestone_1', '1');
    INSERT INTO public.referral_milestones_awarded (user_id, milestone)
      VALUES (p_referrer_id, 1) ON CONFLICT DO NOTHING;
    v_awarded := v_awarded || jsonb_build_object('milestone', 1, 'reward', '₦100');
  END IF;

  -- Milestone 5: ₦500
  IF v_count >= 5 AND NOT v_already_5 THEN
    PERFORM public.record_earning(p_referrer_id, 500, 'referral_milestone_5', '5');
    INSERT INTO public.referral_milestones_awarded (user_id, milestone)
      VALUES (p_referrer_id, 5) ON CONFLICT DO NOTHING;
    v_awarded := v_awarded || jsonb_build_object('milestone', 5, 'reward', '₦500');
  END IF;

  -- Milestone 10: 7-day Basic Premium
  IF v_count >= 10 AND NOT v_already_10 THEN
    UPDATE public.profiles
    SET tier = 'basic_premium',
        is_subscribed = TRUE,
        subscription_started_at = COALESCE(subscription_started_at, NOW()),
        subscription_ends_at = GREATEST(COALESCE(subscription_ends_at, NOW()), NOW()) + INTERVAL '7 days',
        subscription_expiry = GREATEST(COALESCE(subscription_expiry, NOW()), NOW()) + INTERVAL '7 days'
    WHERE id = p_referrer_id;
    INSERT INTO public.referral_milestones_awarded (user_id, milestone)
      VALUES (p_referrer_id, 10) ON CONFLICT DO NOTHING;
    v_awarded := v_awarded || jsonb_build_object('milestone', 10, 'reward', '7 days Basic Premium');
  END IF;

  RETURN jsonb_build_object('count', v_count, 'awarded', v_awarded);
END;
$$;
GRANT EXECUTE ON FUNCTION public.evaluate_referral_milestones(uuid) TO authenticated;

-- Convenience: caller evaluates own milestones (used when user opens wallet).
CREATE OR REPLACE FUNCTION public.refresh_my_referral_status()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  RETURN public.evaluate_referral_milestones(v_uid);
END;
$$;
GRANT EXECUTE ON FUNCTION public.refresh_my_referral_status() TO authenticated;


-- ---------- 4. Pro-only discovery ----------
-- Only paid (basic_premium or pro) users can list other users for discovery.
-- Free users get empty list and must paste UUID manually.
CREATE OR REPLACE FUNCTION public.discover_users(p_limit INT DEFAULT 50)
RETURNS TABLE(
  id UUID,
  username TEXT,
  display_name TEXT,
  avatar_url TEXT,
  about TEXT,
  last_seen TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_tier TEXT;
  v_subscribed BOOLEAN;
  v_expiry TIMESTAMPTZ;
BEGIN
  IF v_uid IS NULL THEN
    RETURN;
  END IF;

  SELECT
    COALESCE(tier::text, 'free'),
    COALESCE(is_subscribed, FALSE),
    subscription_expiry
  INTO v_tier, v_subscribed, v_expiry
  FROM public.profiles WHERE profiles.id = v_uid;

  -- Gate: must be pro/basic_premium AND have an active sub OR pro tier.
  IF v_tier NOT IN ('basic_premium', 'pro')
     OR (v_expiry IS NOT NULL AND v_expiry < NOW() AND v_subscribed = FALSE) THEN
    RETURN; -- empty
  END IF;

  RETURN QUERY
    SELECT p.id, p.username, p.display_name, p.avatar_url, p.about, p.last_seen
    FROM public.profiles p
    WHERE p.id <> v_uid
      AND COALESCE(p.is_blocked, FALSE) = FALSE
    ORDER BY p.last_seen DESC NULLS LAST, p.created_at DESC
    LIMIT LEAST(GREATEST(p_limit, 1), 200);
END;
$$;
GRANT EXECUTE ON FUNCTION public.discover_users(int) TO authenticated;


-- ---------- 5. Admin: grant BASIC tier (basic_premium) ----------
-- Mirrors admin_grant_premium but for basic_premium tier. Existing
-- admin_grant_premium will keep granting 'pro'.
CREATE OR REPLACE FUNCTION public.admin_grant_basic(
  p_secret TEXT,
  p_user_id UUID,
  p_days INT DEFAULT 30
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d INT := LEAST(GREATEST(COALESCE(p_days, 30), 1), 3650);
BEGIN
  PERFORM public._admin_assert_secret(p_secret);
  UPDATE public.profiles
  SET tier = 'basic_premium',
      is_subscribed = TRUE,
      subscription_started_at = NOW(),
      subscription_ends_at = NOW() + make_interval(days => d),
      subscription_expiry = NOW() + make_interval(days => d)
  WHERE id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'User not found';
  END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_grant_basic(text,uuid,int) TO authenticated;

-- Make sure admin_grant_premium upgrades to PRO tier (was previously
-- only flipping is_subscribed without touching tier).
CREATE OR REPLACE FUNCTION public.admin_grant_premium(
  p_secret TEXT,
  p_user_id UUID,
  p_days INT DEFAULT 30
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d INT := LEAST(GREATEST(COALESCE(p_days, 30), 1), 3650);
BEGIN
  PERFORM public._admin_assert_secret(p_secret);
  UPDATE public.profiles
  SET tier = 'pro',
      is_subscribed = TRUE,
      subscription_started_at = NOW(),
      subscription_ends_at = NOW() + make_interval(days => d),
      subscription_expiry = NOW() + make_interval(days => d)
  WHERE id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'User not found';
  END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_grant_premium(text,uuid,int) TO authenticated;

-- Revoke clears tier to free.
CREATE OR REPLACE FUNCTION public.admin_revoke_premium(
  p_secret TEXT,
  p_user_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public._admin_assert_secret(p_secret);
  UPDATE public.profiles
  SET tier = 'free',
      is_subscribed = FALSE,
      subscription_expiry = NULL,
      subscription_ends_at = NULL
  WHERE id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'User not found';
  END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_revoke_premium(text,uuid) TO authenticated;


-- ---------- 6. Flutterwave payment activation ----------
-- Called by the pay-redirect Edge Function after Flutterwave verifies the tx.
-- The function uses service role key (bypasses RLS), so this RPC is plain SQL
-- and does not check auth.uid().
CREATE OR REPLACE FUNCTION public.activate_subscription_after_payment(
  p_user_id UUID,
  p_tier TEXT,                 -- 'basic_premium' or 'pro'
  p_amount NUMERIC,
  p_payment_reference TEXT,
  p_days INT DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tier public.user_tier;
  v_days INT := LEAST(GREATEST(COALESCE(p_days, 30), 1), 365);
  v_existing BIGINT;
BEGIN
  IF p_tier = 'pro' THEN
    v_tier := 'pro';
  ELSIF p_tier = 'basic_premium' OR p_tier = 'basic' THEN
    v_tier := 'basic_premium';
  ELSE
    RAISE EXCEPTION 'Unknown tier %', p_tier;
  END IF;

  -- Idempotent: if this payment reference was already processed, skip.
  SELECT id INTO v_existing
  FROM public.subscriptions
  WHERE payment_reference = p_payment_reference
  LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'duplicate', true);
  END IF;

  INSERT INTO public.subscriptions
    (user_id, tier, amount, payment_provider, payment_reference, status, start_date, end_date)
  VALUES
    (p_user_id, v_tier, p_amount, 'flutterwave', p_payment_reference, 'active',
     NOW(), NOW() + make_interval(days => v_days));

  UPDATE public.profiles
  SET tier = v_tier,
      is_subscribed = TRUE,
      subscription_started_at = NOW(),
      subscription_ends_at = NOW() + make_interval(days => v_days),
      subscription_expiry = NOW() + make_interval(days => v_days)
  WHERE id = p_user_id;

  RETURN jsonb_build_object('success', true, 'tier', v_tier::text);
END;
$$;
-- NOT granted to authenticated — only service role can call.

-- ---------- 7. Streak: bump streak when a message is sent ----------
-- Lightweight wrapper used by app on every successful message send.
-- (update_streak already exists; this just exposes a no-arg "for me" version.)
CREATE OR REPLACE FUNCTION public.touch_my_streak()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RETURN 0; END IF;
  RETURN public.update_streak(v_uid);
END;
$$;
GRANT EXECUTE ON FUNCTION public.touch_my_streak() TO authenticated;
