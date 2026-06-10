import 'dart:async';
import 'dart:convert';

import 'package:isar/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/supabase_service.dart';
import 'local_message.dart';

class ChatThreadMeta {
  bool isPinned;
  DateTime? pinnedAt;

  bool isArchived;
  DateTime? archivedAt;

  bool isMuted;
  DateTime? muteUntil;

  bool isMarkedUnread;

  String? wallpaperPath;

  DateTime updatedAt;

  ChatThreadMeta({
    this.isPinned = false,
    this.pinnedAt,
    this.isArchived = false,
    this.archivedAt,
    this.isMuted = false,
    this.muteUntil,
    this.isMarkedUnread = false,
    this.wallpaperPath,
    DateTime? updatedAt,
  }) : updatedAt = (updatedAt ?? DateTime.now().toUtc());

  factory ChatThreadMeta.fromJson(Map<String, dynamic> json) {
    DateTime? dt(dynamic v) => v == null ? null : DateTime.tryParse(v.toString())?.toUtc();
    return ChatThreadMeta(
      isPinned: json['isPinned'] == true,
      pinnedAt: dt(json['pinnedAt']),
      isArchived: json['isArchived'] == true,
      archivedAt: dt(json['archivedAt']),
      isMuted: json['isMuted'] == true,
      muteUntil: dt(json['muteUntil']),
      isMarkedUnread: json['isMarkedUnread'] == true,
      wallpaperPath: json['wallpaperPath']?.toString(),
      updatedAt: dt(json['updatedAt']) ?? DateTime.now().toUtc(),
    );
  }

  Map<String, dynamic> toJson() => {
        'isPinned': isPinned,
        'pinnedAt': pinnedAt?.toIso8601String(),
        'isArchived': isArchived,
        'archivedAt': archivedAt?.toIso8601String(),
        'isMuted': isMuted,
        'muteUntil': muteUntil?.toIso8601String(),
        'isMarkedUnread': isMarkedUnread,
        'wallpaperPath': wallpaperPath,
        'updatedAt': updatedAt.toIso8601String(),
      };
}

/// WhatsApp-like local message store (Isar) + Supabase sync.
class LocalChatStore {
  static bool _isMuteActive(ChatThreadMeta meta) {
    if (!meta.isMuted) return false;
    final until = meta.muteUntil;
    if (until == null) return true;
    return until.isAfter(DateTime.now().toUtc());
  }

  LocalChatStore({SupabaseService? supabaseService}) : _supabase = supabaseService ?? SupabaseService();

  final SupabaseService _supabase;
  Isar? _isar;

  Future<Isar> _db() async {
    if (_isar != null && _isar!.isOpen) return _isar!;
    final dir = await getApplicationDocumentsDirectory();
    _isar = await Isar.open(
      [LocalMessageSchema],
      directory: p.join(dir.path, 'isar_db'),
      inspector: false,
    );
    return _isar!;
  }

