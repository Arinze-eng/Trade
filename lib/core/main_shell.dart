import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/supabase_service.dart';
import '../shared/theme/app_colors.dart';
import '../features/chat/screens/chat_list_screen.dart';
import '../features/status/screens/status_screen.dart';
import '../features/cdn_chat/screens/wallet_screen.dart';
import 'calls_history_screen.dart';

/// WhatsApp-style bottom nav shell:
///   [Chats] [Updates] [Calls] [Wallet]
class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.profile});

  /// [UPDATE 2026-09-02] Profile supplied by AuthWrapper (cached or fallback).
  /// The shell renders IMMEDIATELY — a background refresh updates it when the
  /// server responds. Nothing here waits on the network before painting.
  final Map<String, dynamic> profile;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  late Map<String, dynamic> _profile = widget.profile;
  final _supabaseService = SupabaseService();
  bool _refreshedOnce = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshProfile());
  }

  @override
  void didUpdateWidget(covariant MainShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // AuthWrapper pushed a fresher profile down → adopt it.
    if (widget.profile != oldWidget.profile && mounted) {
      setState(() => _profile = widget.profile);
    }
  }

  Future<void> _refreshProfile() async {
    if (_refreshedOnce) return;
    _refreshedOnce = true;
    try {
      final user = _supabaseService.currentUser;
      if (user == null) return;
      final p = await _supabaseService
          .getProfile(user.id)
          .timeout(const Duration(seconds: 15), onTimeout: () => null);
      if (p == null || !mounted) return;
      if (p['is_blocked'] == true) return; // AuthWrapper handles blocking
      setState(() => _profile = p);
    } catch (_) {
      // Offline is fine — we already rendered with the cached profile.
    }
  }

  @override
  Widget build(BuildContext context) {
    // [UPDATE 2026-06-08-P2] Use theme-aware background
    final bgColor = Theme.of(context).scaffoldBackgroundColor;

    final pages = <Widget>[
      ChatListScreen(currentUser: _profile),
      StatusScreen(currentUser: _profile),
      const CallsHistoryScreen(),
      WalletScreen(currentUser: _profile),
    ];

    return Scaffold(
      backgroundColor: bgColor,
      // IndexedStack keeps each tab's state alive (like WhatsApp).
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: _BottomNav(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  const _BottomNav({required this.currentIndex, required this.onTap, this.themeBgColor});
  final Color? themeBgColor;

  @override
  Widget build(BuildContext context) {
    final items = const [
      (Icons.chat_bubble_rounded, Icons.chat_bubble_outline_rounded, 'Chats'),
      (Icons.donut_large_rounded, Icons.donut_large_outlined, 'Updates'),
      (Icons.call_rounded, Icons.call_outlined, 'Calls'),
      (Icons.account_balance_wallet_rounded,
          Icons.account_balance_wallet_outlined, 'Wallet'),
    ];

    return Container(
      decoration: BoxDecoration(
        color: themeBgColor ?? const Color(0xFF0F2027),
        border: Border(
          top: BorderSide(color: Colors.white.withOpacity(0.06), width: 1),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: List.generate(items.length, (i) {
              final selected = currentIndex == i;
              final (active, inactive, label) = items[i];
              return Expanded(
                child: InkWell(
                  onTap: () => onTap(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 4),
                          decoration: BoxDecoration(
                            color: selected
                                ? AppColors.violet.withOpacity(0.18)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Icon(
                            selected ? active : inactive,
                            color: selected
                                ? AppColors.violet
                                : Colors.white60,
                            size: 22,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          label,
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w400,
                            color:
                                selected ? Colors.white : Colors.white60,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _NoProfilePlaceholder extends StatelessWidget {
  final String label;
  const _NoProfilePlaceholder({required this.label});

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(title: Text(label)),
      body: const Center(
        child: Text('Sign in to view this tab',
            style: TextStyle(color: Colors.white70)),
      ),
    );
  }
}
