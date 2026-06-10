import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:provider/provider.dart';

import 'core/vpn_splash_screen.dart';
import 'core/offline_queue.dart';
import 'services/vpn_manager.dart';
import 'services/notification_service.dart';
import 'services/background_message_poller.dart';
import 'services/supabase_service.dart';
import 'services/fcm_service.dart';
import 'services/theme_provider.dart';
import 'local_db/local_chat_store.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ══════════════════════════════════════════════════════════════════════
  // [UPDATE 2026-06-11-OFFLINE-BOOT] WhatsApp-style instant cold start.
  //
  // PROBLEM (was): every line below used a blocking `await` on a network
  // call BEFORE runApp(). When the device was offline, Firebase.initializeApp,
  // FCM.init, VpnManager.syncRemoteConfig, NotificationService.init, etc. would
  // stall or throw, so runApp() never executed → the app froze on the native
  // logo and never opened offline.
  //
  // FIX: the ONLY thing we await before runApp() is Supabase.initialize().
  // That call restores the saved auth session from local disk (it does NOT
  // need the network), so it returns fast even with no connectivity. We guard
  // it with a timeout so a slow/hostile network can never block the boot.
  // Everything else (Firebase, FCM, VPN, notifications, cleanup) is kicked off
  // AFTER runApp() in the background — the UI is already on screen by then.
  // ══════════════════════════════════════════════════════════════════════

  // Restore session locally — fast & offline-safe, but never let it hang boot.
  try {
    await Supabase.initialize(
      url: 'https://tlmyxuyqngkgwgjepeed.supabase.co',
      anonKey:
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRsbXl4dXlxbmdrZ3dnamVwZWVkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA3MTcwNTIsImV4cCI6MjA5NjI5MzA1Mn0.pcCDivFiRubY05NOeUBBYvi45TNfS1bSS1oEuRluBsU',
    ).timeout(const Duration(seconds: 4));
  } catch (e) {
    debugPrint('Supabase.initialize timed out/failed (continuing offline): $e');
  }

  // ── WhatsApp-style notification tap handler (set up synchronously) ──
  NotificationService.onNotificationTap = (payload) {
    _handleNotificationTap(payload);
  };

  // ── Paint the UI IMMEDIATELY — app opens instantly, even fully offline ──
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: VpnManager.instance),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: const MyApp(),
    ),
  );

  // ── Everything below runs in the BACKGROUND, after first paint ──
  unawaited(_initBackgroundServices());
}

/// All network-dependent / non-critical initialization. Runs AFTER runApp()
/// so the UI is never blocked. Each step is independently guarded so one
/// failure (e.g. offline) can never cascade.
Future<void> _initBackgroundServices() async {
  // VPN: pull remote config + auto-start (fire and forget, guarded).
  unawaited(() async {
    try {
      await VpnManager.instance.syncRemoteConfig();
    } catch (_) {}
    try {
      await VpnManager.instance.autoStartOnAppOpen();
    } catch (_) {}
  }());

  // Firebase core (needed for FCM). Guarded so offline can't throw up the stack.
  try {
    await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform);
  } catch (e) {
    debugPrint('Firebase init deferred/failed (offline?): $e');
  }

  // Local notification channels + background poller (mostly local, but cheap
  // to defer and keeps boot snappy).
  try {
    await NotificationService.init();
  } catch (_) {}
  try {
    await BackgroundMessagePoller.init();
  } catch (_) {}

  // [UPDATE 2026-06-10-WA] Offline message queue — auto-retry on reconnect.
  OfflineMessageQueue.instance.startListening();
  unawaited(OfflineMessageQueue.instance.flush());

  // Firebase Cloud Messaging (real-time push). Needs network — guarded.
  try {
    await FcmService().init();
  } catch (e) {
    debugPrint('FCM init deferred/failed (offline?): $e');
  }

  // Listen for auth state changes and sync FCM token
  Supabase.instance.client.auth.onAuthStateChange.listen((event) {
    if (event.event == AuthChangeEvent.signedIn && event.session != null) {
      final userId = event.session!.user.id;
      debugPrint('Auth state: signed in as $userId — syncing FCM token');
      FcmService().syncTokenToServer(userId);

      // [UPDATE 2026-06-10] Offline-first: hydrate all conversations on sign-in
      unawaited(() async {
        try {
          final store = LocalChatStore();
          await store.hydrateAllConversations(ownerUserId: userId);
          debugPrint('Offline-first: hydrated all conversations for $userId');
        } catch (_) {}
      }());

      // [UPDATE 2026-06-10] Clean up stale call signals on startup
      unawaited(SupabaseService().cleanupExpiredCallSignals());
    }
  });

  // Cleanup expired media + call signals from Supabase on app open — fire and forget
  unawaited(() async {
    try {
      final supabaseService = SupabaseService();
      await supabaseService.cleanupExpiredSupabaseMedia();
      // [UPDATE 2026-06-10] Clean up stale call signals to prevent phantom calls
      await supabaseService.cleanupExpiredCallSignals();
    } catch (_) {}
  }());
}

/// Handle notification tap navigation — WhatsApp-style.
void _handleNotificationTap(String? payload) {
  if (payload == null || payload.isEmpty) return;
  
  final context = NotificationService.navigatorKey.currentState?.context;
  if (context == null) return;

  final parts = payload.split(':');
  if (parts.length < 2) return;

  final type = parts[0];
  final id = parts.sublist(1).join(':');

  debugPrint('Notification tap navigation: type=$type, id=$id');

  switch (type) {
    case 'chat':
      _pendingNavigation = {'type': 'chat', 'id': id};
      break;
    case 'group':
      _pendingNavigation = {'type': 'group', 'id': id};
      break;
    case 'call':
      _pendingNavigation = {'type': 'call', 'id': id};
      break;
    case 'status':
      _pendingNavigation = {'type': 'status', 'id': id};
      break;
  }
}

Map<String, String>? _pendingNavigation;
Map<String, String>? getAndClearPendingNavigation() {
  final nav = _pendingNavigation;
  _pendingNavigation = null;
  return nav;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();

    return MaterialApp(
      title: 'CDN-NETCHAT',
      debugShowCheckedModeBanner: false,
      navigatorKey: NotificationService.navigatorKey,
      // [UPDATE 2026-06-08] Added light/dark mode support
      theme: ThemeProvider.lightTheme,
      darkTheme: ThemeProvider.darkTheme,
      themeMode: themeProvider.themeMode,
      // ── VPN Splash is the FIRST screen ──
      home: const VpnSplashScreen(),
    );
  }
}