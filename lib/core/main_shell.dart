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
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  final _supabaseService = SupabaseService();
  Map<String, dynamic>? _profile;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    try {
      final user = _supabaseService.currentUser;
      if (user == null) {
        setState(() => _loading = false);
        return;
      }
      final p = await _supabaseService.getProfile(user.id);
      final usernameFromMeta = (user.userMetadata?['username'] ?? '').toString();
      final displayNameFromMeta =
          (user.userMetadata?['display_name'] ?? '').toString();
      final fallback = {
        'id': user.id,
        'email': user.email,
        'username': usernameFromMeta.isNotEmpty
            ? usernameFromMeta
            : user.id.substring(0, 8).toUpperCase(),
        'display_name': displayNameFromMeta,
      };
      if (mounted) {
        setState(() {
          _profile = p ?? fallback;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // [UPDATE 2026-06-08-P2] Use theme-aware background
    final bgColor = Theme.of(context).scaffoldBackgroundColor;
    
    if (_loading) {
      return Scaffold(
        backgroundColor: bgColor,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final pages = <Widget>[
      const ChatListScreen(),
      _profile == null
          ? const _NoProfilePlaceholder(label: 'Updates')
          : StatusScreen(currentUser: _profile!),
      const CallsHistoryScreen(),
      _profile == null
          ? const _NoProfilePlaceholder(label: 'Wallet')
          : WalletScreen(currentUser: _profile!),
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
  const _BottomNav({required this.currentIndex, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF0F2027) : Colors.white;
    final borderColor = isDark
        ? Colors.white.withOpacity(0.06)
        : Colors.grey.shade200;
    final iconColor = isDark ? Colors.white60 : Colors.grey.shade500;
    final textColor = isDark ? Colors.white60 : Colors.grey.shade600;
    final selectedTextColor = isDark ? Colors.white : AppColors.violet;
    final selectedBg = isDark
        ? AppColors.violet.withOpacity(0.18)
        : AppColors.violet.withOpacity(0.10);

    final items = const [
      (Icons.chat_bubble_rounded, Icons.chat_bubble_outline_rounded, 'Chats'),
      (Icons.donut_large_rounded, Icons.donut_large_outlined, 'Updates'),
      (Icons.call_rounded, Icons.call_outlined, 'Calls'),
      (Icons.account_balance_wallet_rounded,
          Icons.account_balance_wallet_outlined, 'Wallet'),
    ];

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(
          top: BorderSide(color: borderColor, width: 1),
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
                                ? selectedBg
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Icon(
                            selected ? active : inactive,
                            color: selected
                                ? AppColors.violet
                                : iconColor,
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
                                selected ? selectedTextColor : textColor,
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
