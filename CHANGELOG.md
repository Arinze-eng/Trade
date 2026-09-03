# Changelog

## 3.6.1+28 (2026-09-03) - AI File Fixes & VPN-Off Fix
### 🤖 Netchat AI — File Attachments Now Work (image / PDF / ZIP)
- **FIX**: Attachments (images, PDFs) were failing because the whole base64
  payload was sent as a URL query parameter (`GET ?payload=<json>`), which broke
  past URL-length limits. Now sends the chat payload as a **POST JSON body**
  (token stays in the URL) — no length ceiling for large files.
- **FIX**: Rotated the built-in PowerX AI token to the active key
  (`px_SbvVuEj...`).
- **NEW**: ZIP / TAR archive support — readable text entries are inlined,
  otherwise the archive listing is sent so the model can work with it. No more
  "unsupported type" for archives.
### 🔌 VPN — Doesn't Trigger When Turned Off
- **FIX**: The launch VPN splash no longer shows "Initializing VPN…" or attempts
  a connection when the user has the VPN switched off (`vpn_disabled` flag) —
  the app now boots straight to the normal splash.
- **FIX**: `main()` no longer kicks off VPN auto-start when the VPN-off flag is
  set.

## 3.6.0+27 (2026-09-03) - ZegoCloud Calls (Agora removed)
### 🎧 Voice/Video Calls — Switched from Agora to ZegoCloud Express
- **CHANGE**: Removed `agora_rtc_engine` entirely and replaced the media layer
  with ZegoCloud `zego_express_engine` (`lib/calls/call_screen.dart` rewritten).
  ZegoCloud routes media through its own global SDNs (reliable over VPN) and
  uses `appID` + `appSign` directly — **no per-call token minting**, no token
  expiry, and no `agora-token` Edge Function.
- **NEW**: `lib/services/zego_config.dart` holds compiled defaults
  (AppID `1113839402`) and reads admin overrides from `app_settings`
  (`zego_app_id` / `zego_app_sign`).
- **NEW**: Admin panel "ZegoCloud Call Config" section (replaces the old Agora
  RTC token field) to change AppID/AppSign in-app without shipping a new build.
- **CHANGE**: Signaling (ring/accept/reject/hang-up) and call history remain on
  the existing Supabase `call_signals` / `call_history` tables — unchanged.
- **REMOVED**: `supabase/functions/agora-token` edge function and
  `lib/services/agora_config.dart`.
- **MIGRATION**: `supabase_zego_config_migration.sql` seeds the new
  `zego_app_id` / `zego_app_sign` keys idempotently.

## 3.5.1+26 (2026-09-03) - Agora Call Fixes, Incoming-Call UI & AI Token Fix
### 🎧 Agora Voice/Video Calls — Stable & Connecting
- **FIX**: Callers were stuck on "Connecting…" because the project uses Agora
  "App ID + Token" (certificate) auth but an empty token was passed to
  `joinChannel`. The app now resolves a valid RTC token at call time —
  from `app_settings.agora_rtc_token` (admin-managed) → shipped default.
- **NEW**: Optional `agora-token` Supabase Edge Function that mints fresh
  tokens from the App Certificate so tokens never expire. Source ships in
  `supabase/functions/agora-token`. (Off by default; enable via
  `AgoraConfig.tokenEndpoint`.)
- **NEW**: Admin panel "Agora RTC Token" section to override/update the token
  in-app (no new APK needed when a token changes).
- **FIX**: Speaker toggle now available on BOTH voice AND video calls
  (previously video calls only had a camera-flip button).

### 📞 Incoming Calls Now Actually Ring & Can Be Answered
- **FIX**: A callee who was NOT inside the caller's chat room previously only
  got a push notification; tapping it did nothing. The chat list now shows a
  full incoming-call Accept/Decline dialog from anywhere, and tapping the call
  notification opens the CallScreen as callee.
- **FIX**: Accepting an incoming call joins Agora immediately (`autoJoin`),
  removing a redundant second "Accept" tap.
- **FIX**: Call signaling now surfaces the ring UI reliably across screens.

