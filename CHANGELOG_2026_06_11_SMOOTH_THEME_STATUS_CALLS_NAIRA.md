# Changelog — 2026-06-11 — Smooth Sync, Light/Dark Theme, Status, Calls, Naira

This update addresses the 5 issues reported on 2026-06-10, building on the
previous WhatsApp-light work without downgrading any existing features.

## 1. ⚡ Smooth chat — no more lag / rebounce / double "reloading"

**Root cause:** `LocalChatStore.watchConversationOfflineFirst` ran two parallel
subscriptions (local Isar watch + remote Supabase realtime). Every remote
message was mirrored into Isar via `upsertFromRemote`, which fired the LOCAL
watch too — so each message triggered a *double emit*, and each emit rebuilt the
entire message list and re-ran auto-scroll. That is what made the chat visibly
"reload / bounce" while chatting.

**Fix (`lib/local_db/local_chat_store.dart`):**
- Emits are now **coalesced** into a single 60 ms window (collapses the
  back-to-back local+remote events into one).
- A cheap **content signature** is computed for the merged list; if nothing
  actually changed, the emit is **dropped** (no rebuild at all).
- Remote rows still mirror into Isar for offline persistence, but no longer
  cause redundant UI rebuilds.

**Fix (`lib/features/chat/screens/chat_room_screen.dart`):**
- Each message bubble now has a **stable `ValueKey('msg_<id>')`** so Flutter
  *reuses* existing bubble elements instead of rebuilding the whole list —
  eliminating the flicker/bounce.
- Combined with the existing send-guard (`_sendInFlight`) and pending-message
  dedupe, double-send and bouncing are fixed.

## 2. 📴 Offline-first (unchanged, still intact)

The offline-first stream (local Isar first, Supabase merge) is preserved — the
app still shows chats instantly offline and syncs when back online.

## 3. 👁️ Status: stop re-prompting to view an already-viewed status

**Root cause:** `getActiveStatus` never joined `status_views`, so
`viewed_by_me` was always null → the ring stayed green (unviewed) forever.

**Fix (`lib/services/supabase_service.dart`):**
- `getActiveStatus` now fetches the current user's `status_views` and sets
  `viewed_by_me` on every status (own statuses count as viewed).
- `markStatusViewed` now **upserts** (idempotent) using the existing
  `(status_id, viewer_id)` primary key, so re-viewing never errors.

**Fix (`lib/features/status/screens/status_screen.dart`):**
- Opening a user's statuses **optimistically** marks them viewed locally, so
  the ring turns grey immediately (and is confirmed on reload).

## 4. 📞 Calls: ringtone + online check

**Fix (`lib/calls/call_screen.dart`):**
- Added a looping **ringback tone** (caller) and **ringtone** (receiver) using
  `audioplayers`, played while ringing and stopped on connect / hangup /
  timeout / dispose. New assets: `assets/audio/ringback.wav`,
  `assets/audio/ringtone.wav`.

**Fix (`lib/services/supabase_service.dart` + `chat_room_screen.dart`):**
- New `isUserOnline(userId)` (true if `last_seen` within 60 s). The caller now
  checks presence **before** ringing; if the peer is offline it shows
  "X is offline right now" and does not ring into the void.
- The existing TURN + ICE-restart + 25 s grace-period work is preserved, so
  end-to-end audio/video stays stable with no 1-minute disconnect.

## 5. 🎨 Light/dark theme consistency + readable ₦

**Naira box → real ₦ sign:**
- Poppins (via `google_fonts`) lacks the ₦ glyph (U+20A6) → it rendered as a
  tofu box. Added `fontFamilyFallback: ['Roboto','NotoSans','sans-serif']` to
  both app themes (`theme_provider.dart`) and a `Money` helper
  (`lib/shared/widgets/money_text.dart`) used for the balance, stat values,
  the ₦ input prefix and transaction amounts so the sign always resolves.

**Wallet now follows the theme (was permanently dark):**
- `wallet_screen.dart`: body background, app-bar title, stat cards and the
  transactions list are now **theme-aware** (flat white/grey in light mode,
  deep gradient in dark mode). The balance card keeps a fixed dark green
  gradient in both modes (fintech-style) so the white balance text is always
  readable.

## 🔧 Build / CI
- Registered `assets/audio/` in `pubspec.yaml`.
- No workflow change needed — pushing to `main` triggers
  `.github/workflows/build_apk.yml`, which builds the **arm64-v8a** release APK
  and uploads it as the `cdn-netchat-apk-arm64` artifact.

## ✅ Validation
- `flutter analyze lib/` → **0 errors** (only pre-existing info-level
  `withOpacity` deprecation notices).
- Local `flutter build apk --debug --target-platform android-arm64` produced
  `app-arm64-v8a-debug.apk` successfully, confirming the full release build
  will compile in CI.
