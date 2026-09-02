-- ============================================================
-- CDN-NETCHAT Earnings Dedup Migration (2026-06-08)
-- Ensures same person viewing the same status cannot earn
-- multiple times for the owner.
-- ============================================================

-- Add unique constraint on earnings (user_id, source, reference_id)
-- to prevent duplicate earnings from the same source
CREATE UNIQUE INDEX IF NOT EXISTS idx_earnings_dedup
  ON public.earnings (user_id, COALESCE(source, ''), COALESCE(reference_id, ''))
  WHERE source IN ('status_view', 'boosted_view');

-- Create a helper function to record status view earnings with dedup
CREATE OR REPLACE FUNCTION public.record_status_view_earning(
  p_owner_id UUID,
  p_viewer_id UUID,
  p_status_id TEXT,
  p_amount NUMERIC DEFAULT 2.50
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_existing BIGINT;
  v_tier public.user_tier;
BEGIN
  -- Check the owner's tier (free users can't earn)
  SELECT tier INTO v_tier FROM public.profiles WHERE id = p_owner_id;
  IF v_tier = 'free' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Free users cannot earn');
  END IF;

  -- Check if this viewer has already earned for this status
  SELECT id INTO v_existing FROM public.earnings
  WHERE user_id = p_owner_id
    AND source = 'status_view'
    AND reference_id = p_status_id;
  
  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Already earned for this view');
  END IF;

  -- Record the earning
  RETURN public.record_earning(p_owner_id, p_amount, 'status_view', p_status_id);
END;
$$;
GRANT EXECUTE ON FUNCTION public.record_status_view_earning(uuid, uuid, text, numeric) TO authenticated;