  Future<void> upsertFromRemote({
    required String ownerUserId,
    required String otherUserId,
    required Map<String, dynamic> m,
  }) async {
    final isar = await _db();

    final remoteId = int.tryParse((m['id'] ?? '').toString());
    if (remoteId == null) return;

    await isar.writeTxn(() async {
      final existing = await isar.localMessages.filter().remoteIdEqualTo(remoteId).findFirst();
      final msg = existing ?? LocalMessage();

      msg.remoteId = remoteId;
      msg.ownerUserId = ownerUserId;
      msg.otherUserId = otherUserId;

      msg.senderId = (m['sender_id'] ?? '').toString();
      msg.receiverId = (m['receiver_id'] ?? '').toString();
      msg.messageType = (m['message_type'] ?? 'text').toString();
      msg.content = (m['content'] ?? '').toString();

      msg.mediaPath = m['media_path']?.toString();
      msg.mediaMime = m['media_mime']?.toString();
      msg.mediaDurationMs = m['media_duration_ms'] == null ? null : int.tryParse(m['media_duration_ms'].toString());
      msg.mediaName = m['media_name']?.toString();
      msg.mediaSizeBytes = m['media_size_bytes'] == null ? null : int.tryParse(m['media_size_bytes'].toString());

      msg.caption = m['caption']?.toString();
      msg.replyToRemoteId = m['reply_to_id'] == null ? null : int.tryParse(m['reply_to_id'].toString());

      final ca = DateTime.tryParse((m['created_at'] ?? '').toString());
      if (ca != null) msg.createdAt = ca.toUtc();

      msg.editedAt = m['edited_at'] == null ? null : DateTime.tryParse(m['edited_at'].toString())?.toUtc();
      msg.deletedAt = m['deleted_at'] == null ? null : DateTime.tryParse(m['deleted_at'].toString())?.toUtc();

      msg.isRead = m['is_read'] == true;
      msg.isDelivered = m['is_delivered'] == true;
      msg.deliveredAt = m['delivered_at'] == null ? null : DateTime.tryParse(m['delivered_at'].toString())?.toUtc();
      msg.isSending = m['is_sending'] == true;
      msg.isLiked = m['is_liked'] == true;

      // Reactions - stored as JSON string
      if (m['reactions'] != null) {
        msg.reactions = m['reactions'] is Map
            ? jsonEncode(m['reactions'])
            : m['reactions'].toString();
      }

      // Pinned
      msg.isPinned = m['is_pinned'] == true;

      // Media expiry
      msg.mediaExpiresAt = m['media_expires_at'] == null
          ? null
          : DateTime.tryParse(m['media_expires_at'].toString())?.toUtc();

      msg.expiresAt = m['expires_at'] == null ? null : DateTime.tryParse(m['expires_at'].toString())?.toUtc();
      msg.viewOnce = m['view_once'] == true;
      msg.viewedBySender = m['viewed_by_sender'] == true;
      msg.viewedByReceiver = m['viewed_by_receiver'] == true;

      msg.deletedForSender = m['deleted_for_sender'] == true;
      msg.deletedForReceiver = m['deleted_for_receiver'] == true;

      await isar.localMessages.put(msg);
    });
  }

  Stream<List<LocalMessage>> watchConversation({
    required String ownerUserId,
    required String otherUserId,
  }) async* {
    yield const <LocalMessage>[];

    try {
      final isar = await _db();
      yield* isar.localMessages
          .filter()
          .ownerUserIdEqualTo(ownerUserId)
          .otherUserIdEqualTo(otherUserId)
          .sortByCreatedAt()
          .watch(fireImmediately: true);
    } catch (_) {
      yield const <LocalMessage>[];
    }
  }

  /// One-time hydrate from Supabase into local store.
  Future<void> hydrateConversation({required String ownerUserId, required String otherUserId}) async {
    final remote = await _supabase.fetchConversationOnce(ownerUserId, otherUserId);
    for (final m in remote) {
      await upsertFromRemote(ownerUserId: ownerUserId, otherUserId: otherUserId, m: m);
    }
  }

  /// Restore local store from a backup message list (messages.json).
  Future<void> restoreFromBackup({required String ownerUserId, required List<dynamic> messages}) async {
    for (final raw in messages) {
      if (raw is! Map) continue;
      final m = raw.cast<String, dynamic>();

      final sender = (m['sender_id'] ?? '').toString();
      final receiver = (m['receiver_id'] ?? '').toString();
      if (sender.isEmpty || receiver.isEmpty) continue;
      final otherUserId = (sender == ownerUserId) ? receiver : sender;

      await upsertFromRemote(ownerUserId: ownerUserId, otherUserId: otherUserId, m: m);
    }
  }

  /// [UPDATE 2026-06-10] Hydrate ALL conversations from Supabase into Isar
  /// This is the key offline-first feature: on startup, load everything!
  Future<void> hydrateAllConversations({required String ownerUserId}) async {
    try {
      // Get all unique conversation partners
      final threads = await _supabase.getChatThreads();
      for (final thread in threads) {
        final otherUserId = (thread['other_user_id'] ?? '').toString();
        if (otherUserId.isEmpty) continue;
        await hydrateConversation(ownerUserId: ownerUserId, otherUserId: otherUserId);
      }
    } catch (_) {}
  }

