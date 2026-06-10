import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../../models/user_tier.dart';
import '../../../services/cdn_chat_business_service.dart';
import '../../../shared/widgets/glass_container.dart';
import '../../../shared/widgets/money_text.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../services/supabase_service.dart';

class WalletScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  const WalletScreen({super.key, required this.currentUser});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  final _businessService = CdnChatBusinessService();
  final _supabaseService = SupabaseService();

  UserTier _tier = UserTier.free;
  double _balance = 0;
  double _dailyEarnings = 0;
  double _totalEarnings = 0;
  int _streak = 0;
  int _referralCount = 0;
  String _referralCode = '';
  List<Map<String, dynamic>> _transactions = [];
  List<Map<String, dynamic>> _cashOutHistory = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final userId = widget.currentUser['id'] as String;

      // Best-effort: re-evaluate referral milestones (awards bonuses if
      // any new threshold has been crossed since last visit).
      try {
        await _supabaseService.refreshMyReferralStatus();
      } catch (_) {}

      final results = await Future.wait([
        _businessService.getUserTier(userId),
        _businessService.getUserBalance(userId),
        _businessService.getDailyEarnings(userId),
        _businessService.getTotalEarnings(userId),
        _businessService.getOrCreateReferralCode(userId),
        _businessService.getTransactions(userId),
      ]);

      if (mounted) {
        // Load cash out history outside setState (async work)
        List<Map<String, dynamic>> cashOutHistory = [];
        try {
          cashOutHistory = await _businessService.getCashOutHistory(userId);
        } catch (_) {}

        setState(() {
          _tier = results[0] as UserTier;
          _balance = results[1] as double;
          _dailyEarnings = results[2] as double;
          _totalEarnings = results[3] as double;
          _referralCode = results[4] as String;
          _transactions = results[5] as List<Map<String, dynamic>>;
          _cashOutHistory = cashOutHistory;
          _streak = widget.currentUser['streak_days'] ?? 0;
          _referralCount = widget.currentUser['referral_count'] ?? 0;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  final _cashOutFullNameController = TextEditingController();
  final _cashOutAccountNumberController = TextEditingController();
  final _cashOutBankController = TextEditingController();
  final _cashOutEmailController = TextEditingController();

  void _showCashOutSheet() {
    final amountController = TextEditingController();
    _cashOutFullNameController.clear();
    _cashOutAccountNumberController.clear();
    _cashOutBankController.clear();
    _cashOutEmailController.clear();
    String selectedMethod = 'bank';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F2027),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final canCashOut = _balance >= CdnChatBusinessService.cashOutMin;
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 16,
                  bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Cash Out',
                        style: GoogleFonts.poppins(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 20,
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (!canCashOut)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.amber.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.amber.withOpacity(0.3),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.info_outline,
                                color: Colors.amber,
                                size: 20,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Minimum cash out: ₦${CdnChatBusinessService.cashOutMin.toInt().toString()}',
                                  style: GoogleFonts.poppins(
                                    color: Colors.amber,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                      // --- Amount Input ---
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 16,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          children: [
                            Text(
                              '₦',
                              style: Money.style(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: amountController,
                                keyboardType: TextInputType.number,
                                style: GoogleFonts.poppins(
                                  color: Colors.white,
                                  fontSize: 28,
                                  fontWeight: FontWeight.bold,
                                ),
                                decoration: InputDecoration(
                                  hintText: '0',
                                  hintStyle: GoogleFonts.poppins(
                                    color: Colors.white30,
                                    fontSize: 28,
                                  ),
                                  border: InputBorder.none,
                                  isDense: true,
                                ),
                                onChanged: (_) => setModalState(() {}),
                              ),
                            ),
                            Text(
                              'Max: ₦${_balance.toInt()}',
                              style: GoogleFonts.poppins(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // --- Personal Details (WhatsApp Cash Out Style) ---
                      const SizedBox(height: 16),
                      Text(
                        'Account Details',
                        style: GoogleFonts.poppins(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Full Name
                      TextField(
                        controller: _cashOutFullNameController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Full Name',
                          hintStyle: const TextStyle(color: Colors.white30),
                          prefixIcon: const Icon(Icons.person_rounded,
                              color: Colors.white38, size: 20),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.06),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                        ),
                      ),
                      const SizedBox(height: 10),
                      // Account Number
                      TextField(
                        controller: _cashOutAccountNumberController,
                        keyboardType: TextInputType.number,
                        maxLength: 10,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Account Number',
                          hintStyle: const TextStyle(color: Colors.white30),
                          prefixIcon: const Icon(Icons.numbers_rounded,
                              color: Colors.white38, size: 20),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.06),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                          counterText: '',
                        ),
                      ),
                      const SizedBox(height: 10),
                      // Bank
                      TextField(
                        controller: _cashOutBankController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Bank Name',
                          hintStyle: const TextStyle(color: Colors.white30),
                          prefixIcon: const Icon(Icons.account_balance_rounded,
                              color: Colors.white38, size: 20),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.06),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                        ),
                      ),
                      const SizedBox(height: 10),
                      // Email
                      TextField(
                        controller: _cashOutEmailController,
                        keyboardType: TextInputType.emailAddress,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Email Address',
                          hintStyle: const TextStyle(color: Colors.white30),
                          prefixIcon: const Icon(Icons.email_rounded,
                              color: Colors.white38, size: 20),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.06),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                        ),
                      ),

                      const SizedBox(height: 16),
                      // Withdrawal methods
                      _buildMethodTile(
                        ctx,
                        setModalState,
                        'bank',
                        '🏦',
                        'Bank Transfer',
                        selectedMethod,
                        (v) => selectedMethod = v,
                      ),
                      _buildMethodTile(
                        ctx,
                        setModalState,
                        'opay',
                        '💳',
                        'OPay',
                        selectedMethod,
                        (v) => selectedMethod = v,
                      ),
                      _buildMethodTile(
                        ctx,
                        setModalState,
                        'mobile_money',
                        '📱',
                        'MTN MoMo',
                        selectedMethod,
                        (v) => selectedMethod = v,
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton(
                          onPressed:
                              canCashOut
                                  ? () {
                                    final amount =
                                        double.tryParse(amountController.text) ??
                                        0;
                                    if (amount <
                                        CdnChatBusinessService.cashOutMin) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            'Minimum cash out is ₦${CdnChatBusinessService.cashOutMin.toInt()}',
                                          ),
                                        ),
                                      );
                                      return;
                                    }
                                    if (amount > _balance) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('Insufficient balance'),
                                        ),
                                      );
                                      return;
                                    }
                                    final fullName = _cashOutFullNameController.text.trim();
                                    final acctNum = _cashOutAccountNumberController.text.trim();
                                    final bank = _cashOutBankController.text.trim();
                                    final email = _cashOutEmailController.text.trim();
                                    if (fullName.isEmpty || acctNum.isEmpty || bank.isEmpty || email.isEmpty) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('Please fill in all details'),
                                        ),
                                      );
                                      return;
                                    }
                                    Navigator.pop(ctx);
                                    _processCashOut(amount, selectedMethod,
                                        fullName: fullName,
                                        accountNumber: acctNum,
                                        bank: bank,
                                        email: email);
                                  }
                                  : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                canCashOut
                                    ? const Color(0xFF25D366)
                                    : Colors.grey,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: Text(
                            canCashOut
                                ? 'Cash Out'
                                : '₦${CdnChatBusinessService.cashOutMin.toInt()} Minimum',
                            style: GoogleFonts.poppins(
                              color: Colors.black,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildMethodTile(
    BuildContext ctx,
    void Function(void Function()) setModalState,
    String value,
    String icon,
    String name,
    String selected,
    void Function(String) onSelect,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () {
          onSelect(value);
          setModalState(() {});
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color:
                selected == value
                    ? const Color(0xFF6366F1).withOpacity(0.15)
                    : Colors.white.withOpacity(0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color:
                  selected == value
                      ? const Color(0xFF6366F1)
                      : Colors.white.withOpacity(0.08),
            ),
          ),
          child: Row(
            children: [
              Text(icon, style: const TextStyle(fontSize: 24)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  name,
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color:
                        selected == value
                            ? const Color(0xFF6366F1)
                            : Colors.white38,
                    width: 2,
                  ),
                ),
                child:
                    selected == value
                        ? Center(
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(0xFF6366F1),
                            ),
                          ),
                        )
                        : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _processCashOut(double amount, String method,
      {String? fullName, String? accountNumber, String? bank, String? email}) async {
    try {
      final userId = widget.currentUser['id'] as String;
      final success = await _businessService.requestCashOut(
        userId: userId,
        amount: amount,
        method: method,
        accountDetails: {
          'method': method,
          'full_name': fullName ?? '',
          'account_number': accountNumber ?? '',
          'bank': bank ?? '',
          'email': email ?? '',
        },
        fullName: fullName,
        accountNumber: accountNumber,
        bank: bank,
        email: email,
      );
      if (mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Cash out of ₦${amount.toInt()} initiated! You\'ll receive it within 24 hours.',
              ),
              backgroundColor: Colors.green,
            ),
          );
          _loadData();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Cash out failed. Please try again.'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _showReferralSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F2027),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder:
          (ctx) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Icon(
                    Icons.people_alt_rounded,
                    color: Color(0xFF25D366),
                    size: 48,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Refer & Earn',
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 20,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Share your referral code. You earn ₦50 when a friend signs up and sends 10 messages!',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(
                      color: Colors.white60,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFF25D366).withOpacity(0.3),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Code: ',
                          style: GoogleFonts.poppins(
                            color: Colors.white54,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          _referralCode,
                          style: GoogleFonts.poppins(
                            color: const Color(0xFF25D366),
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Referral code copied: $_referralCode',
                            ),
                            backgroundColor: Colors.green,
                          ),
                        );
                      },
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: Text(
                        'Copy Code',
                        style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF25D366),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
    );
  }

  void _showBoostStatusSheet() {
    final paymentRefController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F2027),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder:
          (ctx) => SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Icon(
                    Icons.rocket_launch_rounded,
                    color: Colors.amber,
                    size: 48,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Reaching a larger audience',
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Get ~1,000 extra views on your next status post for ₦${CdnChatBusinessService.boostedStatusPrice}',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(
                      color: Colors.white60,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.amber.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.amber.withOpacity(0.2)),
                    ),
                    child: Column(
                      children: [
                        Text(
                          '₦${CdnChatBusinessService.boostedStatusPrice}',
                          style: GoogleFonts.poppins(
                            color: Colors.amber,
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Reaching a larger audience',
                          style: GoogleFonts.poppins(
                            color: Colors.amber.withOpacity(0.7),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: paymentRefController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Payment reference (from Paystack/Flutterwave)',
                      hintStyle: const TextStyle(color: Colors.white30),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.06),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Boost feature available after posting a status!',
                            ),
                            backgroundColor: Colors.amber,
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Text(
                        'Boost Now',
                        style: GoogleFonts.poppins(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // [UPDATE 2026-06-11-THEME] Make the Wallet follow the app theme so it is
    // no longer permanently dark while the rest of the app is light. In light
    // mode we use WhatsApp's flat white/grey surfaces; dark mode keeps the
    // original deep gradient.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scaffoldText = isDark ? Colors.white : const Color(0xFF111B21);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Wallet',
          style: GoogleFonts.poppins(
            color: scaffoldText,
            fontWeight: FontWeight.bold),
        ),
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [
                      const Color(0xFF25D366).withOpacity(0.22),
                      const Color(0xFF6366F1).withOpacity(0.16),
                      Colors.transparent,
                    ]
                  : [
                      const Color(0xFF25D366).withOpacity(0.10),
                      Colors.transparent,
                    ],
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.rocket_launch_rounded, color: Colors.amber),
            onPressed: _showBoostStatusSheet,
            tooltip: 'Reach a larger audience',
          ),
          IconButton(
            icon: const Icon(
              Icons.people_alt_rounded,
              color: Color(0xFF25D366),
            ),
            onPressed: _showReferralSheet,
            tooltip: 'Refer & Earn',
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? const [Color(0xFF06080C), Color(0xFF0B141A), Color(0xFF070B1E)]
                : const [Color(0xFFF7F8FA), Color(0xFFFFFFFF)],
          ),
        ),
        child:
            _isLoading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                  onRefresh: _loadData,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildBalanceCard(),
                      const SizedBox(height: 16),
                      _buildStatsGrid(),
                      const SizedBox(height: 16),
                      _buildActionButtons(),
                      const SizedBox(height: 20),
                      if (_tier.canEarn) _buildEarningRates(),
                      const SizedBox(height: 20),
                      _buildTransactions(),
                      const SizedBox(height: 20),
                      _buildCashOutHistory(),
                    ],
                  ),
                ),
      ),
    );
  }

  Widget _buildBalanceCard() {
    // [UPDATE 2026-06-11-THEME] The balance card keeps a fixed dark green/indigo
    // gradient in BOTH themes (like fintech wallets / WhatsApp Pay) so the white
    // balance text is always perfectly readable — instead of disappearing on a
    // white card in light mode.
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0E5C3F), Color(0xFF128C5E), Color(0xFF1F3A5F)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF128C5E).withOpacity(0.25),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Total Balance',
                style: GoogleFonts.poppins(color: Colors.white70, fontSize: 14),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color:
                      _tier.canEarn
                          ? const Color(0xFF25D366).withOpacity(0.15)
                          : Colors.grey.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color:
                        _tier.canEarn ? const Color(0xFF25D366) : Colors.grey,
                  ),
                ),
                child: Text(
                  _tier.displayName,
                  style: GoogleFonts.poppins(
                    color:
                        _tier.canEarn ? const Color(0xFF25D366) : Colors.grey,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '₦${_balance.toStringAsFixed(2)}',
            style: Money.style(
              color: Colors.white,
              fontSize: 38,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Available for cash out',
            style: GoogleFonts.poppins(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    ).animate().scale(duration: 400.ms, curve: Curves.easeOutBack);
  }

  Widget _buildStatsGrid() {
    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            'Today\'s Earnings',
            '₦${_dailyEarnings.toStringAsFixed(2)}',
            Icons.trending_up,
            const Color(0xFF25D366),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildStatCard(
            'Day Streak',
            '$_streak days',
            Icons.local_fire_department,
            Colors.orange,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildStatCard(
            'Referrals',
            '$_referralCount',
            Icons.people,
            const Color(0xFF6366F1),
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    // [UPDATE 2026-06-11-THEME] Theme-aware text so values are readable on the
    // flat white card in light mode (white text was invisible before).
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final valueColor = isDark ? Colors.white : const Color(0xFF111B21);
    final labelColor = isDark ? Colors.white38 : const Color(0xFF667781);
    return GlassContainer(
      blur: 12,
      opacity: 0.06,
      borderRadius: 14,
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 6),
          Text(
            value,
            style: Money.style(
              color: valueColor,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: GoogleFonts.poppins(color: labelColor, fontSize: 9),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed:
                _balance >= CdnChatBusinessService.cashOutMin
                    ? _showCashOutSheet
                    : null,
            icon: const Icon(Icons.download_rounded, size: 18),
            label: Text(
              'Cash Out',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  _balance >= CdnChatBusinessService.cashOutMin
                      ? const Color(0xFF25D366)
                      : Colors.grey,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _showReferralSheet,
            icon: const Icon(Icons.share_rounded, size: 18),
            label: Text(
              'Invite',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF25D366),
              side: const BorderSide(color: Color(0xFF25D366)),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEarningRates() {
    return GlassContainer(
      blur: 12,
      opacity: 0.06,
      borderRadius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Earning Rates',
            style: GoogleFonts.poppins(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 12),
          _buildRateRow(
            Icons.visibility_rounded,
            'Status View',
            '₦2.50 per unique view',
          ),
          _buildRateRow(
            Icons.chat_rounded,
            'Message Sent',
            '₦0.75 per message',
          ),
          _buildRateRow(
            Icons.people_alt_rounded,
            'Referral',
            '₦50 per referral',
          ),
          _buildRateRow(
            Icons.local_fire_department_rounded,
            'Daily Streak',
            '₦20/day (50+ msgs)',
          ),
          const Divider(color: Colors.white12, height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Daily Cap',
                style: GoogleFonts.poppins(color: Colors.white60, fontSize: 12),
              ),
              Text(
                '₦2,000 max/day',
                style: GoogleFonts.poppins(
                  color: Colors.amber,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRateRow(IconData icon, String label, String rate) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF25D366), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.poppins(color: Colors.white70, fontSize: 13),
            ),
          ),
          Text(
            rate,
            style: GoogleFonts.poppins(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransactions() {
    // [UPDATE 2026-06-11-THEME] Theme-aware colors for the transactions list.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final txText = isDark ? Colors.white : const Color(0xFF111B21);
    final txMuted = isDark ? Colors.white38 : const Color(0xFF667781);
    final txTileBg = isDark ? Colors.white.withOpacity(0.04) : const Color(0xFFF0F2F5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Recent Transactions',
          style: GoogleFonts.poppins(
            color: txText,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 10),
        if (_transactions.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  Icon(
                    Icons.receipt_long_rounded,
                    color: txMuted.withOpacity(0.4),
                    size: 48,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No transactions yet',
                    style: GoogleFonts.poppins(
                      color: txMuted,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          ...List.generate(_transactions.length, (i) {
            final t = _transactions[i];
            final type = t['type']?.toString() ?? '';
            final amount = (t['amount'] as num?)?.toDouble() ?? 0;
            final status = t['status']?.toString() ?? 'completed';
            final desc = t['description']?.toString() ?? type;

            IconData icon;
            Color iconColor;
            if (type == 'earning') {
              icon = Icons.trending_up;
              iconColor = const Color(0xFF25D366);
            } else if (type == 'cash_out') {
              icon = Icons.download_rounded;
              iconColor = Colors.orange;
            } else if (type == 'boost_payment' || type == 'subscription') {
              icon = Icons.rocket_launch_rounded;
              iconColor = Colors.amber;
            } else {
              icon = Icons.receipt_long_rounded;
              iconColor = txMuted;
            }

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: txTileBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: iconColor.withOpacity(0.15),
                    child: Icon(icon, color: iconColor, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          desc,
                          style: GoogleFonts.poppins(
                            color: txText,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          t['created_at']?.toString().substring(0, 10) ?? '',
                          style: GoogleFonts.poppins(
                            color: txMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${type == 'earning' ? '+' : '-'}₦${amount.toStringAsFixed(2)}',
                        style: Money.style(
                          color:
                              type == 'earning'
                                  ? const Color(0xFF25D366)
                                  : txText,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (status == 'pending')
                        Text(
                          'Pending',
                          style: GoogleFonts.poppins(
                            color: Colors.amber,
                            fontSize: 10,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }

  // Cash Out History section — shows user the status of their cash out requests
  Widget _buildCashOutHistory() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Cash Out History',
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 10),
        if (_cashOutHistory.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  Icon(
                    Icons.download_rounded,
                    color: Colors.white.withOpacity(0.1),
                    size: 48,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No cash out requests yet',
                    style: GoogleFonts.poppins(
                      color: Colors.white24,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          ...List.generate(_cashOutHistory.length, (i) {
            final co = _cashOutHistory[i];
            final amount = (co['amount'] as num?)?.toDouble() ?? 0;
            final status = (co['status'] ?? 'pending').toString();
            final method = (co['method'] ?? '').toString();
            final fullName = (co['full_name'] ?? '').toString();
            final acctNumber = (co['account_number'] ?? '').toString();
            final bank = (co['bank'] ?? '').toString();
            final createdAt = (co['created_at'] ?? '').toString();
            final adminNotes = (co['admin_notes'] ?? '').toString();

            Color statusColor;
            String statusText;
            IconData statusIcon;
            if (status == 'completed') {
              statusColor = const Color(0xFF25D366);
              statusText = 'Paid ✓';
              statusIcon = Icons.check_circle_rounded;
            } else if (status == 'rejected') {
              statusColor = Colors.redAccent;
              statusText = 'Rejected ✗';
              statusIcon = Icons.cancel_rounded;
            } else {
              statusColor = Colors.amber;
              statusText = 'Pending';
              statusIcon = Icons.access_time_rounded;
            }

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: statusColor.withOpacity(0.3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: statusColor.withOpacity(0.15),
                        child: Icon(statusIcon, color: statusColor, size: 18),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '₦${amount.toStringAsFixed(2)} via ${method.toUpperCase()}',
                              style: GoogleFonts.poppins(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (fullName.isNotEmpty && acctNumber.isNotEmpty)
                              Text(
                                '$fullName • $acctNumber ($bank)',
                                style: GoogleFonts.poppins(
                                  color: Colors.white54,
                                  fontSize: 11,
                                ),
                              ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          statusText,
                          style: GoogleFonts.poppins(
                            color: statusColor,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (adminNotes.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Note: $adminNotes',
                      style: GoogleFonts.poppins(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ],
                  Text(
                    createdAt.substring(0, 10),
                    style: GoogleFonts.poppins(
                      color: Colors.white24,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }
}
