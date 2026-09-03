-- [FIX 2026-09-03] app_settings RLS + seed for Netchat AI token & Agora RTC token
-- =========================================================================
-- Problem: The `app_settings` table only had a SELECT policy (read). Writing a
-- value (INSERT/UPDATE) was blocked by RLS, so the Admin panel could NOT save
-- the Netchat AI token ("app_settings/netchat_ai_token row missing"), and the
-- dependency rows for `netchat_ai_token` / `agora_rtc_token` did not exist.
--
-- This migration:
--   1. Adds INSERT / UPDATE / DELETE policies for the authenticated role.
--   2. Seeds the missing `netchat_ai_token` and `agora_rtc_token` rows so the
--      first admin save (which is an INSERT ... ON CONFLICT) succeeds.

-- ── 1. RLS policies on app_settings ─────────────────────────────────────
DROP POLICY IF EXISTS app_settings_insert ON public.app_settings;
CREATE POLICY app_settings_insert ON public.app_settings
  FOR INSERT TO authenticated
  WITH CHECK (key IS NOT NULL);

DROP POLICY IF EXISTS app_settings_update ON public.app_settings;
CREATE POLICY app_settings_update ON public.app_settings
  FOR UPDATE TO authenticated
  USING (key IS NOT NULL);

DROP POLICY IF EXISTS app_settings_delete ON public.app_settings;
CREATE POLICY app_settings_delete ON public.app_settings
  FOR DELETE TO authenticated
  USING (key IS NOT NULL);

-- ── 2. Seed missing rows (idempotent) ───────────────────────────────────
INSERT INTO public.app_settings(key, value)
SELECT 'netchat_ai_token', '""'
WHERE NOT EXISTS (SELECT 1 FROM public.app_settings WHERE key = 'netchat_ai_token');

INSERT INTO public.app_settings(key, value)
SELECT 'agora_rtc_token', '""'
WHERE NOT EXISTS (SELECT 1 FROM public.app_settings WHERE key = 'agora_rtc_token');