  /// [UPDATE 2026-06-10] Get chat threads from local DB (offline-first)
  /// Returns list of {otherUserId, otherDisplayName, lastMessage, lastMessageAt, unreadCount}
  Future<List<Map<String, dynamic>>> getLocalChatThreads({required String ownerUserId}) async {
    final isar = await _db();

    // Get all unique otherUserIds
    final others = await isar.localMessages
        .filter()
        .ownerUserIdEqualTo(ownerUserId)
        .otherUserIdProperty()
        .findAll();

    final uniqueOthers = others.toSet().where((id) => id.isNotEmpty).toList();
    final threads = <Map<String, dynamic>>[];

    for (final otherId in uniqueOthers) {
      // Get last message
      final lastMsg = await isar.localMessages
          .filter()
          .ownerUserIdEqualTo(ownerUserId)
          .otherUserIdEqualTo(otherId)
          .sortByCreatedAtDesc()
          .findFirst();

      if (lastMsg == null) continue;

      // Count unread
      final unreadCount = await isar.localMessages
          .filter()
          .ownerUserIdEqualTo(ownerUserId)
          .otherUserIdEqualTo(otherId)
          .isReadEqualTo(false)
          .senderIdEqualTo(otherId)
          .count();

      // Get display name from Supabase profile (cached)
      final profile = await _supabase.getProfile(otherId);

      threads.add({
        'other_user_id': otherId,
        'other_username': profile?['username'] ?? '',
        'other_display_name': profile?['display_name'] ?? profile?['username'] ?? otherId.substring(0, 8),
        'last_message': lastMsg.content,
        'last_message_at': lastMsg.createdAt.toIso8601String(),
        'unread_count': unreadCount,
        'last_message_type': lastMsg.messageType,
      });
    }

    threads.sort((a, b) {
      final aTime = DateTime.tryParse(a['last_message_at'] ?? '');
      final bTime = DateTime.tryParse(b['last_message_at'] ?? '');
      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      return bTime.compareTo(aTime);
    });

    return threads;
  }

  /// Get unread count for a conversation
  Future<int> getUnreadCount({required String ownerUserId, required String otherUserId}) async {
    final isar = await _db();
    final unread = await isar.localMessages
        .filter()
        .ownerUserIdEqualTo(ownerUserId)
        .otherUserIdEqualTo(otherUserId)
        .and()
        .isReadEqualTo(false)
        .and()
        .senderIdEqualTo(otherUserId)
        .findAll();
    return unread.length;
  }

  // ---------------- Thread metadata (pin/mute/archive/unread/wallpaper) ----------------

  SharedPreferences? _prefs;

  Future<SharedPreferences> _sp() async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  static String _metaKey({required String ownerUserId, required String otherId, bool isGroup = false}) {
    return 'chat_meta_v1:${ownerUserId}:${isGroup ? 'g' : 'u'}:$otherId';
  }

