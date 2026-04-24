import 'dart:async';

import 'package:flutter/material.dart';
import 'package:anywherelan/netshare/widgets/app_background.dart';
import 'package:anywherelan/netshare/config/supabase_config.dart';
import 'package:anywherelan/netshare/models/profile.dart';
import 'package:anywherelan/netshare/services/profile_service.dart';
import 'package:app_links/app_links.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:uuid/uuid.dart';

class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key});

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  StreamSubscription? _sub;
  bool _verifying = false;
  Profile? _profile;

  static const _premiumLink = 'https://flutterwave.com/pay/xhceft1fdei1';
  static const _basicLink = 'https://flutterwave.com/pay/hhpuddzjsfrf';

  // Flutterwave only supports HTTPS redirect_url.
  // We redirect to a Supabase Edge Function HTTPS page, which then deep-links into the app.
  static const _redirectBase =
      'https://bztwadpqoohabbemqutp.functions.supabase.co/pay-redirect';

  @override
  void initState() {
    super.initState();
    _refreshProfile();
    _listenDeepLinks();
  }

  Future<void> _refreshProfile() async {
    final p = await ProfileService.getMyProfile();
    if (!mounted) return;
    setState(() => _profile = p);
  }

  void _listenDeepLinks() {
    final appLinks = AppLinks();
    _sub = appLinks.uriLinkStream.listen((uri) {
      if (uri.scheme != 'natproxy') return;
      if (uri.host != 'payment-callback') return;
      _handlePaymentCallback(uri);
    }, onError: (_) {
      // ignore
    });
  }

  Future<void> _handlePaymentCallback(Uri uri) async {
    final transactionId = uri.queryParameters['transaction_id'] ??
        uri.queryParameters['transactionId'] ??
        uri.queryParameters['id'];
    final status = uri.queryParameters['status'];
    final plan = uri.queryParameters['plan'];
    final txRef = uri.queryParameters['tx_ref'] ?? uri.queryParameters['txRef'];

    if (transactionId == null || plan == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Payment callback missing transaction id.')),
      );
      return;
    }

    // If Flutterwave sends status and it isn't successful, just show message.
    if (status != null && status != 'successful') {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Payment status: $status')),
      );
      return;
    }

    await _verifyPayment(transactionId: transactionId, plan: plan, txRef: txRef);
  }

  Future<void> _verifyPayment({
    required String transactionId,
    required String plan,
    String? txRef,
  }) async {
    setState(() => _verifying = true);
    try {
      final res = await SupabaseConfig.client.functions.invoke(
        'verify-flutterwave',
        body: {
          'transaction_id': transactionId,
          'plan': plan,
          'tx_ref': txRef,
        },
      );

      if (res.status != 200) {
        throw Exception(res.data?.toString() ?? 'Verification failed');
      }

      await _refreshProfile();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Payment verified. Features unlocked.')),
      );

      // After unlock, take user to CDN-NETSHARE dashboard.
      Navigator.of(context).pushNamedAndRemoveUntil(
        '/awl',
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Verify failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _startPayment(String plan) async {
    final txRef = const Uuid().v4();

    final base = plan == 'premium' ? _premiumLink : _basicLink;

    // Flutterwave hosted payment links often accept `redirect_url` and `tx_ref`.
    // We include `plan` so we know what to unlock on callback.
    final redirectUrl = Uri.parse(_redirectBase).replace(queryParameters: {
      'plan': plan,
      'tx_ref': txRef,
    });

    final uri = Uri.parse(base).replace(queryParameters: {
      'redirect_url': redirectUrl.toString(),
      'tx_ref': txRef,
    });

    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open payment page.')),
      );
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Widget _planCard({
    required String title,
    required String price,
    required String plan,
    required List<String> bullets,
    required List<Color> gradient,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradient,
        ),
        border: Border.all(color: Colors.black12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    price,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ...bullets.map(
              (b) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check_circle, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(b)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _verifying ? null : () => _startPayment(plan),
                child: const Text('Pay & unlock'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final plan = _profile?.plan;
    final expires = _profile?.planExpiresAt;

    return Scaffold(
      body: AppBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(title: const Text('Plans')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_verifying)
                  const LinearProgressIndicator(minHeight: 3)
                else
                  const SizedBox(height: 3),
                const SizedBox(height: 12),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Subscription status',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        Text('Plan: ${plan ?? '-'}'),
                        Text('Expires: ${expires?.toIso8601String() ?? '-'}'),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: _refreshProfile,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Refresh status'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _planCard(
                  title: 'Basic (15Mbps plan)',
                  price: '₦20,000 / month',
                  plan: 'basic',
                  bullets: const [
                    'Unlock basic usage after trial',
                    'Reliable P2P experience',
                    'Monthly renewal',
                  ],
                  gradient: [
                    Colors.white,
                    Theme.of(context).colorScheme.primary.withOpacity(0.10),
                  ],
                ),
                const SizedBox(height: 12),
                _planCard(
                  title: 'Premium (30Mbps plan)',
                  price: '₦40,000 / month',
                  plan: 'premium',
                  bullets: const [
                    'Unlock premium usage',
                    'Priority features (as enabled in-app)',
                    'Monthly renewal',
                  ],
                  gradient: [
                    Theme.of(context).colorScheme.tertiary.withOpacity(0.18),
                    Colors.white,
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'After payment, you’ll be redirected back to the app automatically.\n'
                  'If redirect doesn’t happen, return to the app and tap “Refresh status”.',
                  style: TextStyle(
                    color: Colors.greenAccent,
                    fontWeight: FontWeight.w600,
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
