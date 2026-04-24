import 'package:flutter/material.dart';
import 'package:anywherelan/netshare/config/supabase_config.dart';
import 'package:anywherelan/netshare/models/profile.dart';
import 'package:anywherelan/netshare/screens/auth/sign_in_screen.dart';
import 'package:anywherelan/netshare/screens/payments/paywall_screen.dart';
import 'package:anywherelan/netshare/screens/onboarding_gate.dart';
import 'package:anywherelan/netshare/services/profile_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Auth gate for CDN-NETSHARE UI-only integration.
///
/// - If not signed in → SignInScreen
/// - If signed in but trial/plan invalid → PaywallScreen
/// - Otherwise → HomeScreen (UI hub: account, payment, speed test)
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  Future<Profile?> _loadProfile() => ProfileService.getMyProfile();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: SupabaseConfig.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = SupabaseConfig.client.auth.currentSession;

        if (session == null) {
          return const SignInScreen();
        }

        return FutureBuilder<Profile?>(
          future: _loadProfile(),
          builder: (context, profSnap) {
            if (profSnap.connectionState != ConnectionState.done) {
              return const Scaffold(body: Center(child: CircularProgressIndicator()));
            }

            final profile = profSnap.data;

            // If profile row missing for any reason, force sign out (trigger should create it).
            if (profile == null) {
              SupabaseConfig.client.auth.signOut();
              return const SignInScreen();
            }

            if (profile.isBlocked) {
              SupabaseConfig.client.auth.signOut();
              return const PaywallScreen(
                title: 'Account blocked',
                subtitle:
                    'Your account has been blocked. Please contact support if this is a mistake.',
                showPlans: false,
              );
            }

            if (!profile.canUseApp) {
              // Keep the user signed in so they can subscribe from the paywall.
              return const PaywallScreen(
                title: 'Trial ended',
                subtitle:
                    'Your 5‑day trial has ended. Choose a plan to continue using CDN-NETSHARE.',
                showPlans: true,
              );
            }

            return const OnboardingGate();
          },
        );
      },
    );
  }
}
