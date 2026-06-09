import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:provider/provider.dart';

import 'core/vpn_splash_screen.dart';
import 'services/vpn_manager.dart';
import 'services/notification_service.dart';
import 'services/background_message_poller.dart';
import 'services/supabase_service.dart';
import 'services/fcm_service.dart';
import 'services/theme_provider.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── FASTER LOADING: Parallel initialization ──

  // VPN auto-start FIRST (before anything else) — fire and forget
  // [UPDATE 2026-06-08] Removed ignoreAccessCheck — VPN is PRO only
  try {
    await VpnManager.instance.syncRemoteConfig();
  } catch (_) {}
  unawaited(VpnManager.instance.autoStartOnAppOpen());

  // ── FASTER LOADING: Initialize Firebase and Supabase in parallel ──
  await Future.wait([
    Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform),
    Supabase.initialize(
      url: 'https://tlmyxuyqngkgwgjepeed.supabase.co',
      anonKey:
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRsbXl4dXlxbmdrZ3dnamVwZWVkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA3MTcwNTIsImV4cCI6MjA5NjI5MzA1Mn0.pcCDivFiRubY05NOeUBBYvi45TNfS1bSS1oEuRluBsU',
    ),
  ]);

  // ── Local notification channels ──
  await NotificationService.init();
  await BackgroundMessagePoller.init();

  // ── Firebase Cloud Messaging (real-time push notifications ONLY) ──
  await FcmService().init();

  // ── WhatsApp-style notification tap handler ──
  NotificationService.onNotificationTap = (payload) {
    _handleNotificationTap(payload);
  };

  // Listen for auth state changes and sync FCM token
  Supabase.instance.client.auth.onAuthStateChange.listen((event) {
    if (event.event == AuthChangeEvent.signedIn && event.session != null) {
      final userId = event.session!.user.id;
      debugPrint('Auth state: signed in as $userId — syncing FCM token');
      FcmService().syncTokenToServer(userId);
    }
  });

  // Cleanup expired media from Supabase on app open — fire and forget
  unawaited(() async {
    try {
      final supabaseService = SupabaseService();
      await supabaseService.cleanupExpiredSupabaseMedia();
    } catch (_) {}
  }());

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: VpnManager.instance),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: const MyApp(),
    ),
  );
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