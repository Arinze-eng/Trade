import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../../../core/debouncer.dart';
import '../../../core/offline_queue.dart';
import '../../../services/supabase_service.dart';
import '../../../services/notification_service.dart';
import '../../../services/drive_backup_service.dart';
import '../../../services/vpn_manager.dart';
import '../../../services/theme_provider.dart';
import '../../../main.dart' show getAndClearPendingNavigation;
import '../../../shared/widgets/glass_container.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../local_db/local_chat_store.dart';
import '../../../local_db/saved_contacts_store.dart';
import '../../../screens/admin_screen.dart';

import 'chat_room_screen.dart';
import 'group_chat_room_screen.dart';
import 'create_group_screen.dart';
import 'archived_chats_screen.dart';

import '../../status/screens/status_screen.dart';
import './../../../models/user_tier.dart';
import './../../../services/cdn_chat_business_service.dart';
import './../../../features/cdn_chat/screens/wallet_screen.dart';
import './../../../features/cdn_chat/screens/subscription_screen.dart';
import './../../../features/channels/screens/channels_screen.dart';
import '../../vpn_ui/widgets/vpn_card.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen>
    with SingleTickerProviderStateMixin {
  final _supabaseService = SupabaseService();
  final _uuidController = TextEditingController();
  final _localChatStore = LocalChatStore();
  final _savedContactsStore = SavedContactsStore();

  List<SavedContact> _savedContacts = const [];

  Map<String, dynamic>? _profile;

  List<Map<String, dynamic>> _threads = [];
  bool _threadsLoading = false;

  List<Map<String, dynamic>> _groups = [];
  bool _groupsLoading = false;

  List<Map<String, dynamic>> _discoverUsers = [];
  bool _discoverLoading = false;
  final _discoverSearchController = TextEditingController();
  final _threadSearchController = TextEditingController();

  bool _isInitializing = true;
  String? _initError;

  bool _hasAccess = true;
  Timer? _lastSeenTimer;

  StreamSubscription<List<Map<String, dynamic>>>? _incomingSub;
  int _lastIncomingMessageId = 0;
  bool _isInChatRoom = false;

  StreamSubscription? _threadRefreshSub;

  StreamSubscription<List<Map<String, dynamic>>>? _callSignalSub;
  final Set<String> _seenCallSignalIds = {};

  // Users with active status (for green ring indicator)
  Set<String> _usersWithActiveStatus = {};
  final _cdnBusiness = CdnChatBusinessService();
  // Cache for thread meta to avoid FutureBuilder lag on every setState
  final Map<String, ChatThreadMeta?> _threadMetaCache = {};
  // ── WHATSAPP-LIKE: All thread metas loaded eagerly in batch ──
  bool _threadMetaCacheLoaded = false;
  UserTier _userTier = UserTier.free;
  double _walletBalance = 0;

  // [UPDATE 2026-06-08-LAGFIX] Throttled setState to prevent rebuild storms
  final _setStateThrottler = SetStateThrottler(
    throttleInterval: const Duration(milliseconds: 80),
  );

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  @override
  void dispose() {
    _uuidController.dispose();
    _setStateThrottler.dispose();
    _discoverSearchController.dispose();
    _threadSearchController.dispose();
    _lastSeenTimer?.cancel();
    _incomingSub?.cancel();
    _threadRefreshSub?.cancel();
    _callSignalSub?.cancel();
    super.dispose();
  }

  Future<void> _initApp() async {
    try {
      // --------------------------------------------------
      // 1) Load persisted / local state first
      // --------------------------------------------------
      final savedContacts = await _savedContactsStore.getAll();
      final user = _supabaseService.currentUser;

      if (user == null) {
        if (mounted) {
          setState(() {
            _isInitializing = false;
            _initError = 'Not signed in';
          });
        }
        return;
      }

      // --------------------------------------------------
      // 2) Fetch profile (with tier & wallet in parallel)
      // --------------------------------------------------
      final results = await Future.wait([
        _supabaseService.getProfile(user.id),
        _cdnBusiness.getUserTier(user.id),
        _supabaseService.fetchWalletBalance(user.id),
      ]);
      final profile = results[0] as Map<String, dynamic>?;
      final tier = results[1] as UserTier;
      final balance = results[2] as double;

      if (!mounted) return;

      // --------------------------------------------------
      // 3) Load threads / groups / contacts
      // --------------------------------------------------
      final threads = await _supabaseService.listChatThreads(user.id);
      //                                              .where((t) => t['id'] != t['other_user_id'])
      //                                              .toList();
      final groups = await _supabaseService.getUserGroups(user.id);
      final threadUserIds = <String>{};
      for (final t in threads) {
        final oid = (t['other_user_id'] ?? t['other_id'] ?? '').toString();
        if (oid.isNotEmpty) threadUserIds.add(oid);
      }
      // Include group member IDs so we can show status rings for group members too
      for (final g in groups) {
        try {
          final ms = g['members'] as List<dynamic>?;
          if (ms != null) {
            for (final m in ms) {
              if (m is Map<String, dynamic>) {
                final mid = m['id']?.toString() ?? '';
                if (mid.isNotEmpty) threadUserIds.add(mid);
              }
            }
          }
        } catch (_) {}
      }
      if (threadUserIds.isNotEmpty) {
        try {
          final activeUsers = await _supabaseService
              .getActiveUsers(threadUserIds.toList());
          if (mounted) {
            _usersWithActiveStatus = activeUsers;
          }
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _savedContacts = savedContacts;
          _profile = profile;
          _userTier = tier;
          _walletBalance = balance;
          _threads = threads;
          _groups = groups;
          _isInitializing = false;
        });
      }

      // --------------------------------------------------
      // 4) Subscribe to incoming messages
      // --------------------------------------------------
      _incomingSub = _supabaseService
          .streamIncomingMessages(user.id)
          .listen((messages) {
        if (_isInChatRoom) return;
        for (final msg in messages) {
          final id = msg['id'] as int? ?? 0;
          if (id > _lastIncomingMessageId) {
            _lastIncomingMessageId = id;
          }
        }
        // Refresh threads on new incoming messages
        if (!_isInChatRoom) _refreshThreads();
      });

      // --------------------------------------------------
      // 5) Subscribe to thread changes (listener for group creation)
      // --------------------------------------------------
      _threadRefreshSub = _supabaseService
          .onUserThreadsChanged()
          .listen((_) => _refreshThreads());

      // --------------------------------------------------
      // 6) Subscribe to call signals (ringing)
      // --------------------------------------------------
      try {
        _callSignalSub = _supabaseService
            .streamIncomingCallSignals(user.id)
            .listen((signals) {
          for (final sig in signals) {
            final id = sig['id']?.toString() ?? '';
            if (_seenCallSignalIds.contains(id)) continue;
            _seenCallSignalIds.add(id);
            final callerId = (sig['caller_id'] ?? '').toString();
            if (callerId.isEmpty) continue;
            // Fetch caller name
            _supabaseService.getProfile(callerId).then((caller) {
              if (!mounted || caller == null) return;
              final name = (caller['display_name'] ?? caller['username'] ?? 'Someone').toString();
              _showCallNotification(name, callerId);
            });
          }
        });
        // Remove old seen IDs after 30 seconds
        Timer.periodic(const Duration(seconds: 30), (_) {
          if (_seenCallSignalIds.length > 100) _seenCallSignalIds.clear();
        });
      } catch (_) {}

      // --------------------------------------------------
      // 7) Periodic active-status refresh
      // --------------------------------------------------
      _lastSeenTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (threadUserIds.isNotEmpty && mounted) {
          _supabaseService
              .getActiveUsers(threadUserIds.toList())
              .then((active) {
            if (mounted) setState(() => _usersWithActiveStatus = active);
          }).catchError((_) {});
        }
      });

      // --------------------------------------------------
      // 8) Preload thread meta cache
      // --------------------------------------------------
      _preloadThreadMetaCache(user.id);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _initError = e.toString();
        });
      }
    }
  }

  Future<void> _refreshThreads() async {
    final user = _supabaseService.currentUser;
    if (user == null) return;
    try {
      final threads = await _supabaseService.listChatThreads(user.id);
      if (mounted) {
        setState(() => _threads = threads);
      }
    } catch (_) {}
  }

  Future<void> _loadGroups() async {
    final user = _supabaseService.currentUser;
    if (user == null) return;
    try {
      final groups = await _supabaseService.getUserGroups(user.id);
      if (mounted) setState(() => _groups = groups);
    } catch (_) {}
  }

  // ── WHATSAPP-LIKE: Eager-batch all thread metas ──
  Future<void> _preloadThreadMetaCache(String ownerUserId) async {
    try {
      final metas = await _localChatStore.getAllMeta(ownerUserId: ownerUserId);
      for (final m in metas) {
        _threadMetaCache[m.otherId] = m;
      }
      _threadMetaCacheLoaded = true;
      if (mounted) setState(() {});
    } catch (_) {}
  }

  // ───────────────────────────────────────────────────────
  // DRAWER
  // ───────────────────────────────────────────────────────

  // ─── WHATSAPP-STYLE DRAWER ───
  Widget _buildDrawer() {
    final displayName = _profile?['display_name'] ?? '';
    final username = _profile?['username'] ?? '';
    final email = _profile?['email'] ?? '';
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Drawer(
      backgroundColor: isDark ? const Color(0xFF111B21) : Colors.white,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          // Header with user info + UUID
          Container(
            padding: const EdgeInsets.fromLTRB(20, 50, 20, 20),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF6366F1), Color(0xFF4F46E5)],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 32,
                      backgroundColor: Colors.white.withOpacity(0.2),
                      child: Text(
                        (displayName.isNotEmpty ? displayName : username)[0]
                            .toUpperCase(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const Spacer(),
                    // Tier badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color:
                            _hasAccess
                                ? Colors.green.withOpacity(0.2)
                                : Colors.orange.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        _hasAccess ? 'ACTIVE' : 'EXPIRED',
                        style: GoogleFonts.poppins(
                          color:
                              _hasAccess
                                  ? Colors.greenAccent
                                  : Colors.orangeAccent,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  displayName.isNotEmpty ? displayName : username,
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                // Show UUID prominently (WhatsApp-style "Your UUID")
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.tag_rounded, color: Colors.white70, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        username,
                        style: GoogleFonts.poppins(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  email,
                  style: GoogleFonts.poppins(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

          // ─── DRAWER MENU ITEMS (WhatsApp-style) ───

          // Status
          _drawerItem(Icons.update_rounded, 'Status', () {
            Navigator.pop(context);
            if (_profile != null) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => StatusScreen(currentUser: _profile!),
                ),
              );
            }
          }),

          // Wallet
          _drawerItem(Icons.wallet_rounded, 'Wallet', () {
            Navigator.pop(context);
            if (_profile != null) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => WalletScreen(currentUser: _profile!),
                ),
              );
            }
          }, subtitle: _userTier.canEarn ? '₦${_walletBalance.toStringAsFixed(2)}' : null),

          // Channels
          _drawerItem(Icons.tag_rounded, 'Channels', () {
            Navigator.pop(context);
            if (_profile != null) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ChannelsScreen(currentUser: _profile!),
                ),
              );
            }
          }),

          // Calls
          _drawerItem(Icons.call_rounded, 'Calls', () {
            Navigator.pop(context);
            _showCallsTab();
          }),

          Divider(color: isDark ? Colors.white12 : Colors.grey.shade200, height: 1),

          // Create Channel (Pro only)
          _drawerItem(
            Icons.add_circle_outline_rounded,
            'Create Channel',
            () {
              Navigator.pop(context);
              if (_userTier.canCreateChannels) {
                if (_profile == null) return;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        CreateGroupScreen(currentUser: _profile!),
                  ),
                ).then((_) {
                  _loadGroups();
                  _refreshThreads();
                });
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Pro tier required to create channels'),
                    backgroundColor: Colors.orange,
                  ),
                );
              }
            },
          ),

          // New Group
          _drawerItem(Icons.group_add_rounded, 'New Group', () {
            Navigator.pop(context);
            if (_profile == null) return;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    CreateGroupScreen(currentUser: _profile!),
              ),
            ).then((_) {
              _loadGroups();
              _refreshThreads();
            });
          }),

          Divider(color: isDark ? Colors.white12 : Colors.grey.shade200, height: 1),

          // VPN
          _drawerItem(Icons.vpn_lock_rounded, 'Offline Mode VPN (60MB)', () {
            Navigator.pop(context);
            _showVpnBottomSheet();
          }, iconColor: const Color(0xFF2AABEE)),

          // Starred Messages
          _drawerItem(Icons.star_rounded, 'Starred Messages', () {
            Navigator.pop(context);
            _showStarredMessages();
          }, iconColor: Colors.amber),

          // Chat Backup
          _drawerItem(Icons.backup_rounded, 'Chat Backup', () {
            Navigator.pop(context);
            _showBackupRestoreSheet();
          }, iconColor: const Color(0xFF2AABEE)),

          // Subscription
          _drawerItem(Icons.subscriptions_rounded, 'Subscription', () {
            Navigator.pop(context);
            if (_profile != null) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) =>
                      SubscriptionScreen(currentUser: _profile!),
                ),
              ).then((_) {
                if (_profile != null) {
                  _cdnBusiness.getUserTier(_profile!['id']).then((tier) {
                    if (mounted) setState(() => _userTier = tier);
                  });
                }
              });
            }
          }, subtitle: _userTier.displayName),

          // [UPDATE 2026-06-08] Theme toggle — light/dark mode
          Consumer<ThemeProvider>(
            builder: (context, themeProvider, _) {
              return _drawerItem(
                themeProvider.isDarkMode ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                themeProvider.isDarkMode ? 'Light Mode' : 'Dark Mode',
                () {
                  Navigator.pop(context);
                  themeProvider.toggleTheme();
                },
                iconColor: Colors.amber,
              );
            },
          ),

          Divider(color: isDark ? Colors.white12 : Colors.grey.shade200, height: 1),

          // [UPDATE 2026-06-10] Renamed from 'Admin' to 'dot' per user request
          _drawerItem(Icons.admin_panel_settings_rounded, 'dot', () {
            Navigator.pop(context);
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const AdminScreen()),
            );
          }, iconColor: Colors.amber),

          // Privacy
          _drawerItem(Icons.privacy_tip_rounded, 'Privacy', () {
            Navigator.pop(context);
            _showPrivacySettings();
          }),

          Divider(color: isDark ? Colors.white12 : Colors.grey.shade200, height: 1),

          // Delete Account
          _drawerItem(Icons.person_remove_rounded, 'Delete Account', () async {
            Navigator.pop(context);
            await _confirmAndDeleteAccount();
          }, iconColor: Colors.orangeAccent, textColor: Colors.orangeAccent),

          // Logout
          _drawerItem(Icons.logout_rounded, 'Logout', () async {
            Navigator.pop(context);
            VpnManager.instance.stopByUser();
            VpnManager.instance.resetAutoStart();
            await _supabaseService.signOut();
          }, iconColor: Colors.redAccent, textColor: Colors.redAccent),
        ],
      ),
    );
  }

  Widget _drawerItem(IconData icon, String text, VoidCallback onTap,
      {Color? iconColor, Color? textColor, String? subtitle}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final defaultIconColor = isDark ? Colors.white70 : Colors.grey.shade600;
    final defaultTextColor = isDark ? Colors.white : Colors.black87;
    return ListTile(
      leading: Icon(icon, color: iconColor ?? defaultIconColor, size: 22),
      title: Text(
        text,
        style: GoogleFonts.poppins(
          color: textColor ?? defaultTextColor,
          fontWeight: FontWeight.w500,
          fontSize: 14,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: GoogleFonts.poppins(
                color: isDark ? Colors.white38 : Colors.grey.shade500,
                fontSize: 11,
              ),
            )
          : null,
      onTap: onTap,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 0),
    );
  }

  // ─── Show Calls as modal (moved from tab) ───
  void _showCallsTab() {
    if (_profile == null) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF0F2027) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white24 : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Call History',
                    style: GoogleFonts.poppins(
                      color: isDark ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _buildCallsList(scrollController),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildCallsList(ScrollController scrollController) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _supabaseService.streamCallHistory(_profile!['id']),
      builder: (context, snapshot) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final calls = snapshot.data!;
        if (calls.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.call_end_rounded,
                  color: isDark ? Colors.white.withOpacity(0.1) : Colors.grey.shade200,
                  size: 80,
                ),
                const SizedBox(height: 16),
                Text(
                  'No call history yet',
                  style: GoogleFonts.poppins(
                    color: isDark ? Colors.white24 : Colors.grey.shade400,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          );
        }

        final dividerColor = isDark ? Colors.white.withOpacity(0.08) : Colors.grey.shade200;
        return ListView.separated(
          controller: scrollController,
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          cacheExtent: 500,
          padding: const EdgeInsets.all(0),
          itemCount: calls.length,
          separatorBuilder:
              (_, __) => Divider(color: dividerColor),
          itemBuilder: (context, index) {
            final call = calls[index];
            final isMe = call['caller_id'] == _profile!['id'];
            final otherId = isMe ? call['receiver_id'] : call['caller_id'];
            final callType = (call['call_type'] ?? 'audio').toString();
            final status = (call['status'] ?? 'missed').toString();
            final duration = call['duration_seconds'] as int?;
            final startedAt = DateTime.tryParse(
              (call['started_at'] ?? '').toString(),
            );

            final otherUser = _discoverUsers
                .firstWhere(
                  (u) => u['id'] == otherId,
                  orElse: () => const {},
                );
            final displayName =
                (otherUser['display_name'] ?? otherUser['username'] ?? 'Unknown').toString();
            final initial = displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';

            final missed = status == 'missed' && !isMe;
            final titleColor = missed ? Colors.redAccent : (isDark ? Colors.white : Colors.black87);
            final subtitleColor = isDark ? Colors.white60 : Colors.grey.shade600;

            return ListTile(
              leading: CircleAvatar(
                radius: 22,
                backgroundColor: AppColors.violet,
                child: Text(initial,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
              title: Text(displayName,
                  style: GoogleFonts.poppins(color: titleColor, fontWeight: FontWeight.w600)),
              subtitle: Row(
                children: [
                  Icon(
                    isMe ? Icons.call_made_rounded : (missed ? Icons.call_missed_rounded : Icons.call_received_rounded),
                    size: 14,
                    color: missed ? Colors.redAccent : (isMe ? Colors.greenAccent : Colors.tealAccent),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${isMe ? 'Outgoing' : (missed ? 'Missed' : 'Incoming')} · ${_relTime(startedAt?.toIso8601String())}',
                    style: GoogleFonts.poppins(color: subtitleColor, fontSize: 12),
                  ),
                ],
              ),
              trailing: Icon(
                callType == 'video' ? Icons.videocam_rounded : Icons.call_rounded,
                color: AppColors.violet,
              ),
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Open chat with $displayName to call back',
                        style: GoogleFonts.poppins()),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  String _relTime(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  // ───────────────────────────────────────────────────────
  // MISSING METHODS
  // ───────────────────────────────────────────────────────

  void _showCallNotification(String callerName, String callerId) {
    // Fire a local push notification for incoming call
    final navigatorState = NotificationService.navigatorKey.currentState;
    if (navigatorState == null || !navigatorState.mounted) return;
    showDialog(
      context: navigatorState.context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F2027),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            const Icon(Icons.phone_in_talk_rounded, color: Colors.greenAccent, size: 20),
            const SizedBox(width: 8),
            Text('Incoming Call', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text('$callerName is calling you...',
            style: GoogleFonts.poppins(color: Colors.white70, fontSize: 16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Ignore', style: GoogleFonts.poppins(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              // Launch the call screen
              if (_profile != null) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CallScreen(
                      currentUser: _profile!,
                      peerId: callerId,
                      isVideo: false,
                      isOutgoing: false,
                    ),
                  ),
                );
              }
            },
            child: Text('Answer', style: GoogleFonts.poppins(color: Colors.greenAccent)),
          ),
        ],
      ),
    );
  }

  async _confirmAndDeleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F2027),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text('Delete Account?', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Text('This cannot be undone. All your data will be permanently removed.',
            style: GoogleFonts.poppins(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: GoogleFonts.poppins(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: GoogleFonts.poppins(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _supabaseService.deleteAccount(_profile!['id']);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account deleted')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  // ───────────────────────────────────────────────────────
  // RESTORE MISSING METHODS
  // ───────────────────────────────────────────────────────

  void _showVpnBottomSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF0F2027) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => const VpnCard(),
    );
  }

  void _showStarredMessages() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F2027),
        content: Text('Starred messages coming soon',
            style: GoogleFonts.poppins(color: Colors.white70)),
      ),
    );
  }

  void _showBackupRestoreSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F2027),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => _buildBackupRestoreSheet(),
    );
  }

  void _showPrivacySettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F2027),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => _buildPrivacySheet(),
    );
  }

  Widget _buildPrivacySheet() {
    // Stub: implement actual privacy settings
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(999))),
          const SizedBox(height: 20),
          Text('Privacy Settings', style: GoogleFonts.poppins(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Text('Last seen & online', style: GoogleFonts.poppins(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 12),
          Text('Read receipts', style: GoogleFonts.poppins(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 12),
          Text('Hide last seen', style: GoogleFonts.poppins(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildBackupRestoreSheet() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(999))),
          const SizedBox(height: 20),
          Text('Chat Backup & Restore', style: GoogleFonts.poppins(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          _backupRestoreButton('Backup to Google Drive', Icons.backup_rounded, Colors.blueAccent, _doBackup),
          const SizedBox(height: 12),
          _backupRestoreButton('Restore from Google Drive', Icons.restore_rounded, Colors.greenAccent, _doRestore),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  void _showDiscoverBottomSheet() {
    // ... existing code for discover
  }

  void _startChat() {
    final uuid = _uuidController.text.trim();
    if (uuid.isEmpty) return;
    if (_profile == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatRoomScreen(
          otherUser: {'id': uuid},
          currentUser: _profile!,
        ),
      ),
    );
  }

  void _showThreadOptionsSheet(Map<String, dynamic> t) {
    // ... existing code for thread options
  }

  Widget _backupRestoreButton(String label, IconData icon, Color iconColor, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: iconColor, size: 24),
      title: Text(label, style: GoogleFonts.poppins(color: Colors.white, fontSize: 14)),
      onTap: onTap,
    );
  }

  Future<void> _doBackup() async {
    // stub
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup started...')),
      );
    }
  }

  Future<void> _doRestore() async {
    // stub
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Restore started...')),
      );
    }
  }

  // ───────────────────────────────────────────────────────
  // BUILD
  // ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // [UPDATE 2026-06-08-P2] Use theme-aware background color
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = Theme.of(context).scaffoldBackgroundColor;
    final textColor = isDark ? Colors.white : Colors.black87;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Builder(
          builder:
              (context) => IconButton(
                icon: Icon(isDark ? Icons.menu_rounded : Icons.menu_rounded),
                color: isDark ? Colors.white : AppColors.textLight,
                onPressed: () => Scaffold.of(context).openDrawer(),
              ),
        ),
        title: Text(
          'CDN-NETCHAT',
          style: GoogleFonts.sora(
            fontWeight: FontWeight.w800,
            color: isDark ? Colors.white : AppColors.lightAppBarTitle,
          ),
        ),
        flexibleSpace: Container(
          decoration: isDark
              ? const BoxDecoration(gradient: AppColors.accentGradient)
              : null,
          child: isDark
              ? Container(color: Colors.black.withOpacity(0.55))
              : null,
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.search_rounded, color: isDark ? Colors.white : AppColors.lightTabNormal),
            onPressed: _showDiscoverBottomSheet,
          ),
        ],
      ),
      drawer: _buildDrawer(),
      body:
          _isInitializing
              ? _buildLoadingState()
              : (_initError != null
                  ? _buildErrorState()
                  : _buildMainChatView()),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton(
            heroTag: 'group_fab',
            mini: true,
            onPressed: () {
              if (_profile == null) return;
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (context) =>
                          CreateGroupScreen(currentUser: _profile!),
                ),
              ).then((_) {
                _loadGroups();
                _refreshThreads();
              });
            },
            backgroundColor: Colors.teal,
            child: const Icon(
              Icons.group_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(height: 10),
          FloatingActionButton(
            heroTag: 'chat_fab',
            onPressed: _showDiscoverBottomSheet,
            backgroundColor: const Color(0xFF6366F1),
            child: const Icon(Icons.chat_rounded, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildMainChatView() {
    // Filter threads based on search query
    final searchQ = _threadSearchController.text.trim().toLowerCase();
    List<Map<String, dynamic>> filteredThreads = _threads;
    if (searchQ.isNotEmpty) {
      filteredThreads = _threads.where((t) {
        final username = (t['other_username'] ?? '').toString().toLowerCase();
        final displayName = (t['other_display_name'] ?? '').toString().toLowerCase();
        final email = (t['other_email'] ?? '').toString().toLowerCase();
        return username.contains(searchQ) ||
            displayName.contains(searchQ) ||
            email.contains(searchQ);
      }).toList();
    }

    // [UPDATE 2026-06-10] Profile header, UUID input, search bar ALL scroll with content
    return _buildChatHistory(filteredThreads: filteredThreads);
  }

  Widget _buildThreadSearchBar() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fieldBg = isDark ? Colors.white.withOpacity(0.05) : AppColors.lightSearchBg;
    final borderColor = isDark ? Colors.white.withOpacity(0.1) : Colors.transparent;
    final textColor = isDark ? Colors.white : Colors.black87;
    final hintColor = isDark ? Colors.white30 : Colors.grey.shade500;
    final iconColor = isDark ? Colors.white38 : Colors.grey.shade500;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4),
      child: Container(
        decoration: BoxDecoration(
          color: fieldBg,
          borderRadius: BorderRadius.circular(12),
          border: borderColor != Colors.transparent ? Border.all(color: borderColor) : null,
        ),
        child: TextField(
          controller: _threadSearchController,
          style: TextStyle(color: textColor, fontSize: 14),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Search chat by name…',
            hintStyle: TextStyle(color: hintColor, fontSize: 13),
            prefixIcon: Icon(Icons.search_rounded, color: iconColor, size: 20),
            suffixIcon: _threadSearchController.text.isNotEmpty
                ? IconButton(
                    icon: Icon(Icons.clear_rounded, color: isDark ? Colors.white38 : Colors.grey.shade400, size: 18),
                    onPressed: () {
                      _threadSearchController.clear();
                      setState(() {});
                    },
                  )
                : null,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingState() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Initializing…', style: TextStyle(color: isDark ? Colors.white70 : Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: Colors.redAccent,
              size: 48,
            ),
            const SizedBox(height: 12),
            Text(
              'Something went wrong',
              style: GoogleFonts.poppins(
                color: isDark ? Colors.white : Colors.black87,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _initError ?? 'Unknown error',
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(color: isDark ? Colors.white54 : Colors.grey.shade600, fontSize: 12),
            ),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _initApp, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileHeader() {
    if (_profile == null) return const SizedBox.shrink();
    final displayName = _profile?['display_name'] ?? '';
    final username = _profile?['username'] ?? '';
    final name = displayName.isNotEmpty ? displayName : username;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8),
      child: GlassContainer(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: const Color(0xFF6366F1),
              child: Text(
                (name as String).isNotEmpty
                    ? (name as String)[0].toUpperCase()
                    : 'U',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Welcome',
                    style: GoogleFonts.poppins(
                      color: isDark ? Colors.white70 : Colors.grey.shade600,
                      fontSize: 11,
                    ),
                  ),
                  Text(
                    name as String,
                    style: GoogleFonts.poppins(
                      color: isDark ? Colors.white : Colors.black87,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUuidInput() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fieldBg = isDark ? Colors.white.withOpacity(0.05) : AppColors.lightSearchBg;
    final borderColor = isDark ? Colors.white.withOpacity(0.1) : Colors.transparent;
    final textColor = isDark ? Colors.white : Colors.black87;
    final hintColor = isDark ? Colors.white30 : Colors.grey.shade500;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: fieldBg,
                borderRadius: BorderRadius.circular(12),
                border: borderColor != Colors.transparent ? Border.all(color: borderColor) : null,
              ),
              child: TextField(
                controller: _uuidController,
                style: TextStyle(color: textColor),
                decoration: InputDecoration(
                  hintText: 'Enter User UUID to chat',
                  hintStyle: TextStyle(color: hintColor),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Container(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF6366F1), Color(0xFF4F46E5)],
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: IconButton(
              onPressed: _startChat,
              icon: const Icon(Icons.send_rounded, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  // ── WHATSAPP-STYLE CHAT HISTORY ──
  Widget _buildChatHistory({required List<Map<String, dynamic>> filteredThreads}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return CustomScrollView(
      slivers: [
        // Profile header
        SliverToBoxAdapter(child: _buildProfileHeader()),

        // UUID quick-start
        SliverToBoxAdapter(child: _buildUuidInput()),

        // Search bar
        SliverToBoxAdapter(child: _buildThreadSearchBar()),

        // Group section header
        if (_groups.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                'Groups',
                style: GoogleFonts.poppins(
                  color: isDark ? Colors.white38 : Colors.grey.shade500,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),

        // Group list
        if (_groups.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildGroupTile(_groups[index]),
                childCount: _groups.length,
              ),
            ),
          ),

        // Chat threads header
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                Text(
                  'Chats',
                  style: GoogleFonts.poppins(
                    color: isDark ? Colors.white38 : Colors.grey.shade500,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                // Archived button
                GestureDetector(
                  onTap: _navigateToArchived,
                  child: Row(
                    children: [
                      Icon(Icons.archive_rounded,
                        size: 14,
                        color: isDark ? Colors.white38 : Color(0xFF00A884),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Archived',
                        style: GoogleFonts.poppins(
                          color: isDark ? Colors.white38 : Color(0xFF00A884),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // Thread list or empty
        if (filteredThreads.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _buildEmptyState(),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildThreadTile(filteredThreads[index]),
                childCount: filteredThreads.length,
              ),
            ),
          ),
      ],
    );
  }

  void _navigateToArchived() {
    if (_profile == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArchivedChatsScreen(
          currentUser: _profile!,
          supabaseService: _supabaseService,
        ),
      ),
    );
  }

  void _openChatWith(Map<String, dynamic> otherUser) {
    if (_profile == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatRoomScreen(
          otherUser: otherUser,
          currentUser: _profile!,
        ),
      ),
    );
  }

  void _openGroupChat(Map<String, dynamic> group) {
    if (_profile == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GroupChatRoomScreen(
          group: group,
          currentUser: _profile!,
        ),
      ),
    ).then((_) {
      _refreshThreads();
    });
  }

  Widget _buildGroupTile(Map<String, dynamic> group) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final groupName = (group['group_name'] ?? 'Group').toString();
    final lastMessage = (group['last_message'] ?? '').toString();
    final unread = int.tryParse((group['unread_count'] ?? 0).toString()) ?? 0;
    final isSuperAdmin = group['created_by'] == _profile?['id'];
    
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: const Color(0xFF2AABEE),
        child: Text(
          groupName.isNotEmpty ? groupName[0].toUpperCase() : 'G',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      title: Text(
        groupName,
        style: GoogleFonts.poppins(
          color: isDark ? Colors.white : Colors.black87,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        lastMessage,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.poppins(
          color: isDark ? Colors.white60 : Colors.grey.shade500,
          fontSize: 12,
        ),
      ),
      trailing: unread > 0
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.whatsappGreen,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                unread.toString(),
                style: GoogleFonts.poppins(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            )
          : null,
      onTap: () => _openGroupChat(group),
      onLongPress: () => _showGroupOptionsDialog(group, isSuperAdmin),
    );
  }

  void _showGroupOptionsDialog(Map<String, dynamic> group, bool isSuperAdmin) {
    final groupName = (group['group_name'] ?? 'Group').toString();
    final groupId = (group['id'] ?? '').toString();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF0F2027) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        title: Text(
          groupName,
          style: GoogleFonts.poppins(
            color: isDark ? Colors.white : Colors.black87,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                Icons.info_outline_rounded,
                color: isDark ? Colors.white70 : Colors.grey.shade600,
              ),
              title: Text(
                'Group Info',
                style: GoogleFonts.poppins(color: isDark ? Colors.white : Colors.black87),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _openGroupChat(group);
              },
            ),
            if (isSuperAdmin)
              ListTile(
                leading: const Icon(
                  Icons.delete_forever_rounded,
                  color: Colors.redAccent,
                ),
                title: Text(
                  'Delete Group',
                  style: GoogleFonts.poppins(color: Colors.redAccent),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmDeleteGroup(groupId, groupName);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteGroup(String groupId, String groupName) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF0F2027) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        title: Text(
          'Delete Group?',
          style: GoogleFonts.poppins(
            color: isDark ? Colors.white : Colors.black87,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'Are you sure you want to permanently delete "$groupName"? This cannot be undone. All messages and members will be removed.',
          style: GoogleFonts.poppins(color: isDark ? Colors.white70 : Colors.grey.shade600, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: GoogleFonts.poppins(color: isDark ? Colors.white54 : Colors.grey.shade600),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await _supabaseService.deleteGroup(groupId);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Group "$groupName" deleted'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
                _loadGroups();
                _refreshThreads();
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Failed to delete group: $e'),
                      backgroundColor: Colors.redAccent,
                    ),
                  );
                }
              }
            },
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(
              'Delete',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThreadTile(Map<String, dynamic> t) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final username = (t['other_username'] ?? t['username'] ?? '').toString();
    final displayName = (t['other_display_name'] ?? '').toString();
    final lastMessage = (t['last_message'] ?? '').toString();
    final unread = int.tryParse((t['unread_count'] ?? 0).toString()) ?? 0;
    final otherId = (t['other_user_id'] ?? t['other_id'] ?? '').toString();
    final hasStatus = _usersWithActiveStatus.contains(otherId);

    final letter =
        ((displayName.trim().isNotEmpty ? displayName : username).isNotEmpty)
            ? (displayName.trim().isNotEmpty ? displayName : username)[0]
            : '?';

    Widget leadingAvatar;
    if (hasStatus) {
      leadingAvatar = GestureDetector(
        onTap: () {
          // Open status
          if (_profile != null) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => StatusScreen(currentUser: _profile!),
              ),
            );
          }
        },
        child: CircleAvatar(
          radius: 29,
          backgroundColor: const Color(0xFF25D366),
          child: CircleAvatar(
            radius: 26,
            backgroundColor: isDark ? const Color(0xFF0B141A) : Colors.white,
            child: CircleAvatar(
              radius: 23,
              backgroundColor: const Color(0xFF6366F1),
              child: Text(
                letter,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      );
    } else {
      leadingAvatar = CircleAvatar(
        radius: 26,
        backgroundColor: const Color(0xFF6366F1),
        child: Text(letter, style: const TextStyle(color: Colors.white)),
      );
    }

    final user = _supabaseService.currentUser;
    if (user == null) return const SizedBox.shrink();

    // ── WHATSAPP-LIKE: Synchronous meta from preloaded cache ──
    final metaKey = otherId;
    final meta = _threadMetaCache[metaKey];
    if (meta == null && !_threadMetaCache.containsKey(metaKey)) {
      _threadMetaCache[metaKey] = null;
      _localChatStore.getMeta(ownerUserId: user.id, otherId: otherId).then((m) {
        if (mounted) {
          _threadMetaCache[metaKey] = m;
          setState(() {});
        }
      });
    }

    final pinned = meta?.isPinned == true;
    final muted = meta?.isMuted == true;
    final archived = meta?.isArchived == true;
    final markedUnread = meta?.isMarkedUnread == true;

    if (archived) return const SizedBox.shrink();

    final effectiveUnread = (unread > 0) || markedUnread;
    final subtitleColor = isDark
        ? (effectiveUnread ? Colors.white : Colors.white60)
        : (effectiveUnread ? Colors.black87 : Colors.grey.shade500);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: leadingAvatar,
      title: Row(
        children: [
          if (pinned) ...[
            Icon(
              Icons.push_pin_rounded,
              color: Colors.amber.withOpacity(0.9),
              size: 16,
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              displayName.trim().isNotEmpty ? displayName : username,
              style: GoogleFonts.poppins(
                color: isDark ? Colors.white : Colors.black87,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (muted) ...[
            const SizedBox(width: 6),
            Icon(
              Icons.notifications_off_rounded,
              color: isDark ? Colors.white38 : Colors.grey.shade400,
              size: 16,
            ),
          ],
        ],
      ),
      subtitle: Text(
        lastMessage,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.poppins(
          color: subtitleColor,
          fontSize: 12,
          fontWeight: effectiveUnread ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      trailing: effectiveUnread
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.whatsappGreen,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                unread > 0 ? unread.toString() : '●',
                style: GoogleFonts.poppins(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            )
          : Icon(
              Icons.chevron_right_rounded,
              color: isDark ? Colors.white38 : Colors.grey.shade300,
            ),
      onTap: () {
        final otherUser = {
          'id': t['other_user_id'] ?? t['other_id'],
          'username': t['other_username'] ?? t['username'],
          'display_name': t['other_display_name'],
          'email': t['other_email'] ?? t['email'],
        };
        _openChatWith(otherUser);
      },
      onLongPress: () => _showThreadOptionsSheet(t),
    );
  }

  Widget _buildEmptyState() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final iconColor = isDark ? Colors.white.withOpacity(0.1) : Colors.grey.shade200;
    final txtColor = isDark ? Colors.white24 : Colors.grey.shade400;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline_rounded,
            color: iconColor,
            size: 100,
          ),
          const SizedBox(height: 20),
          Text(
            'No chat history yet\nStart a chat by UUID or Discover',
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(color: txtColor, fontSize: 16),
          ),
        ],
      ),
    );
  }
}