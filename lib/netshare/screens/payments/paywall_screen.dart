import 'package:flutter/material.dart';
import 'package:anywherelan/netshare/config/supabase_config.dart';
import 'package:anywherelan/netshare/screens/payments/payment_screen.dart';
import 'package:anywherelan/netshare/widgets/app_background.dart';
import 'package:anywherelan/netshare/widgets/glass_card.dart';
import 'package:anywherelan/netshare/widgets/gradient_button.dart';

class PaywallScreen extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool showPlans;

  const PaywallScreen({
    super.key,
    required this.title,
    required this.subtitle,
    required this.showPlans,
  });

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
                    const SizedBox(height: 0),
                    GlassCard(
                      child: Row(
                        children: [
                          Container(
                            height: 54,
                            width: 54,
                            decoration: BoxDecoration(
                              color: cs.primary.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Icon(Icons.lock_outline, color: cs.primary),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
                                const SizedBox(height: 4),
                                Text(subtitle, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    GlassCard(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (showPlans) ...[
                              GradientButton(
                                onPressed: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(builder: (_) => const PaymentScreen()),
                                  );
                                },
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.workspace_premium_outlined),
                                    SizedBox(width: 10),
                                    Text('Choose a plan'),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 10),
                            ],
                            OutlinedButton.icon(
                              onPressed: () async {
                                await SupabaseConfig.client.auth.signOut();
                              },
                              icon: const Icon(Icons.logout_rounded),
                              label: const Text('Back to sign in'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Tip: If you just signed up, make sure you verified your email first.',
                      textAlign: TextAlign.center,
                      style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    )
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
