# CDN-NETCHAT 2026-06-10 Mega Update

## What Changed

### 1. Notifications (FCM Push) — FIXED
- Deployed updated `send-push-notification` Edge Function with proper Firebase OAuth2 token caching
- Added `is_delivered` flag to messages table so sent messages are tracked
- Fixed FCM token exchange with expired token retry logic
- Edge function now uses `direct_boot_ok: true` + `visibility: PUBLIC` for better delivery when app is closed
- **Tested**: sending a message to UUID 5C7E5855 now triggers a push notification

### 2. Calls – TURN Server + Audio Stability — IMPLEMENTED
- Replaced Metered TURN with your `free.expressturn.com:3478` credentials:
  - Username: `000000002094301083`
  - Password: `Uz10c+zqsHQgQYKs1zGs2A+/09M=`
- Added 3 TURN entries for fallback: UDP (3478), TCP (3478?transport=tcp), TLS (443)
- Kept Google STUN + Metered TURN as additional backups
- Fixed `_reapplyAudioConfig()` to re-enable audio after connection
- Added `_ringingTimeout` (20s auto-cancel) so calls don't ring forever

### 3. Phantom Calls (ghost popup) — FIXED
- **Root cause**: Stale call signals in Supabase kept being streamed to clients
- Added `expires_at` column to `call_signals` table (30s TTL)
- Added PostgreSQL trigger to auto-clean expired signals
- Signaling client now filters: ignores signals older than 10 seconds
- Added 20-second ringing timeout (auto-cancels if no answer)
- `cleanup_expired_call_signals()` called on both app startup and call end

### 4. Offline-First Chat (WhatsApp-style) — IMPLEMENTED
- `LocalChatStore.hydrateAllConversations()` loads ALL chats from Supabase → Isar on startup
- `LocalChatStore.getLocalChatThreads()` reads chat list from Isar (works offline)
- Chat list screen reads from local DB first, Supabase subscription updates in background
- Messages displayed from Isar instantly, even without internet
- Sending: queued to Isar → synced to Supabase when online

### 5. Blue Ticks (Read Receipts) — IMPLEMENTED
- **No tick/clock icon**: `is_sending=true` — message is being sent
- **Single tick (✓)**: `is_delivered=true` — FCM delivered to recipient's device
- **Double tick (✓✓)**: `is_read=true` — recipient opened chat and saw the message
- New columns: `is_delivered`, `delivered_at`, `is_sending` on `messages` table
- New RPCs: `mark_message_delivered()`, `mark_conversation_read()`, `get_unread_count()`

### Database Migrations Applied
- `supabase_2026_06_10_mega_update.sql` applied to project `tlmyxuyqngkgwgjepeed`

### Files Modified
- `repo/supabase/functions/send-push-notification/index.ts`
- `repo/lib/calls/call_screen.dart`
- `repo/lib/services/supabase_service.dart`
- `repo/lib/services/fcm_service.dart`
- `repo/lib/local_db/local_message.dart` (+ regenerated `.g.dart`)
- `repo/lib/local_db/local_chat_store.dart`
- `repo/lib/main.dart`
- `repo/pubspec.yaml` (workmanager downgraded for compatibility)
- `repo/.github/workflows/build-apk.yml` (NEW)

### APK Build
- GitHub Actions workflow configured for `arm64-v8a` release APK
- Uses `subosito/flutter-action@v2` for Flutter setup
- Builds with `--split-per-abi` and outputs APK as artifact