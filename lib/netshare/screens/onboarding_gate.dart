import 'package:anywherelan/awl_dashboard_screen.dart';
import 'package:anywherelan/netshare/screens/onboarding_screen.dart';
import 'package:flutter/material.dart';

/// Decides whether to show onboarding or go straight to AWL dashboard.
class OnboardingGate extends StatelessWidget {
  const OnboardingGate({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: OnboardingScreen.isDone(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        final done = snap.data == true;
        if (done) {
          return const AwlDashboardScreen();
        }
        return const OnboardingScreen();
      },
    );
  }
}
