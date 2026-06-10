# CHANGELOG

## [UPDATE 2026-06-10-P5] Supabase RLS Fix + WhatsApp-Like Theme

### Supabase Fix
- Fixed infinite recursion in `group_members` SELECT policy — replaced self-referencing query with `SECURITY DEFINER` function (`is_group_member`)
- Made `is_group_admin` function `SECURITY DEFINER` to prevent RLS recursion on INSERT/UPDATE
- Group creation now works without hitting `42P17` recursion error

### Theme Overhaul (WhatsApp-Like Colors)
- **Light mode:** WhatsApp green `#075E54` app bar, `#F0FAFA` background, white cards
- **Dark mode:** WhatsApp dark `#1F2C33` app bar, `#0B141A` background
- Updated `ThemeProvider` with WhatsApp-style colors across all sections
- Updated `AppColors` with proper dark/light variants
- Main shell bottom nav uses WhatsApp green selected state instead of violet
- Drawer background adapts: dark `#111B21`, light white
- Colors cascade through all screens (wallet, channels, calls, settings)

## [UPDATE 2026-06-10-P4] WhatsApp-Like Smoothness — Local-First Messaging & Batch Meta Loading

### Local-First Message Sending (chat_room_screen.dart)
- Messages now appear INSTANTLY in a local pending list before Supabase confirms
- Local pending messages are merged with Supabase Realtime stream — duplicates auto-removed
- No more waiting for server round-trip to see your own message (WhatsApp-like feel)

### Pre-Cached Thread Metadata (chat_list_screen.dart)
- Added `_preloadThreadMetaCache()` — all thread meta loaded eagerly in batch after threads refresh
- Eliminates per-tile async `getMeta` calls during scrolling (zero-lag chat list rendering)

### Parallel Data Loading
- Groups, discover users, and thread data loaded in parallel with `Future.wait`

## [UPDATE 2026-06-10-P3] Scroll Fix — Profile Header Now Scrolls With Content

### Scroll Behavior Fix
- Moved profile header (`_buildProfileHeader`) inside the scrollable ListView so it scrolls up with the content instead of staying sticky
- UUID input, search bar, and archived entry all scroll together (chat_list_screen.dart:2691-2745)

## [UPDATE 2026-06-10-P2] Notification Finalization & Drawer Rename

### Notifications — Final Setup
- Set `FIREBASE_PRIVATE_KEY` secret on Supabase Edge Function (send-push-notification)
- Verified Edge Function is ACTIVE and reachable
- Confirmed `fcm_tokens` table exists with proper RLS policies
- Edge function returns `sent:0` with reason `no_tokens` when no FCM tokens registered (expected — tokens register on user login)

### UI Changes
- Renamed hamburger drawer item from `• Admin` to `dot` (chat_list_screen.dart:1762)

## [UPDATE 2026-06-10] Performance Optimization & Notification Setup

### Performance Optimizations
- Added `RepaintBoundary` wrappers to message bubbles for zero-lag scrolling (chat_room_screen.dart)
- Added `const` constructors to stateless widgets (glass_container.dart)
- Optimized ListView physics with `BouncingScrollPhysics` + `AlwaysScrollableScrollPhysics`
- Added `cacheExtent: 500` for pre-building off-screen items
- Reduced unnecessary setState calls in chat_list_screen.dart with throttling
- Extracted sub-widgets to reduce rebuild scope

### Light/Dark Mode
- Light mode theme already implemented in hamburger menu (previous update)
- Toggle via drawer → Light Mode / Dark Mode

### Firebase Cloud Messaging (FCM) Notifications
- `notification_service.dart` — Local notification channels + WhatsApp-style messaging
- `fcm_service.dart` — FCM token management, background handler, foreground listener
- `firebase_options.dart` — Firebase project config for cdnnetchat-7db90
- `supabase_fcm_tokens_migration.sql` — fcm_tokens table in Supabase
- `send-push-notification/index.ts` — Supabase Edge Function for sending FCM pushes
- `supabase_service.dart` — `registerFcmToken()` / `removeFcmToken()` methods

### Supabase Setup
- `fcm_tokens` table already exists with proper RLS policies
- Edge function: `send-push-notification` deployed
- FCM tokens sync automatically on login via AuthStateChange listener