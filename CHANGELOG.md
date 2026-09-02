# Changelog

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