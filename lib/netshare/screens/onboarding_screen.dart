import 'package:anywherelan/awl_dashboard_screen.dart';
import 'package:anywherelan/netshare/widgets/app_background.dart';
import 'package:anywherelan/netshare/widgets/glass_card.dart';
import 'package:anywherelan/netshare/widgets/gradient_button.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OnboardingScreen extends StatelessWidget {
  static const routeName = '/onboarding';
  static const _prefsKey = 'onboarding_done_v1';

  const OnboardingScreen({super.key});

  static Future<bool> isDone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefsKey) ?? false;
  }

  static Future<void> setDone() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, true);
  }

  Future<void> _finish(BuildContext context) async {
    await setDone();
    if (!context.mounted) return;
    Navigator.of(context).pushReplacementNamed(AwlDashboardScreen.routeName);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 8),
                    Text(
                      'Welcome',
                      textAlign: TextAlign.center,
                      style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Before you continue',
                      textAlign: TextAlign.center,
                      style: t.bodyMedium?.copyWith(color: Colors.white70, height: 1.35),
                    ),
                    const SizedBox(height: 16),
                    GlassCard(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _bullet(
                              icon: Icons.privacy_tip_outlined,
                              title: 'Privacy',
                              body: 'Only connect to devices and peers you trust.',
                              color: cs.tertiary,
                            ),
                            const SizedBox(height: 12),
                            _bullet(
                              icon: Icons.workspace_premium_outlined,
                              title: 'Subscription',
                              body: 'Your access depends on your trial or paid plan.',
                              color: cs.primary,
                            ),
                            const SizedBox(height: 12),
                            _bullet(
                              icon: Icons.speed,
                              title: 'Speed test',
                              body: 'Use the standalone speed test to check network quality.',
                              color: cs.secondary,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    GradientButton(
                      onPressed: () => _finish(context),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_circle_outline),
                          SizedBox(width: 10),
                          Text('Continue to dashboard'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'This screen shows once.',
                      textAlign: TextAlign.center,
                      style: t.bodySmall?.copyWith(color: Colors.white54),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bullet({
    required IconData icon,
    required String title,
    required String body,
    required Color color,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 40,
          width: 40,
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(body, style: const TextStyle(color: Colors.white70, height: 1.25)),
            ],
          ),
        ),
      ],
    );
  }
}
