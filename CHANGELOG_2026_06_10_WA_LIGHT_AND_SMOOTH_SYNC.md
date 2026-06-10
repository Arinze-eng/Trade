# Changelog — 2026-06-10 — WhatsApp Light Mode + Smooth Sync

## 🎨 1. WhatsApp-Exact Light Mode (no glass / no shiny)

### What changed
- **`lib/shared/theme/app_colors.dart`** — Centralized WhatsApp-2025/26 palette.
  - `chatRoomBgLight` (`#EFEAE2`) — beige paper for chat rooms
  - `outgoingBubbleLight` (`#D9FDD3`) — solid light green
  - `incomingBubbleLight` (`#FFFFFF`) — solid white
  - `textLight` (`#111B21`) — readable dark text on every bubble
  - `bubbleTextFor(brightness)` helper — always dark text in light mode
- **`lib/shared/widgets/glass_container.dart`** &
  **`lib/widgets/glass_container.dart`** — In light mode, the GlassContainer
  now renders as a flat solid white card with a 1-px subtle border + 1 px
  shadow. **No backdrop blur, no translucent gradient.** Dark mode still
  uses the original glass effect.
- **`lib/features/chat/screens/chat_room_screen.dart`**
  - Bubble background: solid color (`#D9FDD3` outgoing / `#FFFFFF` incoming)
    instead of `LinearGradient`.
  - Bubble text: dark `#111B21` in light mode (was white-on-green which made
    the text invisible).
  - Bubble shadow: subtle 1-px instead of the bright purple glow.
  - Removed the white `Colors.white.withOpacity(0.85)` haze layer that was
    making everything look shiny / glassy.
  - Chat-room background: solid `#EFEAE2` beige in light mode.
  - AppBar: solid white with thin shadow + `#111B21` icons (was transparent).
  - Message input: solid `#EFEAE2` container, white pill text-field.
  - Send button: WhatsApp green `#00A884` (was indigo `#6366F1`).

## ⚡ 2. Smooth Offline-First Sync (no lag, no double-send)

### What changed
- **`lib/features/chat/screens/chat_room_screen.dart`**
  - **Send guard** (`_sendInFlight`): rapid taps on the send button are now
    swallowed for 350 ms, preventing the "double message sent" bug.
  - **Smarter pending-message dedupe**: the local pending bubble now
    disappears the moment the real (server-confirmed) message arrives,
    based on `(sender, content, message_type, ≤30 s timestamp)` — fixing
    the "bouncing / message appears twice" UX hiccup.
  - **Stale-pending sweep**: pending messages older than 60 s are dropped
    from the in-memory list (the offline queue takes over for retries).
  - **Auto-enqueue on send failure**: if `sendMessage` throws (no network,
    server hiccup), the message goes into the offline queue for retry on
    reconnect.
- **`lib/core/offline_queue.dart`** — `flush()` now actually re-sends queued
  messages through `SupabaseService.sendMessage`, increments retry counts,
  and removes successful entries. Previously it was a no-op.
- **`lib/main.dart`** — Starts `OfflineMessageQueue.instance.startListening()`
  app-wide and runs an initial flush so messages queued from a previous
  offline session get delivered the moment the app opens with internet.

## 🔧 3. CI / Build

- Existing `.github/workflows/build_apk.yml` already builds the
  `arm64-v8a` APK on push. No workflow changes needed — push triggers
  the build automatically and the APK is uploaded as the
  `cdn-netchat-apk-arm64` artifact.

## ✅ Validation

`flutter analyze lib/` — **0 errors, 0 warnings**.
Only info-level `withOpacity` deprecation notices (pre-existing in the
codebase, harmless).