  Future<ChatThreadMeta?> getMeta({required String ownerUserId, required String otherId, bool isGroup = false}) async {
    final sp = await _sp();
    final raw = sp.getString(_metaKey(ownerUserId: ownerUserId, otherId: otherId, isGroup: isGroup));
    if (raw == null || raw.isEmpty) return null;
    try {
      return ChatThreadMeta.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveMeta({required String ownerUserId, required String otherId, required ChatThreadMeta meta, bool isGroup = false}) async {
    final sp = await _sp();
    await sp.setString(
      _metaKey(ownerUserId: ownerUserId, otherId: otherId, isGroup: isGroup),
      jsonEncode(meta.toJson()),
    );
  }

  Future<ChatThreadMeta> _getOrCreateMeta({required String ownerUserId, required String otherId, bool isGroup = false}) async {
    final existing = await getMeta(ownerUserId: ownerUserId, otherId: otherId, isGroup: isGroup);
    return existing ?? ChatThreadMeta();
  }

  Future<void> togglePinned({required String ownerUserId, required String otherId, bool isGroup = false}) async {
    final meta = await _getOrCreateMeta(ownerUserId: ownerUserId, otherId: otherId, isGroup: isGroup);
    meta.isPinned = !meta.isPinned;
    meta.pinnedAt = meta.isPinned ? DateTime.now().toUtc() : null;
    meta.updatedAt = DateTime.now().toUtc();
    await _saveMeta(ownerUserId: ownerUserId, otherId: otherId, isGroup: isGroup, meta: meta);
  }

  /// muteFor: null => mute indefinitely; Duration.zero => unmute
  Future<void> setMute({required String ownerUserId, required String otherId, Duration? muteFor, bool isGroup = false}) async {
    final meta = await _getOrCreateMeta(ownerUserId: ownerUserId, otherId: otherId, isGroup: isGroup);
    if (muteFor == Duration.zero) {
      meta.isMuted = false;
      meta.muteUntil = null;
    } else {
      meta.isMuted = true;
      meta.muteUntil = muteFor == null ? null : DateTime.now().toUtc().add(muteFor);
    }
    meta.updatedAt = DateTime.now().toUtc();
    await _saveMeta(ownerUserId: ownerUserId, otherId: otherId, isGroup: isGroup, meta: meta);
  }

  Future<void> toggleArchived({required String ownerUserId, required String otherId, bool isGroup = false}) async {
    final meta = await _getOrCreateMeta(ownerUserId: ownerUserId, otherId: otherId, isGroup: isGroup);
    meta.isArchived = !meta.isArchived;
    meta.archivedAt = meta.isArchived ? DateTime.now().toUtc() : null;
    meta.updatedAt = DateTime.now().toUtc();
    await _saveMeta(ownerUserId: ownerUserId, otherId: otherId, isGroup: isGroup, meta: meta);
  }

  /// Explicitly set archived state (used by Archived screen).
  Future<void> setArchived({
    required String ownerUserId,
    required String otherId,
    required bool archived,
    bool isGroup = false,
  }) async {
    final meta = await _getOrCreateMeta(ownerUserId: ownerUserId, otherId: otherId, isGroup: isGroup);
    meta.isArchived = archived;
    meta.archivedAt = archived ? DateTime.now().toUtc() : null;
    meta.updatedAt = DateTime.now().toUtc();
    await _saveMeta(ownerUserId: ownerUserId, otherId: otherId, isGroup: isGroup, meta: meta);
  }

  Future<void> toggleMarkedUnread({required String ownerUserId, required String otherId, bool isGroup = false}) async {
    final meta = await _getOrCreateMeta(ownerUserId: ownerUserId, otherId: otherId, isGroup: isGroup);
    meta.isMarkedUnread = !meta.isMarkedUnread;
    meta.updatedAt = DateTime.now().toUtc();
    await _saveMeta(ownerUserId: ownerUserId, otherId: otherId, isGroup: isGroup, meta: meta);
  }

  Future<void> setWallpaper({required String ownerUserId, required String otherId, String? wallpaperPath, bool isGroup = false}) async {
    final meta = await _getOrCreateMeta(ownerUserId: ownerUserId, otherId: otherId, isGroup: isGroup);
    meta.wallpaperPath = wallpaperPath;
    meta.updatedAt = DateTime.now().toUtc();
    await _saveMeta(ownerUserId: ownerUserId, otherId: otherId, isGroup: isGroup, meta: meta);
  }

  Future<bool> isMutedActive({required String ownerUserId, required String otherId, bool isGroup = false}) async {
    final meta = await getMeta(ownerUserId: ownerUserId, otherId: otherId, isGroup: isGroup);
    if (meta == null) return false;
    return _isMuteActive(meta);
  }

  /// Mark all messages as read locally
  Future<void> markAllAsRead({required String ownerUserId, required String otherUserId}) async {
    final isar = await _db();
    await isar.writeTxn(() async {
      final unread = await isar.localMessages
          .filter()
          .ownerUserIdEqualTo(ownerUserId)
          .otherUserIdEqualTo(otherUserId)
          .and()
          .isReadEqualTo(false)
          .and()
          .senderIdEqualTo(otherUserId)
          .findAll();
      for (final msg in unread) {
        msg.isRead = true;
        await isar.localMessages.put(msg);
      }
    });
  }
}
