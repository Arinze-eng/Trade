# CHANGELOG — 2026-06-11 — WhatsApp-style Offline-First Wiring (v3.6.0+26)

## Goal
Make the app open and operate **instantly, even fully offline** — no more
"rolling spinner, then the chat loads". Supabase stays as the backend
(transport + sync), while the on-device cache is the source of truth for
instant rendering. WhatsApp-style: content is always there, the network
syncs silently in the background.

## What changed

### 1. `lib/core/main_shell.dart` — instant app shell
- **Before:** `_loading = true` showed a full-screen `CircularProgressIndicator`
  that blocked the ENTIRE app until `getProfile()` returned. On a cold/offline
  start that was the visible "rolling sign".
- **After:** the shell paints **immediately** using an instant fallback profile
  built synchronously from the restored auth session metadata (no await, no
  network). The real profile is hydrated in the background. No full-screen
  spinner — ever.

### 2. `lib/features/chat/screens/chat_list_screen.dart` — instant chat list
- **Before:** `_initApp()` set `_isInitializing = true` (full-screen spinner)
  and then `await`ed `getProfile → checkAccessStatus → refreshVpnAccess →
  Future.wait([threads, discover, groups, status])` BEFORE clearing the
  spinner. Offline/slow networks → long "Initializing…" screen.
- **After:**
  - Loads cached local Isar threads **instantly** (works fully offline).
  - Renders the shell with an instant fallback profile (no await).
  - Moves ALL network work (profile, access check, VPN, threads/discover/
    groups/status, business data) into a guarded background hydrate.
  - `_isInitializing` now defaults to `false` so the full-screen spinner is
    never flashed; the list area shows its own lightweight empty/loading state.

### 3. `lib/services/supabase_service.dart` — offline-first list caching
- Added a generic `_cachedList(...)` helper (memory + disk cache + short
  network timeout) so list RPCs return the last good result **instantly** and
  **never hang** the UI when offline/slow.
- Applied to:
  - `getChatThreads()`  — chat list
  - `getMyGroups()`     — groups/channels
  - `discoverUsers()`   — discover sheet
- Each now: tries network with a 6s timeout → falls back to memory cache →
  falls back to disk cache → finally `[]`. Successful fetches refresh the
  cache silently.

## Result
- App opens instantly on cold start, online or offline.
- Chat list, groups, profile, and settings are present immediately from cache.
- No spinner-then-load; the network syncs in the background like WhatsApp.
- Offline message queue + offline-first conversation stream (already present)
  continue to handle sending/receiving when connectivity returns.

## Build
- Version bumped to `3.6.0+26` (pubspec + android versionCode 26).
- APK is built via GitHub Actions (`.github/workflows/build_apk.yml`),
  release, split-per-abi, **arm64-v8a** artifact `cdn-netchat-apk-arm64`.
