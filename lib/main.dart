import 'dart:async';

import 'package:anywherelan/notifications.dart' as notif;
import 'package:anywherelan/providers.dart';
import 'package:anywherelan/server_interop/server_interop.dart';

// AWL original UI screens (kept intact)
import 'package:anywherelan/awl_dashboard_screen.dart';
import 'package:anywherelan/diagnostics_screen.dart';
import 'package:anywherelan/settings_screen.dart';
import 'package:anywherelan/blocked_peers_screen.dart';

import 'package:anywherelan/netshare/config/app_theme.dart';
import 'package:anywherelan/netshare/config/supabase_config.dart';
import 'package:anywherelan/netshare/auth/auth_gate.dart';
import 'package:anywherelan/netshare/screens/account_screen.dart';
import 'package:anywherelan/netshare/screens/auth/resend_verification_screen.dart';
import 'package:anywherelan/netshare/screens/auth/sign_up_screen.dart';
import 'package:anywherelan/netshare/screens/speed_test_screen.dart';
import 'package:anywherelan/netshare/screens/how_to_share_screen.dart';
import 'package:anywherelan/netshare/screens/payments/payment_screen.dart';
import 'package:anywherelan/netshare/screens/onboarding_screen.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:overlay_support/overlay_support.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _container = ProviderContainer();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // CDN-NETSHARE: Supabase (auth + payments)
  await Supabase.initialize(url: SupabaseConfig.url, anonKey: SupabaseConfig.anonKey);

  // AWL: keep server bootstrap in place (so awl-core can be used later)
  if (kIsWeb) {
    await initApp();
    await refreshProviders(_container).catchError((_) {});
  } else {
    _initAndroid();
  }

  runApp(UncontrolledProviderScope(container: _container, child: const MyApp()));
}

Future<void> _initAndroid() async {
  while (true) {
    var dialogTitle = '';
    var dialogBody = '';
    var stopLoop = false;

    final startError = await initApp();

    if (isServerRunning()) {
      await refreshProviders(_container);
      unawaited(refreshProvidersRepeated(_container));
      return;
    } else if (startError.contains('vpn not authorized')) {
      dialogTitle = 'You need to accept vpn connection to use this app';
    } else {
      dialogTitle = 'Failed to start server';
      dialogBody = startError;
      stopLoop = true;
    }

    await showDialog(
      context: notif.navigatorKey.currentContext!,
      builder: (context) {
        return SimpleDialog(
          title: Text(dialogTitle),
          contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          children: [
            if (dialogBody != '') SelectableText(dialogBody),
            if (dialogBody != '') const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: <Widget>[
                ElevatedButton(
                  child: const Text('OK'),
                  onPressed: () async {
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
          ],
        );
      },
    );

    if (stopLoop) return;
    await Future.delayed(const Duration(seconds: 6));
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final app = MaterialApp(
      title: 'CDN-NETSHARE',
      navigatorKey: notif.navigatorKey,
      theme: AppTheme.dark(),
      home: const AuthGate(),
      routes: {
        // CDN-NETSHARE flow
        OnboardingScreen.routeName: (context) => const OnboardingScreen(),
        '/sign-up': (context) => const SignUpScreen(),
        '/resend-verification': (context) => const ResendVerificationScreen(),
        '/account': (context) => const AccountScreen(),
        '/payment': (context) => const PaymentScreen(),
        '/speed-test': (context) => const SpeedTestScreen(),
        HowToShareScreen.routeName: (context) => const HowToShareScreen(),

        // AWL original screens (Status/Peers/Settings/Diagnostics/Logs)
        AwlDashboardScreen.routeName: (context) => const AwlDashboardScreen(),
        DiagnosticsScreen.routeName: (context) => DiagnosticsScreen(),
        DebugScreen.routeName: (context) => DebugScreen(),
        LogsScreen.routeName: (context) => LogsScreen(),
        AppSettingsScreen.routeName: (context) => AppSettingsScreen(),
        BlockedPeersScreen.routeName: (context) => BlockedPeersScreen(),
      },
    );

    if (kIsWeb) {
      return OverlaySupport(child: app);
    }
    return app;
  }
}
