import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../models/user_tier.dart';
import '../../../services/cdn_chat_business_service.dart';
import '../../../services/supabase_service.dart';
import '../../../shared/widgets/glass_container.dart';

class SubscriptionScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  const SubscriptionScreen({super.key, required this.currentUser});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  UserTier _selectedTier = UserTier.basicPremium;
  bool _isProcessing = false;
  final _businessService = CdnChatBusinessService();

  Future<void> _processPayment(UserTier tier) async {
    setState(() => _isProcessing = true);
    try {
      final userId = widget.currentUser['id'] as String;
      final amount = tier.monthlyPriceNaira;

      // Flutterwave payment link
      String flutterwaveUrl;
      if (tier == UserTier.basicPremium) {
        flutterwaveUrl = 'https://flutterwave.com/pay/kscuerhsb4by';
      } else if (tier == UserTier.pro) {
        flutterwaveUrl = 'https://flutterwave.com/pay/bojecsy48sgs';
      } else {
        flutterwaveUrl = 'https://flutterwave.com/pay/cdnchat_${tier.apiValue}_$amount';
      }

      if (await canLaunchUrl(Uri.parse(flutterwaveUrl))) {
        await launchUrl(
          Uri.parse(flutterwaveUrl),
          mode: LaunchMode.externalApplication,
        );
      }

      // Show verification dialog
      if (mounted) _showVerifyDialog(tier);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Payment error: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
        setState(() => _isProcessing = false);
      }
    }
  }

  void _showVerifyDialog(UserTier tier) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF203A43),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            title: Text(
              'Verify Payment',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Have you completed the ${tier.displayName} subscription payment?',
                  style: GoogleFonts.poppins(color: Colors.white70),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF25D366).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: const Color(0xFF25D366).withOpacity(0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.check_circle,
                        color: Color(0xFF25D366),
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Your subscription will be activated immediately after verification.',
                          style: GoogleFonts.poppins(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  setState(() => _isProcessing = false);
                },
                child: Text(
                  'Cancel',
                  style: GoogleFonts.poppins(color: Colors.white54),
                ),
              ),
              ElevatedButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  try {
                    final userId = widget.currentUser['id'] as String;
                    final success = await _businessService.activateSubscription(
                      userId: userId,
                      tier: tier,
                      paymentProvider: 'flutterwave',
                      paymentReference:
                          'manual_${DateTime.now().millisecondsSinceEpoch}',
                    );
                    if (mounted) {
                      if (success) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              '${tier.displayName} Activated! Start earning.',
                            ),
                            backgroundColor: Colors.green,
                          ),
                        );
                        Navigator.pop(context, true);
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Activation failed. Contact support.',
                            ),
                            backgroundColor: Colors.redAccent,
                          ),
                        );
                      }
                      setState(() => _isProcessing = false);
                    }
                  } catch (e) {
                    if (mounted) {
                      setState(() => _isProcessing = false);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Error: $e'),
                          backgroundColor: Colors.redAccent,
                        ),
                      );
                    }
                  }
                },
                child: Text(
                  'Yes, Verify',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F2027),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Plans',
          style: GoogleFonts.poppins(fontWeight: FontWeight.bold),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Header
          Text(
            'Choose Your Plan',
            style: GoogleFonts.poppins(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Unlock earning and premium features',
            style: GoogleFonts.poppins(color: Colors.white60, fontSize: 14),
          ),
          const SizedBox(height: 24),

          // Free Tier
          _buildTierCard(UserTier.free, [
            'Messaging (1-on-1 & groups)',
            'View/post status',
            'Join channels',
            'Refer others',
          ], null),

          const SizedBox(height: 16),

          // Basic Premium
          _buildTierCard(UserTier.basicPremium, [
            'Everything in Free',
            'Earn from activity (₦2.50/view, ₦0.75/msg)',
            'Ad-free experience',
            'Custom themes',
            'Larger file sharing',
            'Exclusive stickers',
          ], 'Most Popular'),

          const SizedBox(height: 16),

          // Pro
          _buildTierCard(UserTier.pro, [
            'Everything in Basic Premium',
            'Automated replies',
            'AI chat box',
            'Create channels',
            'Priority support',
          ], 'Best Value'),

          const SizedBox(height: 24),

          // Upgrade button
          if (_selectedTier != UserTier.free)
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed:
                    _isProcessing ? null : () => _processPayment(_selectedTier),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF25D366),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  elevation: 8,
                  shadowColor: const Color(0xFF25D366).withOpacity(0.4),
                ),
                child:
                    _isProcessing
                        ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black,
                          ),
                        )
                        : Text(
                          'Upgrade to ${_selectedTier.displayName} — ${_selectedTier.monthlyPrice}/month',
                          style: GoogleFonts.poppins(
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
              ),
            ),

          const SizedBox(height: 16),

          // Info note
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.amber.withOpacity(0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.amber.withOpacity(0.2)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: Colors.amber, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Payment via Flutterwave. Need help? Contact support on WhatsApp: +2348138474528',
                    style: GoogleFonts.poppins(
                      color: Colors.amber,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildTierCard(UserTier tier, List<String> features, String? badge) {
    final isSelected = _selectedTier == tier;
    final isPremium = tier != UserTier.free;

    return GestureDetector(
      onTap:
          tier != UserTier.free
              ? () => setState(() => _selectedTier = tier)
              : null,
      child: GlassContainer(
        blur: 18,
        opacity: 0.06,
        borderRadius: 20,
        padding: const EdgeInsets.all(20),
        gradientColors:
            isSelected
                ? [
                  const Color(0xFF25D366).withOpacity(0.1),
                  const Color(0xFF6366F1).withOpacity(0.05),
                ]
                : [
                  Colors.white.withOpacity(0.05),
                  Colors.white.withOpacity(0.02),
                ],
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Text(
                          tier.displayName,
                          style: GoogleFonts.poppins(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (isSelected) ...[
                          const SizedBox(width: 8),
                          const Icon(
                            Icons.check_circle,
                            color: Color(0xFF25D366),
                            size: 20,
                          ),
                        ],
                      ],
                    ),
                    Text(
                      tier.monthlyPrice + '/mo',
                      style: GoogleFonts.poppins(
                        color:
                            isPremium
                                ? const Color(0xFF25D366)
                                : Colors.white60,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ...features.map(
                  (f) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.check_rounded,
                          color: const Color(0xFF25D366),
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            f,
                            style: GoogleFonts.poppins(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (badge != null)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF25D366), Color(0xFF1DB954)],
                    ),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    badge,
                    style: GoogleFonts.poppins(
                      color: Colors.black,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ).animate().scale(duration: 300.ms, curve: Curves.easeOutBack);
  }
}
