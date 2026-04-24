import 'package:anywherelan/netshare/widgets/app_background.dart';
import 'package:anywherelan/netshare/widgets/glass_card.dart';
import 'package:flutter/material.dart';

class HowToShareScreen extends StatelessWidget {
  static const routeName = '/how-to-share';

  const HowToShareScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    Widget step(int n, String title, String body) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$n. $title',
                  style: t.titleMedium?.copyWith(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 8),
                Text(body, style: t.bodyMedium?.copyWith(height: 1.35, color: cs.onSurface)),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: AppBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(title: const Text('How to share internet')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Use CDN to share your connection using the tunnel (Status/Peers).',
                  style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                step(
                  1,
                  'Subscribe / make sure trial is active',
                  'If your trial has ended, open Subscription and complete payment. Then come back and open the dashboard.',
                ),
                step(
                  2,
                  'Open the CDN dashboard',
                  'From the dashboard you can see Status and Peers. The tunnel must be running for sharing to work.',
                ),
                step(
                  3,
                  'Start the tunnel',
                  'Open the hamburger menu (top-left) and tap Start. Accept the VPN permission prompt when asked.',
                ),
                step(
                  4,
                  'Add the other device as a peer',
                  'Go to the Peers tab and tap + to add a peer. Do the same on the other device so both devices know each other.',
                ),
                step(
                  5,
                  'Confirm connection',
                  'Go back to Status. When connected, the peer will show as online/connected. Now traffic can route through the tunnel.',
                ),
                step(
                  6,
                  'Share the connection',
                  'On the device with internet, keep the tunnel running. On the other device, connect through the peer/tunnel path. If speed is low, run Speed test from the menu to confirm your base internet speed.',
                ),
                const SizedBox(height: 8),
                Text(
                  'Tip: If things feel stuck, restart the tunnel from the menu (Stop then Start).',
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
