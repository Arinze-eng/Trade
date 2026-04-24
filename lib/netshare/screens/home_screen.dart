import 'package:flutter/material.dart';
import 'package:anywherelan/netshare/widgets/animated_hero_header.dart';
import 'package:anywherelan/netshare/widgets/app_background.dart';
import 'package:anywherelan/netshare/widgets/glass_card.dart';
import 'package:anywherelan/netshare/widgets/gradient_button.dart';

/// Home hub (UI-only)
///
/// No P2P/VPN screens are exposed here.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;

    return Scaffold(
      body: AppBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('CDN-NETSHARE'),
            actions: [
              IconButton(
                tooltip: 'Account',
                onPressed: () => Navigator.pushNamed(context, '/account'),
                icon: const Icon(Icons.person_outline),
              ),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const AnimatedHeroHeader(
                  title: 'CDN-NETSHARE',
                  subtitle: 'Secure access with subscription + speed test.',
                  icon: Icons.wifi_tethering_rounded,
                ),
                const SizedBox(height: 16),
                GlassCard(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Tools',
                          style: t.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 10),
                        GradientButton(
                          onPressed: () => Navigator.pushNamed(context, '/payment'),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.workspace_premium_outlined),
                              SizedBox(width: 10),
                              Text('Payment & Unlock'),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: () => Navigator.pushNamed(context, '/speed-test'),
                          icon: const Icon(Icons.speed),
                          label: const Text('Speed Test (Standalone)'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
