-- ============================================================================
-- Migration: 2026-06-11 — Realtime + Performance (No-Lag / No-Flicker / Calls)
-- ----------------------------------------------------------------------------
-- WHY:
--   1. Only `messages` was in the Supabase realtime publication, and the Flutter
--      client subscribed WITHOUT a server-side filter — so every change by ANY
--      user re-downloaded the whole table and re-emitted the full list. That was
--      the #1 cause of the chat "flickering / reloading / lag while chatting".
--      The client now filters server-side (.eq) AND these indexes make the
--      filtered reads instant.
--   2. `call_signals` and `typing_events` were NOT in the realtime publication,
--      so the WebRTC signaling stream and the typing indicator never received
--      live INSERT events — calls failed to ring/connect reliably. They are now
--      published, so calls work end-to-end.
--   3. REPLICA IDENTITY FULL makes realtime UPDATE/DELETE events carry the full
--      row, which is required for the client-side `.eq` realtime filter to match
--      reliably on every event (not just INSERT).
--
-- This migration is additive and idempotent — safe to re-run.
-- ============================================================================

-- 1) Realtime publication: add the tables the app streams from.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='call_signals') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.call_signals;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='typing_events') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.typing_events;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='profiles') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.profiles;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='status') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.status;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='group_messages') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.group_messages;
  END IF;
END$$;

-- 2) Replica identity FULL so realtime UPDATE/DELETE events carry the full row
--    (needed for reliable client-side .eq filtering on every event).
ALTER TABLE public.call_signals  REPLICA IDENTITY FULL;
ALTER TABLE public.typing_events REPLICA IDENTITY FULL;
ALTER TABLE public.messages      REPLICA IDENTITY FULL;
ALTER TABLE public.group_messages REPLICA IDENTITY FULL;

-- 3) Indexes to make conversation / signal / typing reads instant.
CREATE INDEX IF NOT EXISTS messages_pair_created_idx
  ON public.messages (sender_id, receiver_id, created_at);
CREATE INDEX IF NOT EXISTS messages_pair_rev_created_idx
  ON public.messages (receiver_id, sender_id, created_at);
CREATE INDEX IF NOT EXISTS messages_receiver_unread_idx
  ON public.messages (receiver_id, is_read) WHERE is_read = false;
CREATE INDEX IF NOT EXISTS call_signals_to_created_idx
  ON public.call_signals (to_id, created_at);
CREATE INDEX IF NOT EXISTS typing_receiver_idx
  ON public.typing_events (receiver_id);
