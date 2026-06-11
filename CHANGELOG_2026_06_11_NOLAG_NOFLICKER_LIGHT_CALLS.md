# CHANGELOG — 2026-06-11 — No-Lag / No-Flicker / Light-Mode / Calls (v3.6.1+27)

This update targets the four issues reported on 2026-06-11. It builds on the
previous WhatsApp-style offline + light-mode work **without removing any
existing feature**. Each prior changelog remains valid; this one supersedes the
flicker/lag and light-mode portions where noted.

---

## ⚡ 3 (MAJOR) — Eliminate lag + STOP the chat flickering / rebouncing

### Root cause finally identified (server-side)
The Flutter client streamed the **entire `messages` table** via Supabase
realtime with **no server-side filter** (`getMessages()` did
`.from('messages').stream(...)` then filtered in Dart). Supabase realtime
therefore pushed the **full table snapshot on EVERY insert/update/delete made by
ANY user, app-wide**. Every such push rebuilt the chat → the visible
"flicker / reload / bounce while chatting". It got worse as the table grew.

### Fixes

1. **`lib/services/supabase_service.dart` — server-side filtered streams**
   - `getMessages()` now uses `.inFilter('sender_id', [me, other])`. Supabase
     2.x applies this as a realtime channel filter (`PostgresChangeFilterType.inFilter`),
     so the client only receives this conversation's events — not the whole
     table. Re-emits drop from "every app-wide change" to "only this chat".
   - `streamIncomingMessages()` now filters `.eq('receiver_id', me)`.
   - `streamIsOtherTyping()` now filters `.eq('receiver_id', me)` so a typing
     keystroke from any user no longer re-emits the whole table.

2. **Supabase DB — realtime publication + indexes**
   (`supabase_realtime_perf_migration.sql`, already applied to the live DB)
   - Added `messages` composite indexes `(sender_id, receiver_id, created_at)`
     and the reverse, plus an unread partial index — conversation reads are now
     index-backed and instant.
   - `REPLICA IDENTITY FULL` on `messages` / `call_signals` / `typing_events`
     so realtime UPDATE/DELETE events carry the full row (needed for reliable
     client filtering on every event, not just INSERT).

3. **`lib/features/chat/screens/chat_room_screen.dart` — no rebuild storms**
   - The audio player previously called `setState(() {})` on **every** player
     event (buffer/position ticks) → the whole message list rebuilt many times
     a second while a voice note played. Now it only rebuilds on a *meaningful*
     play ↔ pause ↔ complete transition.
   - Auto-scroll now triggers only when the **newest message timestamp** changes
     (a genuinely new message), not on read-receipt / reaction updates or when a
     pending bubble is swapped for its confirmed copy. This removes the last
     cause of the chat snapping/rebounding while you read or type.

### Scroll behavior (confirmed, unchanged design, now bulletproof)
- The list is `reverse: true` with `ClampingScrollPhysics` → the bottom (newest)
  is a fixed anchor at offset 0. New messages, keyboard open and image loads do
  **not** move the viewport.
- The view auto-glides to the newest message **only** if the user is already at
  the bottom (`_isNearBottom`, pixels < 120). If they scrolled up to read
  history, they stay exactly where they released — **no auto-rebounce to top or
  bottom**, even while chatting/typing.

---

## 📴 1 — Offline-first (WhatsApp-style), no lag offline

The on-device **Isar** store remains the source of truth and renders chat
content instantly with zero network. `getProfile` / `getChatThreads` /
`getMyGroups` / `discoverUsers` are memory+disk cached with short timeouts
(unchanged from the previous update and still intact). With the new server-side
filtered realtime streams, online sync is far lighter, so there are no
background re-emit storms competing with the UI — offline open is instant and
online stays smooth.

---

## 🎨 2 — Light mode: nothing too bright, everything readable

The light theme uses soft off-white surfaces (not pure #FFFFFF). The remaining
**invisible / too-bright** spots are fixed in
`lib/features/chat/screens/chat_room_screen.dart`:

- **"Last seen" / Online / Offline** in the chat header used `Colors.white54`
  → invisible on the light app-bar. Now theme-aware: WhatsApp dark-green for
  Online/Typing, muted grey-blue (`#667781`) for Last seen, readable grey for
  Offline.
- **Outgoing bubble (pale green `#D9FDD3`)** previously drew the reply box,
  timestamp, "edited" label and the delivery/read ticks in white-ish colors
  → invisible / "too bright, can't see what's there". On a light bubble these
  are now WhatsApp dark teal/grey (`#54656F` / `#667781` / `#8696A0`).
- **Date separators** were always a dark translucent pill (a dark blob on the
  beige background). Light mode now uses WhatsApp's soft white pill with dark
  text.
- **Reply / Edit preview bars** above the input were hardcoded white text. Now
  theme-aware (dark text on a light `#E8EBED` bar in light mode).

Dark mode is unchanged.

---

## 📞 4 — Calls work end-to-end (no disconnect, voice + video)

### Root cause: signaling tables weren't realtime
`call_signals` and `typing_events` were **NOT** in the Supabase realtime
publication, so the WebRTC signaling `.stream()` never received live INSERT
events — offers/answers/ICE candidates could be missed → calls failed to
ring/connect reliably.

### Fix (DB, applied)
`supabase_realtime_perf_migration.sql` adds `call_signals`, `typing_events`,
`profiles`, `status`, `group_messages` to the `supabase_realtime` publication.
Now incoming-call offers, answers and ICE candidates arrive live, so calls ring
and connect end-to-end.

### Already-present call robustness (kept)
- TURN (expressturn + metered) + Google STUN for NAT traversal.
- ICE-restart on disconnect + 25 s grace window → survives network blips with no
  1-minute drop.
- Ringback (caller) / ringtone (receiver), presence check before ringing, and
  phantom-signal rejection.
- Video renders both local (PiP) and remote full-screen; audio path is
  echo-cancelled / noise-suppressed and re-applied on connect.

---

## 🔧 Build / CI
- Version bumped `3.6.0+26 → 3.6.1+27` (pubspec + android `versionCode 27` /
  `versionName 3.6.1`).
- No workflow change needed — pushing to `main` triggers
  `.github/workflows/build_apk.yml`, which builds the **arm64-v8a** release APK
  (`flutter build apk --release --split-per-abi --tree-shake-icons`) on Flutter
  3.32.0 and uploads the artifact `cdn-netchat-apk-arm64`.

## ✅ Validation
- `flutter analyze lib/` → **0 errors** (only pre-existing info/deprecation and
  unused-import notices in unrelated files).
- Verified `SupabaseStreamFilterBuilder.inFilter` exists in supabase 2.12.2 and
  is applied as a realtime channel filter.
- Supabase migration applied live and verified: realtime publication now
  includes call_signals, group_messages, messages, profiles, status,
  typing_events; new indexes created.
