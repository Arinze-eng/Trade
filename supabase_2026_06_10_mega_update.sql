-- ============================================================
-- CDN-NETCHAT 2026-06-10 Mega Update
-- Fixes: Notifications, TURN calls, Ghost calling, Offline first,
--        Blue ticks (delivery + read receipts)
-- ============================================================

-- ---------- 1. Add delivery status columns to messages ----------
-- is_delivered: true when Supabase INSERT completes + FCM sent
-- delivered_at: timestamp of delivery confirmation
-- is_sending: true when message is being sent (shows clock/pending UI)

ALTER TABLE public.messages 
  ADD COLUMN IF NOT EXISTS is_delivered BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS delivered_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS is_sending BOOLEAN NOT NULL DEFAULT false;

-- Add delivery status to group_messages too
ALTER TABLE public.group_messages 
  ADD COLUMN IF NOT EXISTS is_delivered BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS delivered_at TIMESTAMPTZ;

-- ---------- 2. Fix ghost calling: add expiry to call_signals ----------
-- Call signals older than 30 seconds are stale
ALTER TABLE public.call_signals 
  ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '30 seconds');

-- Auto-cleanup expired call signals function
CREATE OR REPLACE FUNCTION public.cleanup_expired_call_signals()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  DELETE FROM public.call_signals WHERE expires_at < NOW();
END;
$$;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_call_signals() TO authenticated;

-- Call this on every insert to auto-clean
CREATE OR REPLACE FUNCTION public.trigger_cleanup_call_signals()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  DELETE FROM public.call_signals WHERE expires_at < NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS cleanup_call_signals_on_insert ON public.call_signals;
CREATE TRIGGER cleanup_call_signals_on_insert
AFTER INSERT ON public.call_signals
FOR EACH STATEMENT EXECUTE FUNCTION public.trigger_cleanup_call_signals();

-- ---------- 3. Mark messages as delivered ----------
-- Called after the Edge Function successfully sends FCM
CREATE OR REPLACE FUNCTION public.mark_message_delivered(p_message_id BIGINT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE public.messages
  SET is_delivered = true, delivered_at = NOW()
  WHERE id = p_message_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.mark_message_delivered(bigint) TO service_role;

-- ---------- 4. Function to mark all messages as read for a conversation ----------
-- Returns count of messages marked as read
CREATE OR REPLACE FUNCTION public.mark_conversation_read(p_other_user_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_count INTEGER;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  UPDATE public.messages
  SET is_read = true
  WHERE sender_id = p_other_user_id
    AND receiver_id = v_uid
    AND is_read = false;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;
GRANT EXECUTE ON FUNCTION public.mark_conversation_read(uuid) TO authenticated;

-- ---------- 5. Function to get unread count for a user ----------
CREATE OR REPLACE FUNCTION public.get_unread_count()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_count INTEGER;
BEGIN
  IF v_uid IS NULL THEN RETURN 0; END IF;
  
  SELECT COUNT(*) INTO v_count
  FROM public.messages
  WHERE receiver_id = v_uid AND is_read = false;
  
  RETURN v_count;
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_unread_count() TO authenticated;

-- ---------- 6. Ensure realtime is enabled for all needed tables ----------
-- Note: ALTER PUBLICATION ... ADD TABLE IF NOT EXISTS is not supported;
-- these tables should already be in the publication from earlier migrations.
-- We skip this because they're already added.

-- ---------- 7. Grant proper usage ----------
GRANT USAGE ON SEQUENCE public.messages_id_seq TO authenticated;