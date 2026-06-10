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
    debounceDelay: const Duration(milliseconds: 200),
  );
  final _searchDebouncer = Debouncer(delay: const Duration(milliseconds: 250));
  final _threadRefreshThrottler = Throttler(interval: const Duration(seconds: 2));

  // [UPDATE 2026-06-08-LAGFIX] Connectivity tracking for offline handling
  bool _isOnline = true;

  @override
  void initState() {
    super.initState();
    _initApp();
    _loadSavedContacts();
    _startIncomingMessageNotifications();
    _listenForIncomingCalls();

    _lastSeenTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      final user = _supabaseService.currentUser;
      if (user != null) {
        _supabaseService.updateLastSeen(user.id);
      }
    });

    // [UPDATE 2026-06-08-LAGFIX] Monitor connectivity for offline handling
    Connectivity().onConnectivityChanged.listen((results) {
      final online = !results.any((r) => r == ConnectivityResult.none);
      if (online != _isOnline && mounted) {
        _isOnline = online;
        setState(() {});
        if (online) {
          // When back online, refresh data
          _refreshThreads();
          OfflineMessageQueue.instance.flush();
        }
      }
    });
    OfflineMessageQueue.instance.startListening();
  }

  @override
  void dispose() {
    _lastSeenTimer?.cancel();
    _incomingSub?.cancel();
    _threadRefreshSub?.cancel();
    _callSignalSub?.cancel();
    _uuidController.dispose();
    _discoverSearchController.dispose();
    _threadSearchController.dispose();
    // [UPDATE 2026-06-08-LAGFIX] Dispose throttlers
    _setStateThrottler.dispose();
    _searchDebouncer.dispose();
    _threadRefreshThrottler.dispose();
    super.dispose();
  }

  void _listenForIncomingCalls() {
    final user = _supabaseService.currentUser;
    if (user == null) return;

    _callSignalSub = _supabaseService.streamCallSignals(user.id).listen((
      signals,
    ) {
      if (!mounted || _isInChatRoom) return;
      for (final s in signals) {
        final sigId = (s['id'] ?? '').toString();
        if (_seenCallSignalIds.contains(sigId)) continue;
        _seenCallSignalIds.add(sigId);

        final type = (s['type'] ?? '').toString();
        if (type == 'call_offer') {
          final payload = s['payload'] as Map<String, dynamic>?;
          final isVideo = payload?['is_video'] == true;
          final fromId = (s['from_id'] ?? '').toString();

          NotificationService.showIncomingCallNotification(
            title: isVideo ? 'Incoming Video Call' : 'Incoming Call',
            body: 'Someone is calling you on CDN-NETCHAT',
            payload: NotificationService.buildPayload(type: 'call', id: fromId),
          );
        }
      }
    });
  }

  Future<void> _initApp() async {
    setState(() {
      _isInitializing = true;
      _initError = null;
    });

    try {
      final user = _supabaseService.currentUser;

      if (user == null) {
        setState(() {
          _isInitializing = false;
          _initError = 'No active session. Please sign in again.';
        });
        return;
      }

      final profile = await _supabaseService.getProfile(user.id);
      final access = await _supabaseService.checkAccessStatus(user.id);

      if (profile != null && profile['is_blocked'] == true) {
        await _supabaseService.signOut();
        if (mounted) {
          final reason =
              (profile['blocked_reason'] ??
                      'Your account has been blocked by admin.')
                  .toString();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(reason),
              backgroundColor: Colors.redAccent,
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      final usernameFromMeta =
          (user.userMetadata?['username'] ?? '').toString();
      final displayNameFromMeta =
          (user.userMetadata?['display_name'] ?? '').toString();
      final fallbackProfile = {
        'id': user.id,
        'email': user.email,
        'username':
            usernameFromMeta.isNotEmpty
                ? usernameFromMeta
                : user.id.substring(0, 8).toUpperCase(),
        'display_name': displayNameFromMeta,
      };

      final hasAccess = access['hasAccess'] == true;

      setState(() {
        _profile = profile ?? fallbackProfile;
        _hasAccess = hasAccess;
      });

      await VpnManager.instance.refreshVpnAccess();
      if (!hasAccess) {
        try {
          await VpnManager.instance.stop();
        } catch (_) {}
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Access expired. Subscribe to continue using the app.',
              ),
            ),
          );
        }
      }

      _supabaseService.updateLastSeen(user.id);

      await Future.wait([
        _refreshThreads(),
        _loadDiscoverUsers(),
        _loadGroups(),
        _loadActiveStatusUsers(),
      ]);

      _startThreadRefreshListener();

      // Init business data
      await _initBusinessData();

      setState(() => _isInitializing = false);

      _handlePendingNotificationNavigation();
    } catch (e) {
      setState(() {
        _isInitializing = false;
        _initError = e.toString();
      });
    }
  }

  void _handlePendingNotificationNavigation() {
    final pending = getAndClearPendingNavigation();
    if (pending == null) return;

    final type = pending['type'] ?? '';
    final id = pending['id'] ?? '';

    if (type == 'chat' && id.isNotEmpty && _profile != null) {
      final otherUser = _discoverUsers.cast<Map<String, dynamic>?>().firstWhere(
        (p) => p != null && p['id']?.toString() == id,
        orElse: () => null,
      );
      if (otherUser != null) {
        _openChatWith(otherUser);
      } else {
        _supabaseService.getProfile(id).then((profile) {
          if (profile != null && mounted) {
            _openChatWith(profile);
          }
        });
      }
    } else if (type == 'group' && id.isNotEmpty && _profile != null) {
      final group = _groups.cast<Map<String, dynamic>?>().firstWhere(
        (g) => g != null && (g['id']?.toString() == id),
        orElse: () => null,
      );
      if (group != null) {
        _openGroupChat(group);
      }
    }
  }

  Future<void> _loadActiveStatusUsers() async {
    try {
      final user = _supabaseService.currentUser;
      if (user == null) return;
      final allStatus = await _supabaseService.getActiveStatus(
        currentUserId: user.id,
      );
      final activeUserIds = <String>{};
      for (final s in allStatus) {
        final userId = (s['user_id'] ?? '').toString();
        if (userId != user.id) {
          activeUserIds.add(userId);
        }
      }
      if (mounted) {
        setState(() => _usersWithActiveStatus = activeUserIds);
      }
    } catch (_) {}
  }

  Future<void> _initBusinessData() async {
    try {
      if (_profile == null) return;
      final userId = _profile!['id'] as String;
      final tier = await _cdnBusiness.getUserTier(userId);
      final balance = await _cdnBusiness.getUserBalance(userId);
      if (mounted) {
        setState(() {
          _userTier = tier;
          _walletBalance = balance;
        });
      }
    } catch (_) {}
  }

  void _startThreadRefreshListener() {
    final user = _supabaseService.currentUser;
    if (user == null) return;

    _threadRefreshSub?.cancel();
    _threadRefreshSub = _supabaseService.streamIncomingMessages(user.id).listen(
      (msgs) {
        if (mounted && !_isInChatRoom) {
          _refreshThreads();
        }
      },
    );
  }

  void _startIncomingMessageNotifications() {
    final user = _supabaseService.currentUser;
    if (user == null) return;

    _incomingSub?.cancel();
    _incomingSub = _supabaseService.streamIncomingMessages(user.id).listen((
      msgs,
    ) async {
      if (!mounted) return;
      if (msgs.isEmpty) return;

      final last = msgs.last;
      final id = int.tryParse((last['id'] ?? 0).toString()) ?? 0;
      if (id <= _lastIncomingMessageId) return;

      _lastIncomingMessageId = id;

      final isUnread = (last['is_read'] == false);
      if (!isUnread || _isInChatRoom) return;

      _refreshThreads();

      final senderId = (last['sender_id'] ?? '').toString();

      try {
        final muted = await _localChatStore.isMutedActive(
          ownerUserId: user.id,
          otherId: senderId,
        );
        if (muted) return;
      } catch (_) {}
      final type = (last['message_type'] ?? 'text').toString();
      final body = switch (type) {
        'image' => '[Image]',
        'audio' => '[Voice note]',
        'video' => '[Video]',
        'file' => '[File]',
        'emoji' => (last['content'] ?? '').toString(),
        _ => (last['content'] ?? '').toString(),
      };

      final senderProfile = _discoverUsers
          .cast<Map<String, dynamic>?>()
          .firstWhere(
            (p) => p != null && (p['id']?.toString() == senderId),
            orElse: () => null,
          );

      final senderName =
          (senderProfile == null)
              ? 'New message'
              : (((senderProfile['display_name'] ?? '') as String)
                      .trim()
                      .isNotEmpty
                  ? senderProfile['display_name']
                  : senderProfile['username']);

      NotificationService.showIncomingMessageNotification(
        title: senderName.toString(),
        body: body.isEmpty ? 'New message' : body,
        payload: NotificationService.buildPayload(type: 'chat', id: senderId),
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$senderName: $body'),
          duration: const Duration(seconds: 4),
          action:
              (senderProfile == null)
                  ? null
                  : SnackBarAction(
                    label: 'Open',
                    onPressed: () {
                      _openChatWith(senderProfile);
                    },
                  ),
        ),
      );
    });
  }

  Future<void> _refreshThreads() async {
    try {
      if (mounted) setState(() => _threadsLoading = true);
      final data = await _supabaseService.getChatThreads();
      if (!mounted) return;

      // ── WHATSAPP-LIKE: Pre-cache all thread meta eagerly ──
      _preloadThreadMetaCache(data);
      _threadMetaCacheLoaded = true;

      setState(() => _threads = data);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _threadsLoading = false);
    }
  }

  // ── WHATSAPP-LIKE: Load all thread metadata in batch ──
  // This eliminates the per-tile async getMeta call during scrolling
  void _preloadThreadMetaCache(List<Map<String, dynamic>> threads) {
    final user = _supabaseService.currentUser;
    if (user == null) return;
    for (final t in threads) {
      final otherId = (t['other_user_id'] ?? t['other_id'] ?? '').toString();
      if (otherId.isEmpty) continue;
      // Kick off async load — doesn't block UI
      _localChatStore.getMeta(ownerUserId: user.id, otherId: otherId).then((meta) {
        _threadMetaCache[otherId] = meta;
      });
    }
  }

  Future<void> _loadGroups() async {
    try {
      if (mounted) setState(() => _groupsLoading = true);
      final data = await _supabaseService.getMyGroups();
      if (!mounted) return;
      setState(() => _groups = data);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _groupsLoading = false);
    }
  }

  // [UPDATE 2026-06-08-P2] Load discover users — Pro users see all, free users see saved contacts only
  Future<void> _loadDiscoverUsers() async {
    try {
      if (mounted) setState(() => _discoverLoading = true);
      final user = _supabaseService.currentUser;
      if (user == null) return;

      final profile = await _supabaseService.getProfile(user.id);
      final tier = (profile?['tier'] ?? 'free').toString().toLowerCase();
      final isSubscribed = profile?['is_subscribed'] == true;
      final expiryRaw = profile?['subscription_expiry'];
      final DateTime? expiry = expiryRaw == null ? null : DateTime.tryParse(expiryRaw.toString());
      final subscriptionValid = isSubscribed && (expiry == null ? false : DateTime.now().isBefore(expiry));
      final isPro = (tier == 'pro' || tier == 'basic_premium') && subscriptionValid;

      List<Map<String, dynamic>> data;
      if (isPro) {
        data = await _supabaseService.discoverUsers(limit: 100);
      } else {
        data = [];
      }

      if (!mounted) return;
      setState(() {
        _discoverUsers =
            data.where((p) => p['id'] != user.id).toList();
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _discoverLoading = false);
    }
  }

  Future<void> _openChatWith(Map<String, dynamic> otherUser) async {
    await _saveContactFromProfile(otherUser);

    if (_profile == null) return;

    if (!_hasAccess) {
      _showSubscriptionDialog();
      return;
    }

    _isInChatRoom = true;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) =>
                ChatRoomScreen(otherUser: otherUser, currentUser: _profile!),
      ),
    ).then((_) {
      _isInChatRoom = false;
      _refreshThreads();
      _loadDiscoverUsers();
    });
  }

  void _openGroupChat(Map<String, dynamic> group) {
    if (_profile == null) return;

    _isInChatRoom = true;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) =>
                GroupChatRoomScreen(group: group, currentUser: _profile!),
      ),
    ).then((_) {
      _isInChatRoom = false;
      _loadGroups();
      _refreshThreads();
    });
  }

  void _showThreadOptionsSheet(Map<String, dynamic> thread) {
    final user = _supabaseService.currentUser;
    if (user == null) return;
    final otherId =
        (thread['other_user_id'] ?? thread['other_id'] ?? '').toString();
    final otherName =
        (thread['other_display_name'] ??
                thread['other_username'] ??
                'this user')
            .toString();
    if (otherId.isEmpty) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        return FutureBuilder(
          future: _localChatStore.getMeta(
            ownerUserId: user.id,
            otherId: otherId,
          ),
          builder: (context, snap) {
            final meta = snap.data;
            final isPinned = meta?.isPinned == true;
            final isMuted = meta?.isMuted == true;
            final isArchived = meta?.isArchived == true;
            final isMarkedUnread = meta?.isMarkedUnread == true;

            Widget tile({
              required IconData icon,
              required String text,
              required VoidCallback onTap,
              Color? color,
            }) {
              return ListTile(
                leading: Icon(icon, color: color ?? Colors.white70),
                title: Text(
                  text,
                  style: GoogleFonts.poppins(
                    color: color ?? Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  onTap();
                },
              );
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
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
                    const SizedBox(height: 10),
                    Text(
                      otherName,
                      style: GoogleFonts.poppins(
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    tile(
                      icon:
                          isPinned
                              ? Icons.push_pin_rounded
                              : Icons.push_pin_outlined,
                      text: isPinned ? 'Unpin chat' : 'Pin chat',
                      onTap: () async {
                        await _localChatStore.togglePinned(
                          ownerUserId: user.id,
                          otherId: otherId,
                        );
                        if (mounted) setState(() {});
                      },
                    ),
                    tile(
                      icon:
                          isMuted
                              ? Icons.notifications_off_rounded
                              : Icons.notifications_active_rounded,
                      text: isMuted ? 'Unmute' : 'Mute',
                      onTap: () async {
                        if (isMuted) {
                          await _localChatStore.setMute(
                            ownerUserId: user.id,
                            otherId: otherId,
                            muteFor: Duration.zero,
                          );
                        } else {
                          await _localChatStore.setMute(
                            ownerUserId: user.id,
                            otherId: otherId,
                            muteFor: const Duration(hours: 8),
                          );
                        }
                        if (mounted) setState(() {});
                      },
                    ),
                    tile(
                      icon:
                          isArchived
                              ? Icons.unarchive_rounded
                              : Icons.archive_rounded,
                      text: isArchived ? 'Unarchive' : 'Archive',
                      onTap: () async {
                        await _localChatStore.toggleArchived(
                          ownerUserId: user.id,
                          otherId: otherId,
                        );
                        if (mounted) setState(() {});
                      },
                    ),
                    tile(
                      icon:
                          isMarkedUnread
                              ? Icons.mark_email_read_rounded
                              : Icons.mark_email_unread_rounded,
                      text: isMarkedUnread ? 'Mark as read' : 'Mark as unread',
                      onTap: () async {
                        await _localChatStore.toggleMarkedUnread(
                          ownerUserId: user.id,
                          otherId: otherId,
                        );
                        if (mounted) setState(() {});
                      },
                    ),
                    tile(
                      icon: Icons.wallpaper_rounded,
                      text: 'Wallpaper',
                      onTap: () {
                        final otherUser = {
                          'id': thread['other_user_id'] ?? thread['other_id'],
                          'username':
                              thread['other_username'] ?? thread['username'],
                          'display_name': thread['other_display_name'],
                          'email': thread['other_email'] ?? thread['email'],
                        };
                        _openChatWith(otherUser);
                      },
                    ),
                    const Divider(color: Colors.white12),
                    tile(
                      icon: Icons.delete_forever_rounded,
                      text: 'Delete chat',
                      color: Colors.redAccent,
                      onTap: () => _showDeleteChatDialog(thread),
                    ),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showDeleteChatDialog(Map<String, dynamic> thread) {
    final otherName =
        (thread['other_display_name'] ??
                thread['other_username'] ??
                'this user')
            .toString();

    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF0F2027),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            title: Text(
              'Delete Chat?',
              style: GoogleFonts.poppins(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: Text(
              'Are you sure you want to delete your chat with $otherName? This will remove the conversation from your chat list.',
              style: GoogleFonts.poppins(color: Colors.white70, fontSize: 14),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  'Cancel',
                  style: GoogleFonts.poppins(color: Colors.white54),
                ),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  final otherId =
                      (thread['other_user_id'] ?? thread['other_id'] ?? '')
                          .toString();
                  if (otherId.isEmpty) return;

                  try {
                    await _supabaseService.deleteChatThread(otherId);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Chat with $otherName deleted'),
                          backgroundColor: Colors.green,
                        ),
                      );
                    }
                    _refreshThreads();
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Failed to delete chat: $e'),
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

  /// [UPDATE 2026-06-08-P3] Discover + Saved Contacts
  ///
  /// - PRO users (30000 Pro tier): see full discovery list with "Save Contact" button
  /// - Basic/Free users: see their saved contacts + ability to add by UUID
  /// - ALL users can save contacts (auto-saved when opening a chat)
  void _showDiscoverBottomSheet() {
    _discoverSearchController.text = '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F2027),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (context) {
        // Determine current user's tier for PRO checks
        final isProUser = _userTier == UserTier.pro || _userTier == UserTier.basicPremium;

        return StatefulBuilder(
          builder: (context, setModalState) {
            final q = _discoverSearchController.text.trim().toUpperCase();

            // For PRO: search across discover users
            // For free: search across saved contacts
            final filtered = isProUser
                ? _discoverUsers.where((u) {
                    final username =
                        (u['username'] ?? '').toString().toUpperCase();
                    final email =
                        (u['email'] ?? '').toString().toUpperCase();
                    final name =
                        (u['display_name'] ?? '').toString().toUpperCase();
                    return q.isEmpty ||
                        username.contains(q) ||
                        email.contains(q) ||
                        name.contains(q);
                  }).toList()
                : _savedContacts
                    .where((c) {
                      final uuid = c.uuid.toUpperCase();
                      final displayName = c.displayName.toUpperCase();
                      final username = c.username.toUpperCase();
                      return q.isEmpty ||
                          uuid.contains(q) ||
                          displayName.contains(q) ||
                          username.contains(q);
                    })
                    .toList();

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 16,
                  bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40, height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            isProUser ? 'Discover Users' : 'My Contacts',
                            style: GoogleFonts.poppins(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        if (isProUser)
                          Text(
                            _userTier == UserTier.pro ? '30000 PRO' : 'BASIC',
                            style: GoogleFonts.poppins(
                              color: const Color(0xFF25D366),
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded, color: Colors.white70),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _discoverSearchController,
                      style: const TextStyle(color: Colors.white),
                      onChanged: (_) => setModalState(() {}),
                      decoration: InputDecoration(
                        hintText: isProUser
                            ? 'Search by UUID or email…'
                            : 'Search saved contacts by name or UUID…',
                        hintStyle: const TextStyle(color: Colors.white30),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.06),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: Colors.white.withOpacity(0.12)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: Colors.white.withOpacity(0.12)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: Color(0xFF6366F1)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_discoverLoading)
                      const Padding(
                        padding: EdgeInsets.all(16.0),
                        child: CircularProgressIndicator(),
                      )
                    else if (filtered.isEmpty && !isProUser)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 6),
                        child: Column(
                          children: [
                            const Icon(Icons.contacts_rounded, color: Colors.white54, size: 36),
                            const SizedBox(height: 10),
                            Text(
                              'No saved contacts yet',
                              style: GoogleFonts.poppins(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Chat with someone by UUID from the main screen\n'
                              'and they will be saved to your contacts',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.poppins(
                                color: Colors.white60,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ),
                      )
                    else if (filtered.isEmpty && isProUser)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 6),
                        child: Column(
                          children: [
                            const Icon(Icons.search_off_rounded, color: Colors.white54, size: 36),
                            const SizedBox(height: 10),
                            Text(
                              'No users found matching "$q"',
                              style: GoogleFonts.poppins(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: filtered.length,
                          separatorBuilder:
                              (_, __) => Divider(color: Colors.white.withOpacity(0.08)),
                          itemBuilder: (context, i) {
                            String userId;
                            String username;
                            String displayName;
                            String email;
                            bool hasStatus;

                            if (isProUser) {
                              final u = filtered[i] as Map<String, dynamic>;
                              userId = (u['id'] ?? '').toString();
                              username = (u['username'] ?? '').toString();
                              displayName = ((u['display_name'] ?? '') as String).trim();
                              email = (u['email'] ?? '').toString();
                              hasStatus = _usersWithActiveStatus.contains(userId);
                            } else {
                              final c = filtered[i] as SavedContact;
                              userId = c.userId;
                              username = c.uuid;
                              displayName = c.displayName;
                              email = c.username;
                              hasStatus = _usersWithActiveStatus.contains(userId);
                            }

                            final letter =
                                (displayName.isNotEmpty ? displayName : username)[0].toUpperCase();

                            // Check if already saved
                            final isSaved = _savedContacts.any((sc) => sc.userId == userId);

                            return ListTile(
                              dense: true,
                              leading: hasStatus
                                  ? CircleAvatar(
                                      radius: 20,
                                      backgroundColor: const Color(0xFF25D366),
                                      child: CircleAvatar(
                                        radius: 17,
                                        backgroundColor: const Color(0xFF0B141A),
                                        child: CircleAvatar(
                                          radius: 14,
                                          backgroundColor: const Color(0xFF6366F1),
                                          child: Text(
                                            letter,
                                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                      ),
                                    )
                                  : CircleAvatar(
                                      backgroundColor: const Color(0xFF6366F1),
                                      child: Text(
                                        letter,
                                        style: const TextStyle(color: Colors.white, fontSize: 14),
                                      ),
                                    ),
                              title: Text(
                                displayName.isNotEmpty ? displayName : username,
                                style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w600),
                              ),
                              subtitle: Text(
                                isProUser ? email : 'UUID: $username',
                                style: GoogleFonts.poppins(color: Colors.white60, fontSize: 12),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (isProUser)
                                    IconButton(
                                      icon: Icon(
                                        isSaved ? Icons.person_remove_rounded : Icons.person_add_rounded,
                                        color: isSaved ? Colors.orangeAccent : const Color(0xFF6366F1),
                                        size: 20,
                                      ),
                                      tooltip: isSaved ? 'Remove contact' : 'Save contact',
                                      onPressed: () async {
                                        if (isSaved) {
                                          await _savedContactsStore.remove(userId);
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(content: Text('$displayName removed from contacts'), backgroundColor: Colors.orange),
                                          );
                                        } else {
                                          await _savedContactsStore.upsertFromProfile({
                                            'id': userId,
                                            'username': username,
                                            'display_name': displayName,
                                            'email': email,
                                          } as Map<String, dynamic>);
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(content: Text('$displayName saved to contacts'), backgroundColor: Colors.green),
                                          );
                                        }
                                        _loadSavedContacts();
                                        setModalState(() {});
                                      },
                                    ),
                                  const SizedBox(width: 4),
                                  const Icon(Icons.chat_bubble_rounded, color: Color(0xFF6366F1), size: 20),
                                ],
                              ),
                              onTap: () async {
                                Navigator.pop(context);
                                final userMap = isProUser
                                    ? filtered[i] as Map<String, dynamic>
                                    : {
                                        'id': userId,
                                        'username': username,
                                        'display_name': displayName,
                                        'email': email,
                                      } as Map<String, dynamic>;
                                await _saveContactFromProfile(userMap);
                                _openChatWith(userMap);
                              },
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _loadSavedContacts() async {
    try {
      final list = await _savedContactsStore.list();
      if (mounted) setState(() => _savedContacts = list);
    } catch (_) {}
  }

  Future<void> _saveContactFromProfile(Map<String, dynamic> profile) async {
    try {
      await _savedContactsStore.upsertFromProfile(profile);
      await _loadSavedContacts();
    } catch (_) {}
  }

  void _startChat() async {
    final chatUuid = _uuidController.text.trim().toUpperCase();
    if (chatUuid.isEmpty) return;

    if (_profile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Still loading your profile. Please try again.'),
        ),
      );
      return;
    }

    if (!_hasAccess) {
      _showSubscriptionDialog();
      return;
    }

    final targetProfile = await _supabaseService.getProfileByChatUuid(chatUuid);
    if (targetProfile != null) {
      await _saveContactFromProfile(targetProfile);
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder:
                (context) => ChatRoomScreen(
                  otherUser: targetProfile,
                  currentUser: _profile!,
                ),
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('User UUID not found')));
      }
    }
  }

  void _showSubscriptionDialog() {
    if (!mounted) return;
    if (_profile == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SubscriptionScreen(currentUser: _profile!),
      ),
    );
  }

  Future<void> _shareChatBackup() async {
    try {
      if (_profile == null) return;
      final userId = _profile!['id'] as String;

      final threads = await _supabaseService.getChatThreads();
      final allMessages = <Map<String, dynamic>>[];
      final contacts = <Map<String, dynamic>>[];

      for (final t in threads) {
        final otherId = (t['other_user_id'] ?? t['other_id'] ?? '').toString();
        if (otherId.isEmpty) continue;

        contacts.add({
          'id': otherId,
          'username': t['other_username'] ?? t['username'] ?? '',
          'display_name': t['other_display_name'] ?? '',
          'email': t['other_email'] ?? t['email'] ?? '',
        });

        final convo = await _supabaseService.fetchConversationOnce(
          userId,
          otherId,
        );
        allMessages.addAll(convo);
      }

      final archive = Archive();
      final jsonBytes = utf8.encode(
        jsonEncode({
          'version': '3.1.0',
          'exported_at': DateTime.now().toUtc().toIso8601String(),
          'user_id': userId,
          'contacts': contacts,
          'messages': allMessages,
        }),
      );
      archive.addFile(
        ArchiveFile('messages.json', jsonBytes.length, jsonBytes),
      );

      try {
        final docs = await getApplicationDocumentsDirectory();
        final cacheDir = Directory(p.join(docs.path, 'chat_media_cache'));
        if (await cacheDir.exists()) {
          await for (final ent in cacheDir.list(
            recursive: true,
            followLinks: false,
          )) {
            if (ent is! File) continue;
            final rel = p.relative(ent.path, from: cacheDir.path);
            final bytes = await ent.readAsBytes();
            archive.addFile(
              ArchiveFile(p.join('media', rel), bytes.length, bytes),
            );
          }
        }
      } catch (_) {}

      final zipData = ZipEncoder().encode(archive);
      if (zipData == null) throw Exception('Failed to create backup ZIP');

      final dir = await getTemporaryDirectory();
      final filePath = p.join(
        dir.path,
        'cdn-netchat-backup-${DateTime.now().millisecondsSinceEpoch}.zip',
      );
      await File(filePath).writeAsBytes(zipData);

      await SharePlus.instance.share(
        ShareParams(files: [XFile(filePath)], text: 'CDN-NETCHAT Chat Backup'),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Backup failed: ${e.toString()}')),
        );
      }
    }
  }

  Future<void> _exportAllChatsAsTxt() async {
    try {
      if (_profile == null) return;
      final userId = _profile!['id'] as String;
      final myName =
          (_profile!['display_name'] ?? _profile!['username'] ?? 'Me')
              ?.toString() ??
          'Me';

      final threads = await _supabaseService.getChatThreads();
      final buffer = StringBuffer();

      buffer.writeln('CDN-NETCHAT Full Chat Export');
      buffer.writeln('Exported: ${DateTime.now().toLocal()}');
      buffer.writeln('User: $myName');
      buffer.writeln('${'=' * 60}');
      buffer.writeln();

      for (final t in threads) {
        final otherId = (t['other_user_id'] ?? t['other_id'] ?? '').toString();
        if (otherId.isEmpty) continue;

        final otherName =
            (t['other_display_name'] ?? t['other_username'] ?? 'User')
                .toString();

        buffer.writeln('--- Chat with $otherName ---');
        buffer.writeln();

        final messages = await _supabaseService.fetchConversationOnce(
          userId,
          otherId,
        );
        for (final msg in messages) {
          final isMe = msg['sender_id'] == userId;
          final deletedForMe =
              isMe
                  ? (msg['deleted_for_sender'] == true)
                  : (msg['deleted_for_receiver'] == true);
          if (deletedForMe && (msg['message_type'] ?? '') != 'deleted')
            continue;

          final senderName = isMe ? myName : otherName;
          final time = DateTime.tryParse((msg['created_at'] ?? '').toString());
          final timeStr =
              time != null
                  ? '${time.day}/${time.month}/${time.year} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}'
                  : '';
          final type = (msg['message_type'] ?? 'text').toString();

          if (type == 'deleted') {
            buffer.writeln('[$timeStr] $senderName: [Message deleted]');
          } else if (type == 'image') {
            buffer.writeln('[$timeStr] $senderName: [Image]');
          } else if (type == 'audio') {
            buffer.writeln('[$timeStr] $senderName: [Voice note]');
          } else if (type == 'file') {
            buffer.writeln(
              '[$timeStr] $senderName: [File: ${msg['media_name'] ?? 'File'}]',
            );
          } else {
            buffer.writeln('[$timeStr] $senderName: ${msg['content'] ?? ''}');
          }
        }

        buffer.writeln();
        buffer.writeln('${'-' * 40}');
        buffer.writeln();
      }

      buffer.writeln('${'=' * 60}');
      buffer.writeln('End of export');

      final dir = await getTemporaryDirectory();
      final filePath = p.join(
        dir.path,
        'cdn-netchat-export-${DateTime.now().millisecondsSinceEpoch}.txt',
      );
      await File(filePath).writeAsString(buffer.toString());

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(filePath)],
          text: 'CDN-NETCHAT Chat Export (TXT)',
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: ${e.toString()}')),
        );
      }
    }
  }

  Future<void> _restoreChatFromBackup() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowedExtensions: ['json', 'zip'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) {
        return;
      }

      final filePath = result.files.single.path;
      if (filePath == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not access the selected file'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
                SizedBox(width: 12),
                Text('Restoring backup...'),
              ],
            ),
            duration: Duration(seconds: 30),
            backgroundColor: Color(0xFF6366F1),
          ),
        );
      }

      final userId = _profile?['id'] as String?;
      if (userId == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please sign in to restore backup'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
        return;
      }

      List<dynamic> messages = [];
      List<dynamic> contacts = [];

      if (filePath.endsWith('.zip')) {
        final bytes = await File(filePath).readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);

        try {
          final msgFile = archive.files.firstWhere(
            (f) => f.isFile && f.name == 'messages.json',
          );
          final raw = utf8.decode(msgFile.content as List<int>);
          final decoded = jsonDecode(raw) as Map<String, dynamic>;
          messages = (decoded['messages'] as List?) ?? [];
          contacts = (decoded['contacts'] as List?) ?? [];

          final docs = await getApplicationDocumentsDirectory();
          final cacheDir = Directory(p.join(docs.path, 'chat_media_cache'));
          if (!await cacheDir.exists()) await cacheDir.create(recursive: true);

          for (final file in archive.files) {
            if (!file.isFile || !file.name.startsWith('media/')) continue;
            final rel = file.name.substring('media/'.length);
            final target = File(p.join(cacheDir.path, rel));
            await target.parent.create(recursive: true);
            await target.writeAsBytes(file.content as List<int>, flush: true);
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).clearSnackBars();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Invalid backup ZIP: ${e.toString()}'),
                backgroundColor: Colors.redAccent,
              ),
            );
          }
          return;
        }
      } else {
        final backup =
            jsonDecode(await File(filePath).readAsString())
                as Map<String, dynamic>;
        messages = (backup['messages'] as List?) ?? [];
        contacts = (backup['contacts'] as List?) ?? [];
      }

      if (messages.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No messages found in backup'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      final store = LocalChatStore(supabaseService: _supabaseService);
      await store.restoreFromBackup(ownerUserId: userId, messages: messages);

      await _refreshThreads();
      await _loadDiscoverUsers();

      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '✅ Restored ${messages.length} messages and ${contacts.length} contacts',
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Restore failed: ${e.toString()}'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  // ─── WHATSAPP-STYLE DRAWER ───
  Widget _buildDrawer() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final displayName = _profile?['display_name'] ?? '';
    final username = _profile?['username'] ?? '';
    final email = _profile?['email'] ?? '';

    return Drawer(
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF111B21)
          : AppColors.lightSurface,
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
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
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
                .cast<Map<String, dynamic>?>()
                .firstWhere(
                  (p) =>
                      p != null && p['id']?.toString() == otherId.toString(),
                  orElse: () => null,
                );
            final name =
                otherUser != null
                    ? ((otherUser['display_name'] ?? '')
                            .toString()
                            .trim()
                            .isNotEmpty
                        ? otherUser['display_name']
                        : otherUser['username'] ?? 'Unknown')
                    : 'Unknown';

            final titleColor = status == 'missed' ? Colors.redAccent : (isDark ? Colors.white : Colors.black87);
            final subtitleColor = isDark ? Colors.white54 : Colors.grey.shade600;

            return ListTile(
              leading: CircleAvatar(
                backgroundColor:
                    status == 'missed'
                        ? Colors.redAccent.withOpacity(0.3)
                        : const Color(0xFF6366F1),
                child: Icon(
                  callType == 'video'
                      ? Icons.videocam_rounded
                      : Icons.call_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              title: Text(
                name.toString(),
                style: GoogleFonts.poppins(
                  color: titleColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                '${isMe ? 'Outgoing' : 'Incoming'} ${callType == 'video' ? 'video' : 'audio'} call'
                '${duration != null && status == 'completed' ? ' • ${duration}s' : ''}'
                '${status == 'missed' ? ' • Missed' : ''}',
                style: GoogleFonts.poppins(color: subtitleColor, fontSize: 12),
              ),
              trailing:
                  startedAt != null
                      ? Text(
                        '${startedAt.hour.toString().padLeft(2, '0')}:${startedAt.minute.toString().padLeft(2, '0')}',
                        style: GoogleFonts.poppins(
                          color: isDark ? Colors.white38 : Colors.grey.shade500,
                          fontSize: 12,
                        ),
                      )
                      : null,
            );
          },
        );
      },
    );
  }

  Future<void> _confirmAndDeleteAccount() async {
    if (_profile == null) return;

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF0F2027),
            title: Text(
              'Delete Account?',
              style: GoogleFonts.poppins(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            content: Text(
              'This will permanently delete your account and log you out.\n\nThis cannot be undone.',
              style: GoogleFonts.poppins(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(
                  'Cancel',
                  style: GoogleFonts.poppins(color: Colors.white70),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(
                  'Delete',
                  style: GoogleFonts.poppins(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
    );

    if (ok != true) return;

    try {
      try {
        VpnManager.instance.stopByUser();
      } catch (_) {}

      await _supabaseService.deleteMyAccount();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Account deleted'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Delete failed: ${e.toString()}'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _showStarredMessages() async {
    if (_profile == null) return;
    try {
      final starred = await _supabaseService.getStarredMessages(
        _profile!['id'],
      );
      if (!mounted) return;

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
                    const SizedBox(height: 14),
                    Text(
                      'Starred Messages',
                      style: GoogleFonts.poppins(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (starred.isEmpty)
                      Center(
                        child: Text(
                          'No starred messages',
                          style: GoogleFonts.poppins(color: Colors.white54),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          children:
                              starred.map((m) {
                                final content = (m['content'] ?? '').toString();
                                final type =
                                    (m['message_type'] ?? 'text').toString();
                                final time = DateTime.tryParse(
                                  (m['created_at'] ?? '').toString(),
                                );
                                return ListTile(
                                  leading: Icon(
                                    type == 'image'
                                        ? Icons.image_rounded
                                        : type == 'audio'
                                        ? Icons.mic_rounded
                                        : type == 'file'
                                        ? Icons.insert_drive_file_rounded
                                        : Icons.star_rounded,
                                    color: Colors.amber,
                                  ),
                                  title: Text(
                                    content.isEmpty ? '[$type]' : content,
                                    style: GoogleFonts.poppins(
                                      color: Colors.white,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    time != null
                                        ? '${time.day}/${time.month}/${time.year} ${time.hour}:${time.minute.toString().padLeft(2, '0')}'
                                        : '',
                                    style: GoogleFonts.poppins(
                                      color: Colors.white54,
                                      fontSize: 11,
                                    ),
                                  ),
                                );
                              }).toList(),
                        ),
                      ),
                  ],
                ),
              ),
            ),
      );
    } catch (_) {}
  }

  void _showBackupRestoreSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F2027),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder:
          (context) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
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
                  const SizedBox(height: 14),
                  Text(
                    'Chat Backup & Restore',
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Share your entire chat history and contacts, or restore from a backup file.',
                    style: GoogleFonts.poppins(
                      color: Colors.white70,
                      fontSize: 13,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: _exportAllChatsAsTxt,
                      icon: const Icon(Icons.description_rounded),
                      label: Text(
                        'Export as TXT',
                        style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.cyan,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: _shareChatBackup,
                      icon: const Icon(Icons.share_rounded),
                      label: Text(
                        'Share Chat Backup (JSON)',
                        style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6366F1),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: _restoreChatFromBackup,
                      icon: const Icon(Icons.restore_rounded),
                      label: Text(
                        'Restore Chat Backup',
                        style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2AABEE),
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

  void _showVpnBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F2027),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder:
          (context) => DraggableScrollableSheet(
            initialChildSize: 0.6,
            minChildSize: 0.4,
            maxChildSize: 0.9,
            expand: false,
            builder: (context, scrollController) {
              return SingleChildScrollView(
                controller: scrollController,
                child: const Padding(
                  padding: EdgeInsets.all(16),
                  child: VpnCard(),
                ),
              );
            },
          ),
    );
  }

  void _showPrivacySettings() {
    bool hideLastSeen = false;
    bool hideReadReceipts = false;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F2027),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            _supabaseService.getMyPrivacySettings().then((settings) {
              if (settings != null) {
                setModalState(() {
                  hideLastSeen = settings['hide_last_seen'] == true;
                  hideReadReceipts = settings['hide_read_receipts'] == true;
                });
              }
            });

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
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
                    const SizedBox(height: 14),
                    Text(
                      'Privacy Settings',
                      style: GoogleFonts.poppins(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 20),
                    SwitchListTile(
                      value: hideLastSeen,
                      onChanged: (v) async {
                        await _supabaseService.updatePrivacySettings(
                          hideLastSeen: v,
                        );
                        setModalState(() => hideLastSeen = v);
                      },
                      title: Text(
                        'Hide Last Seen',
                        style: GoogleFonts.poppins(color: Colors.white),
                      ),
                      subtitle: Text(
                        'Others won\'t see when you were last online',
                        style: GoogleFonts.poppins(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                      activeColor: const Color(0xFF6366F1),
                    ),
                    SwitchListTile(
                      value: hideReadReceipts,
                      onChanged: (v) async {
                        await _supabaseService.updatePrivacySettings(
                          hideReadReceipts: v,
                        );
                        setModalState(() => hideReadReceipts = v);
                      },
                      title: Text(
                        'Hide Read Receipts',
                        style: GoogleFonts.poppins(color: Colors.white),
                      ),
                      subtitle: Text(
                        'Others won\'t see if you read their messages',
                        style: GoogleFonts.poppins(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                      activeColor: const Color(0xFF6366F1),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // [UPDATE 2026-06-10-P5] WhatsApp-exact light mode colors
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = Theme.of(context).scaffoldBackgroundColor;
    final textColor = isDark ? Colors.white : Colors.black87;
    final hintColor = textColor.withOpacity(0.3);
    final fieldFillColor = isDark
        ? Colors.white.withOpacity(0.05)
        : const Color(0xFFF0F2F5);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Builder(
          builder:
              (context) => IconButton(
                icon: const Icon(Icons.menu_rounded),
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
        flexibleSpace: isDark
            ? Container(
                decoration: const BoxDecoration(gradient: AppColors.accentGradient),
                child: Container(color: Colors.black.withOpacity(0.55)),
              )
            : null,
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
    final fieldBg = isDark ? Colors.white.withOpacity(0.05) : const Color(0xFFF0F2F5);
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
    final fieldBg = isDark ? Colors.white.withOpacity(0.05) : const Color(0xFFF0F2F5);
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
              borderRadius: BorderRadius.circular(15),
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

  Widget _buildChatHistory({List<Map<String, dynamic>>? filteredThreads}) {
    final threads = filteredThreads ?? _threads;
    if (_threadsLoading && _threads.isEmpty && _groups.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (threads.isEmpty && _groups.isEmpty) {
      return _buildEmptyState();
    }

    // [UPDATE 2026-06-10] Profile header, UUID input, search bar & offline badge ALL scroll
    // with content — moved profile header inside the ListView
    Widget profileHeader = _buildProfileHeader();
    Widget uuidInput = _buildUuidInput();
    Widget searchBar = _buildThreadSearchBar();
    Widget offlineBanner = _isOnline
        ? const SizedBox.shrink()
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.withOpacity(0.4)),
            ),
            child: const Row(
              children: [
                Icon(Icons.wifi_off_rounded, color: Colors.orangeAccent, size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Offline — messages will send when connected',
                    style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
                  ),
                ),
              ],
            ),
          );

    const int headerItemCount = 4; // profileHeader + uuidInput + searchBar + archivedEntry

    return RefreshIndicator(
      onRefresh: () async {
        await _refreshThreads();
        await _loadDiscoverUsers();
        await _loadGroups();
      },
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 80),
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        cacheExtent: 500,
        itemCount: headerItemCount + _groups.length + threads.length,
        itemBuilder: (context, index) {
          // Header items — all scroll with content now
          if (index == 0) return RepaintBoundary(child: profileHeader);
          if (index == 1) return RepaintBoundary(child: uuidInput);
          if (index == 2) return RepaintBoundary(child: searchBar);
          if (index == 3) {
            return Column(
              children: [
                if (!_isOnline) offlineBanner,
                RepaintBoundary(child: _buildArchivedEntry()),
              ],
            );
          }

          final adj = index - headerItemCount;
          if (adj < _groups.length) {
            final g = _groups[adj];
            return RepaintBoundary(child: _buildGroupTile(g));
          } else {
            final t = threads[adj - _groups.length];
            return RepaintBoundary(child: _buildThreadTile(t));
          }
        },
      ),
    );
  }

  Widget _buildArchivedEntry() {
    return FutureBuilder<int>(
      future: _countArchivedThreads(),
      builder: (context, snap) {
        final count = snap.data ?? 0;
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const CircleAvatar(
            radius: 22,
            backgroundColor: Color(0xFF203A43),
            child: Icon(Icons.archive_rounded, color: Colors.white70),
          ),
          title: Text(
            'Archived',
            style: GoogleFonts.poppins(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle:
              count == 0
                  ? Text(
                    'No archived chats',
                    style: GoogleFonts.poppins(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  )
                  : Text(
                    '$count chat${count == 1 ? '' : 's'}',
                    style: GoogleFonts.poppins(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
          trailing: const Icon(
            Icons.chevron_right_rounded,
            color: Colors.white38,
          ),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder:
                    (_) => ArchivedChatsScreen(
                      currentUser: _profile ?? const {},
                      threads: _threads,
                    ),
              ),
            );
          },
        );
      },
    );
  }

  Future<int> _countArchivedThreads() async {
    int count = 0;
    for (final t in _threads) {
      final otherId = (t['other_user_id'] ?? t['other_id'] ?? '').toString();
      final meta = await _localChatStore.getMeta(
        ownerUserId: (_profile?['id'] ?? '').toString(),
        otherId: otherId,
      );
      if (meta?.isArchived == true) count++;
    }
    return count;
  }

  Widget _buildGroupTile(Map<String, dynamic> group) {
    final groupName = (group['group_name'] ?? 'Group').toString();
    final lastMessage = (group['last_message'] ?? '').toString();
    final memberCount = group['member_count'] ?? 0;
    final myRole = (group['my_role'] ?? '').toString();
    final isSuperAdmin = myRole == 'super_admin';

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        radius: 26,
        backgroundColor: Colors.teal,
        child: Text(
          groupName[0].toUpperCase(),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Row(
        children: [
          const Icon(Icons.group_rounded, color: Colors.teal, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              groupName,
              style: GoogleFonts.poppins(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      subtitle: Text(
        lastMessage.isEmpty ? '$memberCount members' : lastMessage,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.poppins(color: Colors.white60, fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
      onTap: () => _openGroupChat(group),
      onLongPress: () => _showGroupOptionsDialog(group, isSuperAdmin),
    );
  }

  void _showGroupOptionsDialog(Map<String, dynamic> group, bool isSuperAdmin) {
    final groupName = (group['group_name'] ?? 'Group').toString();
    final groupId = (group['id'] ?? '').toString();

    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF0F2027),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            title: Text(
              groupName,
              style: GoogleFonts.poppins(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(
                    Icons.info_outline_rounded,
                    color: Colors.white70,
                  ),
                  title: Text(
                    'Group Info',
                    style: GoogleFonts.poppins(color: Colors.white),
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
    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF0F2027),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            title: Text(
              'Delete Group?',
              style: GoogleFonts.poppins(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: Text(
              'Are you sure you want to permanently delete "$groupName"? This cannot be undone. All messages and members will be removed.',
              style: GoogleFonts.poppins(color: Colors.white70, fontSize: 14),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  'Cancel',
                  style: GoogleFonts.poppins(color: Colors.white54),
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
            backgroundColor: const Color(0xFF0B141A),
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
    // No async getMeta per tile — all loaded eagerly in _preloadThreadMetaCache
    final metaKey = otherId;
    final meta = _threadMetaCache[metaKey];
    // If cache miss (first load scenario), load lazily without blocking render
    if (meta == null && !_threadMetaCache.containsKey(metaKey)) {
      _threadMetaCache[metaKey] = null; // mark loading
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
      trailing:
          effectiveUnread
              ? Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
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