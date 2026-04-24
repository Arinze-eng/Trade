import 'package:flutter/material.dart';
import 'package:anywherelan/netshare/widgets/animated_hero_header.dart';
import 'package:anywherelan/netshare/widgets/app_background.dart';
import 'package:anywherelan/netshare/widgets/glass_card.dart';

/// Shared auth UI wrapper for sign-in / sign-up screens.
class AuthScaffold extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  final IconData icon;

  const AuthScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.icon = Icons.shield_outlined,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AnimatedHeroHeader(
                      title: 'CDN-NETSHARE',
                      subtitle: subtitle,
                      icon: icon,
                    ),
                    const SizedBox(height: 12),
                    GlassCard(
                      padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
                      child: child,
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
}
