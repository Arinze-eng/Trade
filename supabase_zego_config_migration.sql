-- [ADD 2026-09-03] Seed ZegoCloud call config override keys in app_settings.
-- =========================================================================
-- Agora was replaced by ZegoCloud for audio/video calls. The ZegoCloud
-- AppID / AppSign can be overridden from the Admin panel; those overrides are
-- stored here (empty value = use compiled defaults in lib/services/zego_config.dart).
-- Idempotent: safe to run even if this migration was applied before.

INSERT INTO public.app_settings(key, value)
SELECT 'zego_app_id', '""'
WHERE NOT EXISTS (SELECT 1 FROM public.app_settings WHERE key = 'zego_app_id');

INSERT INTO public.app_settings(key, value)
SELECT 'zego_app_sign', '""'
WHERE NOT EXISTS (SELECT 1 FROM public.app_settings WHERE key = 'zego_app_sign');