### 🤖 Netchat AI & Admin Token Save
- **FIX**: Admin could not save the AI token ("app_settings/netchat_ai_token
  row missing"). `setAdminToken` now uses INSERT...ON CONFLICT, and the
  `app_settings` table gained proper RLS INSERT/UPDATE/DELETE policies plus the
  missing `netchat_ai_token` / `agora_rtc_token` rows (see
  `supabase_app_settings_fix_migration.sql`).
- **FIX**: AI token resolution discards empty/invalid stored values and falls
  back to the working built-in default so the AI answers reliably.

### 🗄️ Supabase (executed on live project)
- Applied `app_settings` RLS + seed migration to `tlmyxuyqngkgwgjepeed`.
- Set `agora_rtc_token` in `app_settings`.

---

## 3.5.0+25 (2026-06-08) - Lag Fix, Contacts & Call Audio Overhaul
### 🚀 Performance (Zero-Lag Scroll)
- **NEW**: `Debouncer` / `Throttler` / `Batcher` utility classes — centralize all debounce/throttle logic
- **NEW**: `SetStateThrottler` — prevents rebuild storms from rapid stream updates
- **NEW**: `OfflineMessageQueue` — queues messages when offline, auto-flushes on reconnect
- **NEW**: `PaginatedMessageLoader` — paginates chat messages (50 per page, max 200 cached)
- **FIX**: UUID input and search bar now **scroll WITH content** instead of being static
- **FIX**: Debounced all setState() calls in chat_list and chat_room screens
- **FIX**: Throttled thread refresh on incoming messages (max once per 2s)
- **FIX**: Connectivity monitoring with offline banner + auto-reconnect
- **FIX**: `flutter_webrtc` upgraded to ^0.12.3 for stable audio session handling

### 👥 Contacts (Tiered Discovery)
- **PRO (30000)**: Full user discovery with "Save Contact" button on each user
- **Basic/Free**: "My Contacts" view showing saved contacts only
- **ALL users**: Contacts auto-saved when opening a chat, manually deletable
- **FIX**: Discover button shows real contacts screen instead of lock icon

### 📞 Call Audio Fix
- **FIX**: WebRTC audio session properly configured with echo cancellation + noise suppression
- **FIX**: Audio track explicitly unmuted after connection (some Android devices start muted)
- **FIX**: Audio re-configuration re-applied after WebRTC connection established
- **FIX**: TURN servers (Metered) added for reliable connectivity behind NAT/firewall
- **FIX**: Call signal cleanup after hangup — prevents stale signals from triggering dialogs
- **FIX**: Mic/camera tracks stop() before dispose() to properly release hardware

### 🏗️ Build
- GitHub Actions workflow improved for arm64-v8a APK build (already configured)
- Flutter 3.41.9 stable, Java 17, tree-shake-icons enabled

### 📝 Documentation
- All changes documented with `[UPDATE 2026-06-08-LAGFIX]`, `[UPDATE 2026-06-08-P3]` markers
- New files: `core/debouncer.dart`, `core/offline_queue.dart`, `core/message_paginator.dart`

## 3.4.4+23 (2026-06-08) - Feature Pack + Performance
- **BREAKING**: VPN is now **PRO tier only** — no basic_premium, no trial VPN
- **BREAKING**: First-time users / unsigned-in users do NOT auto-start VPN
- **Feat**: Light/Dark mode toggle in drawer (theme switcher works across all sections)
- **Feat**: ThemeProvider with persistent dark/light selection
- **UI**: Chat UUID moved from main header into drawer (free sidebar space)
- **UI**: "One-time boost" renamed to "Reaching a larger audience"
- **Fix**: Status views dedup — earnings now use `record_status_view_earning()` RPC
  with unique index `idx_earnings_dedup` preventing duplicate earnings per (user, status)
- **Perf**: Removed duplicate `StreamBuilder` for pinned messages in chat room
- **Perf**: `RepaintBoundary` around each message bubble for zero-lag scrolling
- **Perf**: Optimized `_buildProfileHeader` — removed redundant rebuild triggers
- **App Icon**: Updated brand icon with new N logo design
- **Chore**: Documented all changes inline with `[UPDATE 2026-06-08]` markers
- **Chore**: Bump version to 3.4.4+23

## 3.4.3+22 (2026-06-07)
- **Fix**: Admin grants now properly reflect in VPN access (tier+subscription_ends_at check)
- **Fix**: Device fingerprint toggle non-functional — missing SQL RPCs applied
- **Feat**: Search chats by name/email in the chat list
- **Fix**: `hide_last_seen` and `hide_read_receipts` columns added to profiles table
- **Fix**: `touch_last_seen` now respects `hide_last_seen` setting
- **Perf**: Replaced per-tile FutureBuilder with cached metadata lookup (reduces widget rebuilds)
- **Perf**: `ListView.builder` with `itemExtent` for smooth scrolling
- **Perf**: `RepaintBoundary` around each chat thread tile to prevent unnecessary repaints
- **Chore**: Bump version to 3.4.3+22

## 3.4.0+19
- WhatsApp-style bottom nav (Chats/Updates/Calls/Wallet)
- Admin signup-fingerprint toggle