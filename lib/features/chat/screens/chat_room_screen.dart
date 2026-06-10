import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:provider/provider.dart';

import '../../../services/supabase_service.dart';
import '../../../services/notification_service.dart';
import '../../../services/background_message_poller.dart';
import '../../../services/theme_provider.dart';
import '../../../local_db/local_chat_store.dart';
import '../../../shared/widgets/rich_text_editor.dart';
import '../../../shared/widgets/glass_container.dart';
import '../../../shared/widgets/fullscreen_image_viewer.dart';
import '../../../shared/widgets/image_editor.dart';
import '../../../calls/call_screen.dart';
import '../../../services/cdn_chat_business_service.dart';

class ChatRoomScreen extends StatefulWidget {
  final Map<String, dynamic> otherUser;
  final Map<String, dynamic> currentUser;

  const ChatRoomScreen({
    super.key,
    required this.otherUser,
    required this.currentUser,
  });

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> with TickerProviderStateMixin {
  final _messageController = TextEditingController();
  final _supabaseService = SupabaseService();
  final _scrollController = ScrollController();
  final _localChatStore = LocalChatStore();

  String? _wallpaperPath;

  final _imagePicker = ImagePicker();
  final _recorder = AudioRecorder();
  final _audioPlayer = AudioPlayer();

  final Map<int, String> _signedUrlCache = {};
  final Map<int, String> _localMediaCache = {};
  int? _currentlyPlayingMessageId;
  bool _isRecording = false;

  // Reply to
  Map<String, dynamic>? _replyToMessage;

  // Edit message (20min window)
  Map<String, dynamic>? _editingMessage;

  // Rich text toolbar visible
  bool _showRichTextToolbar = false;

  // Privacy
  bool _otherHideLastSeen = false;
  bool _otherHideReadReceipts = false;
  bool _myHideReadReceipts = false;

  // Typing — debounced to avoid flooding Supabase on every keystroke
  bool _isTyping = false;
  StreamSubscription<bool>? _typingSub;
  Timer? _typingDebounceTimer;
  bool _lastSentTypingState = false;

  // Call signaling
  StreamSubscription<List<Map<String, dynamic>>>? _callSignalSub;
  final Set<String> _seenSignalIds = {};

  // Media cleanup timer
  Timer? _mediaCleanupTimer;

  late AnimationController _emojiAnimController;

  // View-once tracking
  final Set<int> _viewOnceShown = {};

  // Chat search + jump-to-date (WhatsApp-like)
  final Map<String, GlobalKey> _messageKeys = {};
  final Map<String, GlobalKey> _dateHeaderKeys = {};

  List<Map<String, dynamic>> _latestMessages = const [];
  // ── WHATSAPP-LIKE LOCAL-FIRST: Local messages for instant rendering ──
  List<Map<String, dynamic>> _localPendingMessages = const [];

  // ── SMOOTH SCROLL FIX: Track previous message count ──
  // Only auto-scroll when NEW messages arrive, not on every rebuild
  int _previousMessageCount = 0;
  bool _isNearBottom = true; // Track if user scrolled up

  // ── Performance: debounce expensive operations ──
  Timer? _markReadDebounce;
  Timer? _localSyncDebounce;
  int _lastSyncedCount = 0;

  @override
  void initState() {
    super.initState();
    _supabaseService.markAsRead(widget.currentUser['id'], widget.otherUser['id']);
    _localChatStore.markAllAsRead(
      ownerUserId: widget.currentUser['id'],
      otherUserId: widget.otherUser['id'],
    );

    _audioPlayer.playerStateStream.listen((state) {
      if (!mounted) return;
      if (state.processingState == ProcessingState.completed) {
        setState(() => _currentlyPlayingMessageId = null);
      } else {
        setState(() {});
      }
    });

    _loadPrivacySettings();
    _loadWallpaper();

    _typingSub = _supabaseService.streamIsOtherTyping(otherUserId: widget.otherUser['id']).listen((typing) {
      if (mounted) setState(() => _isTyping = typing);
    });

    _listenForCalls();

    _emojiAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    // ── SMOOTH TYPING FIX: Debounce typing signals ──
    // Instead of sending a Supabase RPC on every keystroke, we debounce
    // so we send on state change and then keep-alive every 2s while typing.
    _messageController.addListener(_onTextChanged);

    // Track scroll position to know if user is near bottom
    _scrollController.addListener(_onScrollChanged);

    _mediaCleanupTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      _supabaseService.cleanupExpiredSupabaseMedia();
    });
    _supabaseService.cleanupExpiredSupabaseMedia();
  }

  Future<void> _loadPrivacySettings() async {
    try {
      final otherProfile = await _supabaseService.getProfile(widget.otherUser['id']);
      if (otherProfile != null) {
        if (mounted) {
          setState(() {
            _otherHideLastSeen = otherProfile['hide_last_seen'] == true;
            _otherHideReadReceipts = otherProfile['hide_read_receipts'] == true;
          });
        }
      }
      final myPrivacy = await _supabaseService.getMyPrivacySettings();
      if (myPrivacy != null && mounted) {
        setState(() {
          _myHideReadReceipts = myPrivacy['hide_read_receipts'] == true;
        });
      }
    } catch (_) {}
  }

  /// Debounced text change handler for typing indicator.
  /// Sends typing state on change and keeps alive every 2s while typing.
  void _onTextChanged() {
    final isTyping = _messageController.text.trim().isNotEmpty;

    _typingDebounceTimer?.cancel();

    if (isTyping != _lastSentTypingState) {
      _lastSentTypingState = isTyping;
      _supabaseService.setTyping(
        receiverId: widget.otherUser['id'],
        isTyping: isTyping,
      );
    }

    if (isTyping) {
      _typingDebounceTimer = Timer(const Duration(seconds: 2), () {
        if (_messageController.text.trim().isNotEmpty && mounted) {
          _supabaseService.setTyping(
            receiverId: widget.otherUser['id'],
            isTyping: true,
          );
        }
      });
    }
  }

  /// Track whether user is near the bottom of the chat.
  void _onScrollChanged() {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;
    _isNearBottom = (maxScroll - currentScroll) < 100;
  }

  bool _isSameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  String _dayKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Widget _buildDateHeader(DateTime date, {Key? key}) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(date.year, date.month, date.day);

    String label;
    if (d == today) {
      label = 'Today';
    } else if (d == today.subtract(const Duration(days: 1))) {
      label = 'Yesterday';
    } else {
      label = '${date.day.toString().padLeft(2, '0')}/'
          '${date.month.toString().padLeft(2, '0')}/'
          '${date.year}';
    }

    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.35),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white10),
          ),
          child: Text(
            label,
            style: GoogleFonts.poppins(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  Future<void> _showChatSearch() async {
    if (_latestMessages.isEmpty) return;

    final controller = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) {
        List<Map<String, dynamic>> matches = const [];

        return StatefulBuilder(
          builder: (ctx, setLocal) {
            void runSearch(String q) {
              final query = q.trim().toLowerCase();
              if (query.isEmpty) {
                setLocal(() => matches = const []);
                return;
              }
              final res = <Map<String, dynamic>>[];
              for (final m in _latestMessages) {
                final type = (m['message_type'] ?? 'text').toString();
                if (type != 'text') continue;
                final content = (m['content'] ?? '').toString();
                if (content.toLowerCase().contains(query)) res.add(m);
              }
              setLocal(() => matches = res.take(50).toList());
            }

            return AlertDialog(
              backgroundColor: const Color(0xFF203A43),
              title: Text('Search in chat', style: GoogleFonts.poppins(color: Colors.white)),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Type to search...',
                        hintStyle: const TextStyle(color: Colors.white54),
                        filled: true,
                        fillColor: Colors.black.withOpacity(0.25),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      ),
                      onChanged: runSearch,
                    ),
                    const SizedBox(height: 12),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: matches.length,
                        itemBuilder: (ctx, i) {
                          final m = matches[i];
                          final id = (m['id'] ?? '').toString();
                          final content = (m['content'] ?? '').toString();
                          final ts = DateTime.tryParse((m['created_at'] ?? '').toString())?.toLocal();
                          return ListTile(
                            dense: true,
                            title: Text(
                              content,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.poppins(color: Colors.white, fontSize: 13),
                            ),
                            subtitle: ts == null
                                ? null
                                : Text(
                                    '${ts.day.toString().padLeft(2, '0')}/${ts.month.toString().padLeft(2, '0')} ${_formatTime(ts)}',
                                    style: GoogleFonts.poppins(color: Colors.white54, fontSize: 11),
                                  ),
                            onTap: () {
                              Navigator.pop(ctx);
                              _jumpToMessage(id);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('Close', style: GoogleFonts.poppins(color: Colors.white70)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showJumpToDate() async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDate: DateTime.now(),
      builder: (ctx, child) {
        return Theme(
          data: Theme.of(ctx).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF6366F1),
              surface: Color(0xFF203A43),
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked == null) return;

    final key = _dayKey(picked);
    final headerKey = _dateHeaderKeys[key];
    final headerContext = headerKey?.currentContext;
    if (headerContext == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No messages on that date')),
      );
      return;
    }

    await Scrollable.ensureVisible(
      headerContext,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      alignment: 0.1,
    );
  }

  Future<void> _jumpToMessage(String messageId) async {
    final key = _messageKeys[messageId];
    final ctx = key?.currentContext;
    if (ctx == null) return;
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      alignment: 0.3,
    );
  }

  void _listenForCalls() {
    final selfId = widget.currentUser['id'] as String;
    _callSignalSub = _supabaseService.streamCallSignals(selfId).listen((signals) {
      if (!mounted) return;
      for (final s in signals) {
        final sigId = (s['id'] ?? '').toString();
        if (_seenSignalIds.contains(sigId)) continue;
        _seenSignalIds.add(sigId);

        final fromId = (s['from_id'] ?? '').toString();
        if (fromId != widget.otherUser['id']) continue;

        final type = (s['type'] ?? '').toString();
        if (type == 'call_offer' || type == 'offer') {
          final payload = s['payload'] as Map<String, dynamic>?;
          final isVideo = payload?['is_video'] == true;
          _showIncomingCallDialog(fromId, isVideo);
        }
      }
    });
  }

  void _showIncomingCallDialog(String fromId, bool isVideo) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF203A43),
        title: Text(isVideo ? 'Incoming Video Call' : 'Incoming Voice Call',
            style: GoogleFonts.poppins(color: Colors.white)),
        content: Text(
          '${widget.otherUser['display_name'] ?? widget.otherUser['username']} is calling...',
          style: GoogleFonts.poppins(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _supabaseService.logMissedCall(
                callerId: fromId,
                receiverId: widget.currentUser['id'],
                isVideo: isVideo,
              );
            },
            child: const Text('Decline', style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CallScreen(
                    selfId: widget.currentUser['id'],
                    peerId: fromId,
                    isVideo: isVideo,
                    isCaller: false,
                  ),
                ),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Accept'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadWallpaper() async {
    try {
      final meta = await _localChatStore.getMeta(
        ownerUserId: widget.currentUser['id'],
        otherId: widget.otherUser['id'],
      );
      if (!mounted) return;
      setState(() => _wallpaperPath = meta?.wallpaperPath);
    } catch (_) {}
  }

  Future<void> _pickAndSetWallpaper() async {
    try {
      final res = await FilePicker.platform.pickFiles(type: FileType.image);
      if (res == null || res.files.isEmpty) return;
      final pickedPath = res.files.single.path;
      if (pickedPath == null) return;

      final docs = await getApplicationDocumentsDirectory();
      final ext = p.extension(pickedPath);
      final destDir = Directory(p.join(docs.path, 'chat_wallpapers'));
      if (!await destDir.exists()) await destDir.create(recursive: true);
      final destPath = p.join(
        destDir.path,
        '${widget.currentUser['id']}_${widget.otherUser['id']}${ext.isEmpty ? '.jpg' : ext}',
      );

      await File(pickedPath).copy(destPath);
      await _localChatStore.setWallpaper(
        ownerUserId: widget.currentUser['id'],
        otherId: widget.otherUser['id'],
        wallpaperPath: destPath,
      );
      if (!mounted) return;
      setState(() => _wallpaperPath = destPath);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Wallpaper updated'), backgroundColor: Colors.green),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to set wallpaper: $e'), backgroundColor: Colors.redAccent),
      );
    }
  }

  Future<void> _clearWallpaper() async {
    try {
      await _localChatStore.setWallpaper(
        ownerUserId: widget.currentUser['id'],
        otherId: widget.otherUser['id'],
        wallpaperPath: null,
      );
      if (!mounted) return;
      setState(() => _wallpaperPath = null);
    } catch (_) {}
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
    _recorder.dispose();
    _typingSub?.cancel();
    _typingDebounceTimer?.cancel();
    _callSignalSub?.cancel();
    _emojiAnimController.dispose();
    _mediaCleanupTimer?.cancel();
    _markReadDebounce?.cancel();
    _localSyncDebounce?.cancel();
    // Send "stopped typing" on dispose
    _supabaseService.setTyping(receiverId: widget.otherUser['id'], isTyping: false);
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final content = _messageController.text.trim();
    if (content.isEmpty) return;

    _messageController.clear();

    // If editing a message
    if (_editingMessage != null) {
      final createdAt = DateTime.tryParse((_editingMessage!['created_at'] ?? '').toString());
      if (createdAt != null && DateTime.now().difference(createdAt).inMinutes <= 20) {
        final hasRich = RichTextEditor.hasFormatting(content);
        if (hasRich) {
          final segments = RichTextEditor.parseMarkdownToSegments(content);
          final richJson = RichTextEditor.toJsonString(segments);
          final plainText = segments.map((s) => s.text).join();
          await _supabaseService.editRichTextMessage(
            messageId: _editingMessage!['id'],
            content: plainText,
            richTextJson: richJson,
          );
        } else {
          await _supabaseService.editMessage(
            messageId: _editingMessage!['id'],
            newContent: content,
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cannot edit: 20 minute window has passed'), backgroundColor: Colors.redAccent),
          );
        }
      }
      setState(() => _editingMessage = null);
      return;
    }

    // Determine message type
    String messageType = 'text';
    if (_isOnlyEmoji(content)) {
      messageType = 'emoji';
    }

    // Check for rich text formatting
    final hasRich = RichTextEditor.hasFormatting(content);
    String? richTextJson;
    String plainContent = content;
    bool isRichText = false;

    if (hasRich) {
      isRichText = true;
      final segments = RichTextEditor.parseMarkdownToSegments(content);
      richTextJson = RichTextEditor.toJsonString(segments);
      plainContent = segments.map((s) => s.text).join();
    }

    // ── WHATSAPP-LIKE: Show message instantly in local pending list ──
    // before Supabase even confirms. This makes the send FEEL instant.
    final localMsg = <String, dynamic>{
      'id': -DateTime.now().millisecondsSinceEpoch, // negative = pending
      'sender_id': widget.currentUser['id'],
      'receiver_id': widget.otherUser['id'],
      'content': hasRich ? plainContent : content,
      'message_type': messageType,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'is_read': true,
      'is_liked': false,
      'reply_to_id': _replyToMessage?['id'],
      'is_rich_text': isRichText,
      'rich_text_json': richTextJson,
      'is_pinned': false,
      '_is_pending': true,
    };
    setState(() {
      _localPendingMessages = [..._localPendingMessages, localMsg];
    });

    // Send to Supabase in the background (UI already shows the message)
    _supabaseService.sendMessage(
      senderId: widget.currentUser['id'],
      receiverId: widget.otherUser['id'],
      content: hasRich ? plainContent : content,
      messageType: messageType,
      replyToId: _replyToMessage?['id'],
      isRichText: isRichText,
      richTextJson: richTextJson,
    );

    // Record earning for Premium users (₦0.75 per message)
    try {
      final CdnChatBusinessService business = CdnChatBusinessService();
      final tier = await business.getUserTier(widget.currentUser['id']);
      if (tier.canEarn) {
        business.recordEarning(
          userId: widget.currentUser['id'],
          amount: CdnChatBusinessService.messageSentRate,
          source: 'message_sent',
        ).then((result) {
          debugPrint('Earning recorded for message: $result');
        }).catchError((e) {
          debugPrint('Earning recording failed: $e');
        });
        business.updateStreak(widget.currentUser['id']);
      }
    } catch (_) {}

    setState(() => _replyToMessage = null);
    _forceScrollToBottom();
  }

  Future<void> _scheduleMessage() async {
    final content = _messageController.text.trim();
    if (content.isEmpty) return;

    // Pick date + time
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 5))),
    );
    if (time == null) return;

    final when = DateTime(date.year, date.month, date.day, time.hour, time.minute);

    String messageType = 'text';
    if (_isOnlyEmoji(content)) messageType = 'emoji';

    await BackgroundMessagePoller.scheduleMessageSend(
      when: when,
      senderId: widget.currentUser['id'],
      receiverId: widget.otherUser['id'],
      content: content,
      messageType: messageType,
    );

    _messageController.clear();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Scheduled for ${when.toLocal()}'),
          backgroundColor: const Color(0xFF2AABEE),
        ),
      );
    }
  }

  bool _isOnlyEmoji(String text) {
    final emojiRegex = RegExp(
      r'^[\u{1F600}-\u{1F64F}\u{1F300}-\u{1F5FF}\u{1F680}-\u{1F6FF}\u{1F1E0}-\u{1F1FF}\u{2600}-\u{26FF}\u{2700}-\u{27BF}\u{FE00}-\u{FE0F}\u{1F900}-\u{1F9FF}\u{1FA00}-\u{1FA6F}\u{1FA70}-\u{1FAFF}\u{200D}\u{20E3}\u{FE0F}\u{E0020}-\u{E007F}\s]+$',
      unicode: true,
    );
    return emojiRegex.hasMatch(text) && text.replaceAll(RegExp(r'\s'), '').isNotEmpty;
  }

  Future<String?> _getSignedUrlForMessage(Map<String, dynamic> message) async {
    final int id = message['id'] as int;
    final String? mediaPath = message['media_path'] as String?;
    if (mediaPath == null || mediaPath.isEmpty) return null;

    if (_signedUrlCache.containsKey(id)) return _signedUrlCache[id];
    if (_localMediaCache.containsKey(id)) return _localMediaCache[id];

    try {
      final localPath = await _supabaseService.cacheMediaLocally(
        mediaPath: mediaPath,
        mediaMime: message['media_mime'] ?? '',
      );
      if (localPath.startsWith('/') || localPath.startsWith('file://')) {
        _localMediaCache[id] = localPath;
        return localPath;
      }
      _signedUrlCache[id] = localPath;
      return localPath;
    } catch (_) {
      try {
        final url = await _supabaseService.createSignedChatMediaUrl(mediaPath);
        _signedUrlCache[id] = url;
        return url;
      } catch (_) {
        return null;
      }
    }
  }

  Future<void> _pickAndSendImage({bool viewOnce = false}) async {
    final XFile? picked = await _imagePicker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;

    // Offer options: Crop, Edit (draw/text), or Send as is
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF203A43),
        title: Text('Send Image', style: GoogleFonts.poppins(color: Colors.white)),
        content: Text('Edit or crop the image before sending?', style: GoogleFonts.poppins(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'send'),
            child: const Text('Send as is', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, 'crop'),
            icon: const Icon(Icons.crop_rounded, size: 18),
            label: const Text('Crop'),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2AABEE)),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, 'edit'),
            icon: const Icon(Icons.brush_rounded, size: 18),
            label: const Text('Draw / Text'),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6366F1)),
          ),
        ],
      ),
    );

    if (action == null) return; // User cancelled

    String imagePath = picked.path;

    if (action == 'crop') {
      CroppedFile? cropped;
      try {
        cropped = await ImageCropper().cropImage(
          sourcePath: picked.path,
          uiSettings: [
            AndroidUiSettings(
              toolbarTitle: 'Crop Image',
              toolbarColor: const Color(0xFF6366F1),
              toolbarWidgetColor: Colors.white,
              backgroundColor: const Color(0xFF0F2027),
              aspectRatioPresets: [
                CropAspectRatioPreset.original,
                CropAspectRatioPreset.square,
                CropAspectRatioPreset.ratio3x2,
                CropAspectRatioPreset.ratio4x3,
                CropAspectRatioPreset.ratio16x9,
              ],
              initAspectRatio: CropAspectRatioPreset.original,
              lockAspectRatio: false,
              hideBottomControls: false,
              showCropGrid: true,
              cropGridColor: Colors.white24,
              cropGridColumnCount: 3,
              cropGridRowCount: 3,
            ),
          ],
        );
      } catch (e) {
        // Cropper crashed — use original image as fallback
        debugPrint('ImageCropper error (using original): $e');
      }
      if (cropped != null) {
        imagePath = cropped.path;
      }

      // After crop, offer to draw/text on the cropped image
      if (!mounted) return;

      final editAfterCrop = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF203A43),
          title: Text('Draw on image?', style: GoogleFonts.poppins(color: Colors.white)),
          content: Text('Add text or draw on the cropped image?', style: GoogleFonts.poppins(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('No, send', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6366F1)),
              child: const Text('Draw / Text'),
            ),
          ],
        ),
      );

      if (editAfterCrop == true) {
        final editedPath = await Navigator.of(context).push<String>(
          MaterialPageRoute(
            builder: (_) => ImageEditorScreen(imagePath: imagePath),
          ),
        );
        if (editedPath != null) imagePath = editedPath;
      }
    } else if (action == 'edit') {
      // Open image editor with draw/text/color picker
      final editedPath = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => ImageEditorScreen(imagePath: imagePath),
        ),
      );
      if (editedPath != null) {
        imagePath = editedPath;
      }
    }

    if (!mounted) return;

    final file = File(imagePath);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    final ext = p.extension(imagePath).replaceFirst('.', '').toLowerCase();
    final mime = (ext == 'png') ? 'image/png' : 'image/jpeg';

    final mediaPath = await _supabaseService.uploadChatMedia(
      ownerUserId: widget.currentUser['id'],
      bytes: bytes,
      ext: ext.isEmpty ? 'jpg' : ext,
      mime: mime,
    );

    await _supabaseService.sendMessage(
      senderId: widget.currentUser['id'],
      receiverId: widget.otherUser['id'],
      content: '',
      messageType: 'image',
      mediaPath: mediaPath,
      mediaMime: mime,
      mediaSizeBytes: bytes.length,
      replyToId: _replyToMessage?['id'],
      viewOnce: viewOnce,
    );

    setState(() => _replyToMessage = null);
    _forceScrollToBottom();
  }

  Future<void> _pickAndSendVideo({bool viewOnce = false}) async {
    final XFile? picked = await _imagePicker.pickVideo(source: ImageSource.gallery);
    if (picked == null) return;

    final file = File(picked.path);
    final bytes = await file.readAsBytes();
    final ext = p.extension(picked.path).replaceFirst('.', '').toLowerCase();
    const mime = 'video/mp4';

    final mediaPath = await _supabaseService.uploadChatMedia(
      ownerUserId: widget.currentUser['id'],
      bytes: bytes,
      ext: ext.isEmpty ? 'mp4' : ext,
      mime: mime,
    );

    await _supabaseService.sendMessage(
      senderId: widget.currentUser['id'],
      receiverId: widget.otherUser['id'],
      content: '',
      messageType: 'video',
      mediaPath: mediaPath,
      mediaMime: mime,
      mediaSizeBytes: bytes.length,
      replyToId: _replyToMessage?['id'],
      viewOnce: viewOnce,
    );

    setState(() => _replyToMessage = null);
    _forceScrollToBottom();
  }

  Future<void> _pickAndSendFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;

    final platformFile = result.files.first;
    if (platformFile.bytes == null && platformFile.path == null) return;

    List<int> bytes;
    if (platformFile.bytes != null) {
      bytes = platformFile.bytes!;
    } else {
      bytes = await File(platformFile.path!).readAsBytes();
    }

    final fileName = platformFile.name;
    final ext = p.extension(fileName).replaceFirst('.', '').toLowerCase();
    final mime = _getMimeForExt(ext);

    final mediaPath = await _supabaseService.uploadFile(
      ownerUserId: widget.currentUser['id'],
      bytes: bytes,
      fileName: fileName,
      mime: mime,
    );

    await _supabaseService.sendMessage(
      senderId: widget.currentUser['id'],
      receiverId: widget.otherUser['id'],
      content: '',
      messageType: 'file',
      mediaPath: mediaPath,
      mediaMime: mime,
      mediaName: fileName,
      mediaSizeBytes: bytes.length,
      replyToId: _replyToMessage?['id'],
    );

    setState(() => _replyToMessage = null);
    _forceScrollToBottom();
  }

  String _getMimeForExt(String ext) {
    const mimes = {
      'pdf': 'application/pdf',
      'doc': 'application/msword',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint',
      'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'txt': 'text/plain',
      'zip': 'application/zip',
      'mp4': 'video/mp4',
      'mp3': 'audio/mpeg',
    };
    return mimes[ext] ?? 'application/octet-stream';
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      final path = await _recorder.stop();
      setState(() => _isRecording = false);
      if (path == null) return;

      final file = File(path);
      final bytes = await file.readAsBytes();
      final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
      final durationMs = await _probeAudioDurationMs(file);
      const mime = 'audio/mp4';

      final mediaPath = await _supabaseService.uploadChatMedia(
        ownerUserId: widget.currentUser['id'],
        bytes: bytes,
        ext: ext.isEmpty ? 'm4a' : ext,
        mime: mime,
      );

      await _supabaseService.sendMessage(
        senderId: widget.currentUser['id'],
        receiverId: widget.otherUser['id'],
        content: '',
        messageType: 'audio',
        mediaPath: mediaPath,
        mediaMime: mime,
        mediaDurationMs: durationMs,
        mediaSizeBytes: bytes.length,
        replyToId: _replyToMessage?['id'],
      );

      setState(() => _replyToMessage = null);
      _forceScrollToBottom();
      return;
    }

    final hasPerm = await _recorder.hasPermission();
    if (!hasPerm) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission denied')),
        );
      }
      return;
    }

    final dir = await getTemporaryDirectory();
    final filePath = p.join(
      dir.path,
      'voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
    );

    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000, sampleRate: 44100),
      path: filePath,
    );

    setState(() => _isRecording = true);
  }

  Future<int?> _probeAudioDurationMs(File file) async {
    try {
      final tmp = AudioPlayer();
      await tmp.setFilePath(file.path);
      final d = tmp.duration;
      await tmp.dispose();
      return d?.inMilliseconds;
    } catch (_) {
      return null;
    }
  }

  void _syncMessagesToLocal(List<Map<String, dynamic>> messages) {
    for (final m in messages) {
      _localChatStore.upsertFromRemote(
        ownerUserId: widget.currentUser['id'],
        otherUserId: widget.otherUser['id'],
        m: m,
      );
    }
  }

  void _debouncedSyncToLocal(List<Map<String, dynamic>> messages) {
    // Only sync when message count changes (new message) — avoids heavy writes
    // when existing messages update (read receipts, reactions, edits).
    if (messages.length == _lastSyncedCount) return;
    _lastSyncedCount = messages.length;

    _localSyncDebounce?.cancel();
    _localSyncDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _syncMessagesToLocal(messages);
    });
  }

  void _debouncedMarkAsRead(List<Map<String, dynamic>> messages) {
    final myId = widget.currentUser['id'];
    final otherId = widget.otherUser['id'];

    final hasUnread = messages.any((m) {
      if ((m['message_type'] ?? '') == 'deleted') return false;
      return m['receiver_id'] == myId && m['sender_id'] == otherId && m['is_read'] != true;
    });

    if (!hasUnread) return;

    _markReadDebounce?.cancel();
    _markReadDebounce = Timer(const Duration(milliseconds: 400), () {
      // Server + local.
      _supabaseService.markAsRead(myId, otherId);
      _localChatStore.markAllAsRead(ownerUserId: myId, otherUserId: otherId);
    });
  }

  Future<void> _playOrPauseAudio(Map<String, dynamic> message) async {
    final int id = message['id'] as int;

    if (_currentlyPlayingMessageId == id && _audioPlayer.playing) {
      await _audioPlayer.pause();
      setState(() {});
      return;
    }

    final url = await _getSignedUrlForMessage(message);
    if (url == null) return;

    await _audioPlayer.stop();

    if (url.startsWith('/') || url.startsWith('file://')) {
      await _audioPlayer.setFilePath(url.startsWith('file://') ? url.substring(7) : url);
    } else {
      await _audioPlayer.setUrl(url);
    }

    _currentlyPlayingMessageId = id;
    await _audioPlayer.play();
    setState(() {});
  }

  /// ── SMOOTH SCROLL FIX: Smart scroll-to-bottom ──
  /// Only scrolls when:
  /// 1. User is near the bottom (hasn't scrolled up to read old messages)
  /// 2. New messages were added (not just a state update on existing messages)
  ///
  /// Uses smooth animation with easeOutCubic for WhatsApp-like feel.
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && _isNearBottom) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  /// Force-scroll to bottom (used when user sends a message themselves)
  void _forceScrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _startCall(bool isVideo) async {
    final selfId = widget.currentUser['id'] as String;
    final peerId = widget.otherUser['id'] as String;

    await _supabaseService.sendCallSignal(
      toId: peerId,
      type: 'call_offer',
      payload: {'is_video': isVideo},
    );

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen(
          selfId: selfId,
          peerId: peerId,
          isVideo: isVideo,
          isCaller: true,
        ),
      ),
    );
  }

  Future<void> _shareMessage(Map<String, dynamic> message) async {
    final type = (message['message_type'] ?? 'text').toString();
    final content = (message['content'] ?? '').toString();

    if (type == 'text' || type == 'emoji') {
      await SharePlus.instance.share(ShareParams(text: content));
      return;
    }

    final url = await _getSignedUrlForMessage(message);
    if (url == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load media to share')),
        );
      }
      return;
    }

    try {
      String filePath;
      if (url.startsWith('/') || url.startsWith('file://')) {
        filePath = url.startsWith('file://') ? url.substring(7) : url;
      } else {
        final http = await _downloadToTempFile(url, message);
        filePath = http;
      }

      final file = XFile(filePath);
      await SharePlus.instance.share(ShareParams(files: [file], text: content.isNotEmpty ? content : null));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to share: ${e.toString()}')),
        );
      }
    }
  }

  Future<String> _downloadToTempFile(String url, Map<String, dynamic> message) async {
    final dir = await getTemporaryDirectory();
    final mediaName = (message['media_name'] ?? 'shared_file').toString();
    final ext = p.extension(mediaName).isNotEmpty ? p.extension(mediaName) : '.bin';
    final fileName = 'share_${DateTime.now().millisecondsSinceEpoch}$ext';
    final filePath = p.join(dir.path, fileName);

    final localFile = File(url.startsWith('file://') ? url.substring(7) : url);
    if (await localFile.exists()) {
      return localFile.path;
    }

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final sink = File(filePath).openWrite();
      await response.pipe(sink);
      await sink.flush();
      await sink.close();
      return filePath;
    } finally {
      client.close();
    }
  }

  Future<void> _exportChatAsTxt() async {
    try {
      final otherDisplayName = (widget.otherUser['display_name'] ?? widget.otherUser['username'] ?? 'User').toString();
      final txtContent = await _supabaseService.exportChatAsTxt(
        currentUserId: widget.currentUser['id'],
        otherUserId: widget.otherUser['id'],
        otherDisplayName: otherDisplayName,
      );

      final dir = await getTemporaryDirectory();
      final safeName = otherDisplayName.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
      final fileName = 'chat_${safeName}_${DateTime.now().millisecondsSinceEpoch}.txt';
      final filePath = p.join(dir.path, fileName);
      await File(filePath).writeAsString(txtContent);

      final file = XFile(filePath);
      await SharePlus.instance.share(ShareParams(
        files: [file],
        text: 'CDN-NETCHAT Chat with $otherDisplayName',
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: ${e.toString()}')),
        );
      }
    }
  }

  void _showMessageOptions(Map<String, dynamic> message, bool isMe) {
    final isDeleted = (message['message_type'] ?? '') == 'deleted';
    final isPinned = message['is_pinned'] == true;
    final isStarred = message['is_starred'] == true;

    // Check if within 20min edit window
    final createdAt = DateTime.tryParse((message['created_at'] ?? '').toString());
    final canEdit = isMe && !isDeleted && createdAt != null &&
        DateTime.now().difference(createdAt).inMinutes <= 20;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F2027),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            Container(
              width: 40, height: 4, margin: const EdgeInsets.only(top: 12),
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(999)),
            ),
            const SizedBox(height: 12),
            if (!isDeleted) ...[
              ListTile(
                leading: const Icon(Icons.reply_rounded, color: Colors.white70),
                title: Text('Reply', style: GoogleFonts.poppins(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _replyToMessage = message);
                },
              ),
              if (canEdit)
                ListTile(
                  leading: const Icon(Icons.edit_rounded, color: Color(0xFF2AABEE)),
                  title: Text('Edit', style: GoogleFonts.poppins(color: Colors.white)),
                  subtitle: Text('Within 20 min window', style: GoogleFonts.poppins(color: Colors.white38, fontSize: 11)),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _editingMessage = message;
                      _messageController.text = (message['content'] ?? '').toString();
                    });
                    _messageController.selection = TextSelection.collapsed(offset: _messageController.text.length);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.copy_rounded, color: Colors.white70),
                title: Text('Copy', style: GoogleFonts.poppins(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: (message['content'] ?? '').toString()));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied to clipboard')),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.share_rounded, color: Colors.white70),
                title: Text('Share', style: GoogleFonts.poppins(color: Colors.white)),
                onTap: () { Navigator.pop(ctx); _shareMessage(message); },
              ),
              ListTile(
                leading: Icon(isPinned ? Icons.push_pin : Icons.push_pin_outlined, color: Colors.white70),
                title: Text(isPinned ? 'Unpin' : 'Pin', style: GoogleFonts.poppins(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _supabaseService.pinMessage(messageId: message['id'], pinned: !isPinned);
                },
              ),
              ListTile(
                leading: Icon(isStarred ? Icons.star_rounded : Icons.star_outline_rounded, color: Colors.amber),
                title: Text(isStarred ? 'Unstar' : 'Star', style: GoogleFonts.poppins(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _supabaseService.starMessage(messageId: message['id'], starred: !isStarred);
                },
              ),
              // Forward
              ListTile(
                leading: const Icon(Icons.shortcut_rounded, color: Colors.white70),
                title: Text('Forward', style: GoogleFonts.poppins(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showForwardDialog(message);
                },
              ),
              // Reactions
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: ['❤️', '😂', '😮', '😢', '👍', '👎'].map((emoji) {
                    return GestureDetector(
                      onTap: () async {
                        Navigator.pop(ctx);
                        await _supabaseService.setReaction(messageId: message['id'], emoji: emoji);
                      },
                      child: Text(emoji, style: const TextStyle(fontSize: 28)),
                    );
                  }).toList(),
                ),
              ),
              const Divider(color: Colors.white12),
            ],
            if (isMe && !isDeleted)
              ListTile(
                leading: const Icon(Icons.delete_forever_rounded, color: Colors.redAccent),
                title: Text('Delete for everyone', style: GoogleFonts.poppins(color: Colors.redAccent)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _supabaseService.deleteMessageForEveryone(messageId: message['id']);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: Colors.orangeAccent),
              title: Text('Delete for me', style: GoogleFonts.poppins(color: Colors.orangeAccent)),
              onTap: () async {
                Navigator.pop(ctx);
                await _supabaseService.deleteMessageForMe(
                  messageId: message['id'],
                  iAmSender: isMe,
                );
              },
            ),
            ],
          ),
        ),
      ),
    );
  }

  void _showForwardDialog(Map<String, dynamic> message) async {
    try {
      final threads = await _supabaseService.getChatThreads();
      if (!mounted) return;

      showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF0F2027),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 40, height: 4, margin: const EdgeInsets.only(top: 12),
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(999))),
              const SizedBox(height: 12),
              Text('Forward to...', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: threads.map((t) {
                    final name = (t['other_display_name'] ?? t['other_username'] ?? 'User').toString();
                    return ListTile(
                      leading: CircleAvatar(backgroundColor: const Color(0xFF6366F1), child: Text(name[0], style: const TextStyle(color: Colors.white))),
                      title: Text(name, style: GoogleFonts.poppins(color: Colors.white)),
                      onTap: () async {
                        Navigator.pop(ctx);
                        final content = (message['content'] ?? '').toString();
                        final type = (message['message_type'] ?? 'text').toString();
                        await _supabaseService.sendMessage(
                          senderId: widget.currentUser['id'],
                          receiverId: t['other_user_id'],
                          content: content,
                          messageType: type,
                          isForwarded: true,
                          forwardedFromId: message['sender_id'],
                        );
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Message forwarded'), backgroundColor: Colors.green),
                          );
                        }
                      },
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      );
    } catch (_) {}
  }

  void _showPrivacySettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F2027),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        bool hideLastSeen = _otherHideLastSeen;
        bool hideReadReceipts = _myHideReadReceipts;

        return StatefulBuilder(
          builder: (ctx, setModalState) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40, height: 4,
                    decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(999)),
                  ),
                  const SizedBox(height: 14),
                  Text('Privacy Settings', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                  const SizedBox(height: 20),
                  SwitchListTile(
                    value: hideLastSeen,
                    onChanged: (v) async {
                      await _supabaseService.updatePrivacySettings(hideLastSeen: v);
                      setModalState(() => hideLastSeen = v);
                      if (mounted) setState(() => _otherHideLastSeen = v);
                    },
                    title: Text('Hide Last Seen', style: GoogleFonts.poppins(color: Colors.white)),
                    subtitle: Text('Others won\'t see when you were last online', style: GoogleFonts.poppins(color: Colors.white54, fontSize: 12)),
                    activeColor: const Color(0xFF6366F1),
                  ),
                  SwitchListTile(
                    value: hideReadReceipts,
                    onChanged: (v) async {
                      await _supabaseService.updatePrivacySettings(hideReadReceipts: v);
                      setModalState(() => hideReadReceipts = v);
                      if (mounted) setState(() => _myHideReadReceipts = v);
                    },
                    title: Text('Hide Read Receipts', style: GoogleFonts.poppins(color: Colors.white)),
                    subtitle: Text('Others won\'t see if you read their messages', style: GoogleFonts.poppins(color: Colors.white54, fontSize: 12)),
                    activeColor: const Color(0xFF6366F1),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // [UPDATE 2026-06-10-P5] Use theme-aware background color
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lightMode = !isDark;
    final bgColor = Theme.of(context).scaffoldBackgroundColor;
    final textColor = isDark ? Colors.white : Colors.black87;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
        titleTextStyle: GoogleFonts.poppins(color: textColor, fontSize: 16, fontWeight: FontWeight.bold),
        title: Row(
          children: [
            CircleAvatar(
              backgroundColor: const Color(0xFF6366F1),
              child: Text(((widget.otherUser['display_name'] ?? widget.otherUser['username']) as String)[0]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StreamBuilder<Map<String, dynamic>>(
                stream: _supabaseService.streamProfile(widget.otherUser['id']),
                builder: (context, snapshot) {
                  String status = 'Offline';
                  Color statusColor = Colors.redAccent;

                  if (snapshot.hasData) {
                    final otherHideLastSeen = snapshot.data?['hide_last_seen'] == true;
                    final lastSeen = DateTime.tryParse((snapshot.data?['last_seen'] ?? '').toString());
                    final now = DateTime.now();

                    if (otherHideLastSeen) {
                      // User hides last seen - just show Online/Offline without timestamp
                      if (lastSeen != null && now.difference(lastSeen).inMinutes < 2) {
                        status = 'Online';
                        statusColor = Colors.greenAccent;
                      } else {
                        status = 'Offline';
                        statusColor = Colors.redAccent;
                      }
                    } else if (lastSeen != null) {
                      // User shows last seen - show exact time
                      if (now.difference(lastSeen).inMinutes < 2) {
                        status = 'Online';
                        statusColor = Colors.greenAccent;
                      } else {
                        status = 'Last seen ${_formatLastSeen(lastSeen)}';
                        statusColor = Colors.white54;
                      }
                    }
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (widget.otherUser['display_name'] ?? widget.otherUser['username']) as String,
                        style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _isTyping ? 'Typing...' : status,
                          style: TextStyle(
                            fontSize: 12,
                            color: _isTyping ? Colors.redAccent : statusColor,
                          ),
                          maxLines: 1,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
        // [UPDATE 2026-06-08-P2] Call/Video buttons VISIBLE on top-right (WhatsApp-style)
        actions: [
          IconButton(
            icon: Icon(Icons.videocam_rounded, color: textColor.withOpacity(0.7)),
            tooltip: 'Video call',
            onPressed: () => _startCall(true),
          ),
          IconButton(
            icon: Icon(Icons.call_rounded, color: textColor.withOpacity(0.7)),
            tooltip: 'Voice call',
            onPressed: () => _startCall(false),
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert_rounded, color: textColor),
            color: const Color(0xFF203A43),
            onSelected: (val) {
              if (val == 'search') _showChatSearch();
              if (val == 'jump_date') _showJumpToDate();
              if (val == 'privacy') _showPrivacySettings();
              if (val == 'privacy') _showPrivacySettings();
              if (val == 'export_txt') _exportChatAsTxt();
              if (val == 'wallpaper') _pickAndSetWallpaper();
              if (val == 'clear_wallpaper') _clearWallpaper();
              if (val == 'rich_text') {
                setState(() => _showRichTextToolbar = !_showRichTextToolbar);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'search',
                child: Row(
                  children: const [
                    Icon(Icons.search_rounded, color: Colors.white70, size: 20),
                    SizedBox(width: 10),
                    Text('Search', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'jump_date',
                child: Row(
                  children: const [
                    Icon(Icons.calendar_month_rounded, color: Colors.white70, size: 20),
                    SizedBox(width: 10),
                    Text('Jump to date', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'rich_text',
                child: Row(
                  children: [
                    Icon(Icons.format_size_rounded,
                        color: _showRichTextToolbar ? const Color(0xFF6366F1) : Colors.white70, size: 20),
                    const SizedBox(width: 10),
                    Text(_showRichTextToolbar ? 'Hide Formatting' : 'Text Formatting',
                        style: const TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              const PopupMenuItem(value: 'wallpaper', child: Text('Set Wallpaper', style: TextStyle(color: Colors.white))),
              const PopupMenuItem(value: 'clear_wallpaper', child: Text('Clear Wallpaper', style: TextStyle(color: Colors.white))),
              const PopupMenuItem(value: 'export_txt', child: Text('Export Chat as TXT', style: TextStyle(color: Colors.white))),
              const PopupMenuItem(value: 'privacy', child: Text('Privacy Settings', style: TextStyle(color: Colors.white))),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_wallpaperPath != null && File(_wallpaperPath!).existsSync())
            Positioned.fill(
              child: Image.file(File(_wallpaperPath!), fit: BoxFit.cover),
            ),
          Positioned.fill(child: Container(color: lightMode ? Colors.white.withOpacity(0.85) : Colors.black.withOpacity(0.25))),
          Column(
            children: [
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _supabaseService.getMessages(
                widget.currentUser['id'],
                widget.otherUser['id'],
              ),
              builder: (context, snapshot) {
                // ── WHATSAPP-LIKE: Merge local pending messages with remote messages ──
                // Local pending messages appear INSTANTLY, even before Supabase confirms.
                List<Map<String, dynamic>> messages;
                if (snapshot.hasData && snapshot.data!.isNotEmpty) {
                  messages = snapshot.data!;
                  // Remove duplicates (local pending that have arrived via stream)
                  final remoteIds = messages.map((m) => m['id']).toSet();
                  _localPendingMessages = _localPendingMessages
                      .where((m) => !remoteIds.contains(m['id']))
                      .toList();
                } else {
                  messages = [];
                }
                // Prepend local pending messages (newest last for correct order)
                if (_localPendingMessages.isNotEmpty) {
                  messages = [...messages, ..._localPendingMessages];
                }

                if (!snapshot.hasData && messages.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }

                _latestMessages = messages;

                // Compute pinned from the SAME snapshot to avoid extra stream rebuilds.
                final pinned = messages
                    .where((m) => m['is_pinned'] == true && (m['message_type'] ?? '') != 'deleted')
                    .toList();

                // Reduce lag: debounce expensive operations.
                _debouncedMarkAsRead(messages);
                _debouncedSyncToLocal(messages);

                // Only auto-scroll when NEW messages arrive.
                if (messages.length > _previousMessageCount) {
                  _previousMessageCount = messages.length;
                  _scrollToBottom();
                }

                return Column(
                  children: [
                    if (pinned.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF6366F1).withOpacity(0.15),
                          border: Border(bottom: BorderSide(color: const Color(0xFF6366F1).withOpacity(0.3))),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.push_pin, color: Colors.amber, size: 16),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '📌 ${pinned.length} pinned message${pinned.length > 1 ? 's' : ''}',
                                style: GoogleFonts.poppins(color: Colors.amber, fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(16),
                  // ── SMOOTH SCROLL: physics for buttery-smooth scrolling ──
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  // ── SMOOTH SCROLL: cache extent for pre-building off-screen items ──
                  cacheExtent: 500,
                  itemCount: messages.length,
                  // [UPDATE 2026-06-08] Optimized itemBuilder with RepaintBoundary
                  // for zero-lag scrolling — each message bubble renders independently
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    final isMe = message['sender_id'] == widget.currentUser['id'];

                    final createdAt = DateTime.tryParse((message['created_at'] ?? '').toString())?.toLocal();
                    DateTime? prevCreatedAt;
                    if (index > 0) {
                      prevCreatedAt = DateTime.tryParse((messages[index - 1]['created_at'] ?? '').toString())?.toLocal();
                    }

                    final showDateHeader = createdAt != null &&
                        (index == 0 || prevCreatedAt == null || !_isSameDay(createdAt, prevCreatedAt));

                    Widget bubble = _buildMessageBubble(message, isMe, messages);

                    // ── SMOOTH SCROLL: Wrap each bubble in RepaintBoundary so
                    // only changed items repaint, not the entire list ──
                    bubble = RepaintBoundary(child: bubble);

                    if (!showDateHeader) return bubble;

                    final dayKey = _dayKey(createdAt!);
                    final headerKey = _dateHeaderKeys.putIfAbsent(dayKey, () => GlobalKey());

                    return RepaintBoundary(
                      child: Column(
                        children: [
                          _buildDateHeader(createdAt, key: headerKey),
                          bubble,
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          );
              },
            ),
          ),
          if (_replyToMessage != null) _buildReplyPreview(),
          if (_editingMessage != null) _buildEditPreview(),
          _buildMessageInput(),
        ],
          ),
        ],
      ),
    );
  }

  /// [UPDATE 2026-06-08] Removed duplicate StreamBuilder — pinned messages
  /// are now rendered inline in the main message list builder to avoid
  /// double-stream lag.

  Widget _buildReplyPreview() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.white.withOpacity(0.05),
      child: Row(
        children: [
          Container(
            width: 3, height: 36,
            decoration: BoxDecoration(color: const Color(0xFF6366F1), borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _replyToMessage!['sender_id'] == widget.currentUser['id'] ? 'You' : (widget.otherUser['display_name'] ?? 'User'),
                  style: GoogleFonts.poppins(color: const Color(0xFF6366F1), fontSize: 12, fontWeight: FontWeight.w600),
                ),
                Text(
                  (_replyToMessage!['content'] ?? '').toString().isEmpty
                      ? '[Media]'
                      : (_replyToMessage!['content'] ?? '').toString(),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, color: Colors.white38, size: 18),
            onPressed: () => setState(() => _replyToMessage = null),
          ),
        ],
      ),
    );
  }

  Widget _buildEditPreview() {
    final createdAt = DateTime.tryParse((_editingMessage!['created_at'] ?? '').toString());
    final remaining = createdAt != null ? 20 - DateTime.now().difference(createdAt).inMinutes : 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: const Color(0xFF2AABEE).withOpacity(0.1),
      child: Row(
        children: [
          Container(
            width: 3, height: 36,
            decoration: BoxDecoration(color: const Color(0xFF2AABEE), borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Editing message',
                  style: GoogleFonts.poppins(color: const Color(0xFF2AABEE), fontSize: 12, fontWeight: FontWeight.w600),
                ),
                Text(
                  '${remaining > 0 ? remaining : 0} min remaining to edit',
                  style: GoogleFonts.poppins(color: Colors.white54, fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, color: Colors.white38, size: 18),
            onPressed: () {
              setState(() {
                _editingMessage = null;
                _messageController.clear();
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(Map<String, dynamic> message, bool isMe, List<Map<String, dynamic>> allMessages) {
    final type = (message['message_type'] ?? 'text').toString();
    final isDeleted = type == 'deleted';
    final isEmoji = type == 'emoji';

    // Check if deleted for me
    final deletedForMe = isMe
        ? (message['deleted_for_sender'] == true)
        : (message['deleted_for_receiver'] == true);
    if (deletedForMe && !isDeleted) return const SizedBox.shrink();

    // Check reply to
    final replyToId = message['reply_to_id'];
    Map<String, dynamic>? replyToMsg;
    if (replyToId != null) {
      try {
        replyToMsg = allMessages.firstWhere((m) => m['id'] == replyToId);
      } catch (_) {}
    }

    // Parse reactions
    Map<String, dynamic> reactions = {};
    if (message['reactions'] != null) {
      try {
        if (message['reactions'] is Map) {
          reactions = Map<String, dynamic>.from(message['reactions'] as Map);
        } else if (message['reactions'] is String) {
          reactions = Map<String, dynamic>.from(jsonDecode(message['reactions'] as String));
        }
      } catch (_) {}
    }

    final isPinned = message['is_pinned'] == true;
    final isForwarded = message['is_forwarded'] == true;
    final isViewOnce = message['view_once'] == true;
    final isStarred = message['is_starred'] == true;
    final isEmojiOnly = isEmoji || (type == 'text' && _isOnlyEmoji((message['content'] ?? '').toString()));

    // Rich text
    final isRichText = message['is_rich_text'] == true;
    final richTextJson = (message['rich_text_json'] ?? '').toString();

    // View-once: check if already viewed
    final viewedBySender = message['viewed_by_sender'] == true;
    final viewedByReceiver = message['viewed_by_receiver'] == true;
    final isViewOnceViewed = isMe ? viewedBySender : viewedByReceiver;

    // Check media expiry
    final mediaExpiresAt = message['media_expires_at'];
    final isMediaExpired = mediaExpiresAt != null &&
        DateTime.tryParse(mediaExpiresAt.toString())?.isBefore(DateTime.now()) == true;

    final bool lightMode = Theme.of(context).brightness == Brightness.light;

    final myBubbleGradient = lightMode
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFD9FDD3),
              Color(0xFFD9FDD3),
            ],
          )
        : LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF075E54),
              Color(0xFF054D44),
            ],
          );

    final bubbleRadius = BorderRadius.circular(22).copyWith(
      bottomRight: isMe ? const Radius.circular(6) : const Radius.circular(22),
      bottomLeft: isMe ? const Radius.circular(22) : const Radius.circular(6),
    );

    final replyBg = isMe
        ? Colors.white.withOpacity(0.10)
        : (lightMode ? Colors.black.withOpacity(0.05) : Colors.white.withOpacity(0.10));
final replyTextColor = isMe
        ? Colors.white54
        : (lightMode ? Colors.grey.shade600 : Colors.white54);
final tsColor = isMe
        ? Colors.white60
        : (lightMode ? Colors.grey.shade500 : Colors.white54);
final editedColor = isMe
        ? Colors.white38
        : (lightMode ? Colors.grey.shade400 : Colors.white24);

    Widget bubbleContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Reply reference
        if (replyToMsg != null) ...[
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: replyBg,
              borderRadius: BorderRadius.circular(10),
              border: Border(left: BorderSide(color: const Color(0xFF2AABEE), width: 3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  replyToMsg['sender_id'] == widget.currentUser['id'] ? 'You' : (widget.otherUser['display_name'] ?? 'User'),
                  style: GoogleFonts.poppins(color: const Color(0xFF2AABEE), fontSize: 11, fontWeight: FontWeight.w600),
                ),
                Text(
                  (replyToMsg['content'] ?? '').toString().isEmpty ? '[Media]' : (replyToMsg['content'] ?? '').toString(),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(color: replyTextColor, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],

        // View-once indicator
        if (isViewOnce && !isDeleted)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.visibility_rounded,
                  color: isMe ? Colors.white38.withOpacity(0.7) : (lightMode ? Colors.grey.shade400 : Colors.white38.withOpacity(0.7)),
                  size: 12),
                const SizedBox(width: 4),
                Text('View once',
                  style: GoogleFonts.poppins(
                    color: isMe ? Colors.white38 : (lightMode ? Colors.grey.shade500 : Colors.white38),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),

        if (isDeleted)
          Text(
            'This message was deleted',
            style: TextStyle(color: isMe ? Colors.white38 : (lightMode ? Colors.grey.shade400 : Colors.white38), fontSize: 14, fontStyle: FontStyle.italic),
          )
        else if (isEmojiOnly)
          Text(
            (message['content'] ?? '').toString(),
            style: const TextStyle(fontSize: 48),
            textAlign: TextAlign.center,
          )
        else if (type == 'text')
          // Rich text or plain text
          isRichText && richTextJson.isNotEmpty
              ? RichText(
                  text: TextSpan(
                    style: TextStyle(color: isMe ? Colors.white : (lightMode ? Colors.black87 : Colors.white)),
                    children: RichTextEditor.buildTextSpans(
                      RichTextEditor.parseRichText(richTextJson),
                    ),
                  ),
                )
              : _buildPlainTextWithFormatting((message['content'] ?? '').toString(), isMe: isMe, lightMode: lightMode)
        else if (type == 'image')
          isMediaExpired
              ? _buildExpiredMedia()
              : isViewOnce && isViewOnceViewed && !isMe
                  ? _buildViewOnceExpired()
                  : _buildImageMessage(message)
        else if (type == 'video')
          isMediaExpired
              ? _buildExpiredMedia()
              : isViewOnce && isViewOnceViewed && !isMe
                  ? _buildViewOnceExpired()
                  : _buildVideoMessage(message)
        else if (type == 'audio')
          _buildAudioMessage(message)
        else if (type == 'file')
          isMediaExpired
              ? _buildExpiredFile()
              : _buildFileMessage(message)
        else
          Text(
            (message['content'] ?? '').toString(),
            style: TextStyle(color: isMe ? Colors.white : (lightMode ? Colors.black87 : Colors.white), fontSize: 15),
          ),

        if (!isDeleted && !isEmojiOnly) ...[
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message['edited_at'] != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text('edited', style: TextStyle(color: editedColor, fontSize: 10, fontStyle: FontStyle.italic)),
                ),
              Text(
                _formatTime(DateTime.parse(message['created_at'])),
                style: TextStyle(color: tsColor, fontSize: 11),
              ),
              if (!isMe) ...[
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: () => _supabaseService.toggleLike(message['id'], !(message['is_liked'] ?? false)),
                  child: Icon(
                    message['is_liked'] == true ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                    color: message['is_liked'] == true ? Colors.redAccent : (lightMode ? Colors.grey.shade400 : Colors.white38),
                    size: 18,
                  ),
                ),
              ],
              if (isMe) ...[
                const SizedBox(width: 8),
                Icon(
                  _myHideReadReceipts ? Icons.done_rounded : Icons.done_all_rounded,
                  size: 14,
                  color: (!_myHideReadReceipts && message['is_read'] == true)
                      ? const Color(0xFF2AABEE)
                      : Colors.white38,
                ),
              ],
            ],
          ),
        ],
      ],
    );

    final bubbleWidget = isEmojiOnly
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: bubbleContent,
          )
        : (isMe
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  gradient: myBubbleGradient,
                  borderRadius: bubbleRadius,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF2AABEE).withOpacity(0.22),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: bubbleContent,
              )
            : Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: lightMode ? Colors.white : const Color(0xFF1F2C33),
                  borderRadius: bubbleRadius,
                  boxShadow: lightMode
                      ? [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.06),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ]
                      : [
                          BoxShadow(
                            color: const Color(0xFF2AABEE).withOpacity(0.12),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ],
                ),
                child: bubbleContent,
              ));

    return Dismissible(
      key: ValueKey(message['id']),
      direction: DismissDirection.startToEnd,
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          setState(() => _replyToMessage = message);
        }
        return false;
      },
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        child: const Icon(Icons.reply_rounded, color: Colors.white38, size: 28),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => _showMessageOptions(message, isMe),
        onTap: () {
          // View-once: mark as viewed on tap
          if (isViewOnce && !isViewOnceViewed && !isMe) {
            _supabaseService.markViewOnceViewed(messageId: message['id'], iAmSender: false);
          }
        },
        child: Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            constraints: BoxConstraints(
              maxWidth: isEmojiOnly ? MediaQuery.of(context).size.width * 0.9
                  : MediaQuery.of(context).size.width * 0.75,
            ),
            child: Column(
              crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                // Forwarded label
                if (isForwarded && !isDeleted)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2, left: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.shortcut_rounded,
                          color: isMe ? Colors.white38.withOpacity(0.6) : (lightMode ? Colors.grey.shade400 : Colors.white38.withOpacity(0.6)),
                          size: 12),
                        const SizedBox(width: 4),
                        Text('Forwarded',
                          style: GoogleFonts.poppins(
                            color: isMe ? Colors.white38 : (lightMode ? Colors.grey.shade500 : Colors.white38),
                            fontSize: 10, fontStyle: FontStyle.italic
                          ),
                        ),
                      ],
                    ),
                  ),
                // Pinned indicator
                if (isPinned)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.push_pin, color: Colors.amber.withOpacity(0.8), size: 12),
                        const SizedBox(width: 4),
                        Text('Pinned', style: GoogleFonts.poppins(color: Colors.amber.withOpacity(0.8), fontSize: 10)),
                      ],
                    ),
                  ),
                // Star indicator
                if (isStarred && !isDeleted)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.star_rounded, color: Colors.amber.withOpacity(0.8), size: 12),
                        const SizedBox(width: 4),
                        Text('Starred', style: GoogleFonts.poppins(color: Colors.amber.withOpacity(0.8), fontSize: 10)),
                      ],
                    ),
                  ),
                bubbleWidget,
                // Reactions display
                if (reactions.isNotEmpty && !isDeleted)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Wrap(
                      spacing: 4,
                      children: reactions.entries.map((e) {
                        final isMyReaction = e.key == widget.currentUser['id'];
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: isMyReaction ? const Color(0xFF6366F1).withOpacity(0.3) : Colors.white.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isMyReaction ? const Color(0xFF6366F1).withOpacity(0.5) : Colors.white12,
                            ),
                          ),
                          child: Text(e.value.toString(), style: const TextStyle(fontSize: 16)),
                        );
                      }).toList(),
                    ),
                  ),
                if (isMe && message['is_liked'] == true && !isDeleted)
                  const Padding(
                    padding: EdgeInsets.only(top: 2, right: 5),
                    child: Icon(Icons.favorite_rounded, color: Colors.redAccent, size: 12),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Parse and render text with *bold*, _italic_, ~strikethrough~
  Widget _buildPlainTextWithFormatting(String text, {bool isMe = true, bool lightMode = false}) {
    final textColor = isMe
        ? Colors.white
        : (lightMode ? Colors.black87 : Colors.white);
    if (!RichTextEditor.hasFormatting(text)) {
      return Text(text, style: TextStyle(color: textColor, fontSize: 15));
    }

    final segments = RichTextEditor.parseMarkdownToSegments(text);
    return RichText(
      text: TextSpan(
        style: TextStyle(color: textColor, fontSize: 15),
        children: RichTextEditor.buildTextSpans(segments),
      ),
    );
  }

  Widget _buildExpiredMedia() => Container(
    width: 220, height: 120,
    decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(14)),
    child: const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.timer_off_rounded, color: Colors.white38, size: 32),
      SizedBox(height: 8),
      Text('Media expired', style: TextStyle(color: Colors.white38, fontSize: 12)),
    ])),
  );

  Widget _buildExpiredFile() => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(12)),
    child: const Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.timer_off_rounded, color: Colors.white38, size: 36),
      SizedBox(width: 10),
      Text('File expired', style: TextStyle(color: Colors.white38, fontSize: 14)),
    ]),
  );

  Widget _buildViewOnceExpired() => Container(
    width: 220, height: 120,
    decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(14)),
    child: const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.visibility_off_rounded, color: Colors.white38, size: 32),
      SizedBox(height: 8),
      Text('View-once media viewed', style: TextStyle(color: Colors.white38, fontSize: 12)),
    ])),
  );

  Widget _buildImageMessage(Map<String, dynamic> message) {
    return FutureBuilder<String?>(
      future: _getSignedUrlForMessage(message),
      builder: (context, snapshot) {
        final url = snapshot.data;
        if (url == null) {
          return const SizedBox(
            width: 180, height: 180,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }

        // Make image tappable to view fullscreen
        return GestureDetector(
          onTap: () {
            String? filePath;
            if (url.startsWith('/') || url.startsWith('file://')) {
              filePath = url.startsWith('file://') ? url.substring(7) : url;
            }
            FullScreenImageViewer.open(
              context,
              imageUrl: url,
              filePath: filePath,
            );
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: url.startsWith('/') || url.startsWith('file://')
                ? Image.file(
                    File(url.startsWith('file://') ? url.substring(7) : url),
                    width: 220, height: 220, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 220, height: 220,
                      color: Colors.white.withOpacity(0.08),
                      child: const Center(child: Icon(Icons.broken_image_rounded, color: Colors.white54)),
                    ),
                  )
                : CachedNetworkImage(
                    imageUrl: url,
                    width: 220, height: 220, fit: BoxFit.cover,
                    placeholder: (context, _) => Container(
                      width: 220, height: 220,
                      color: Colors.white.withOpacity(0.08),
                      child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                    errorWidget: (context, _, __) => Container(
                      width: 220, height: 220,
                      color: Colors.white.withOpacity(0.08),
                      child: const Center(child: Icon(Icons.broken_image_rounded, color: Colors.white54)),
                    ),
                  ),
          ),
        );
      },
    );
  }

  Widget _buildVideoMessage(Map<String, dynamic> message) {
    return Container(
      width: 220, height: 160,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.videocam_rounded, color: Colors.white, size: 40),
          const SizedBox(height: 8),
          Text('Video', style: GoogleFonts.poppins(color: Colors.white, fontSize: 13)),
          if (message['media_size_bytes'] != null)
            Text(_formatBytes(message['media_size_bytes'] as int), style: GoogleFonts.poppins(color: Colors.white54, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildAudioMessage(Map<String, dynamic> message) {
    final int id = message['id'] as int;
    final bool isPlaying = _currentlyPlayingMessageId == id && _audioPlayer.playing;
    final durationMs = message['media_duration_ms'] as int?;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: () => _playOrPauseAudio(message),
          icon: Icon(isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
              color: Colors.white, size: 34),
        ),
        const SizedBox(width: 8),
        Text(
          durationMs == null ? 'Voice note' : _formatDurationMs(durationMs),
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
      ],
    );
  }

  Widget _buildFileMessage(Map<String, dynamic> message) {
    final fileName = (message['media_name'] ?? 'File').toString();
    final fileSize = message['media_size_bytes'] as int?;
    final mime = (message['media_mime'] ?? '').toString();
    final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';

    // Different icons and colors for different file types (WhatsApp-like shiny style)
    IconData fileIcon = Icons.insert_drive_file_rounded;
    Color iconColor = const Color(0xFF6366F1); // Default indigo
    Color bgColor = const Color(0xFF6366F1).withOpacity(0.15);

    if (mime.contains('pdf') || ext == 'pdf') {
      fileIcon = Icons.picture_as_pdf_rounded;
      iconColor = Colors.redAccent;
      bgColor = Colors.redAccent.withOpacity(0.15);
    } else if (mime.contains('zip') || mime.contains('rar') || mime.contains('7z') || mime.contains('compressed') || ['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) {
      fileIcon = Icons.folder_zip_rounded;
      iconColor = Colors.orangeAccent;
      bgColor = Colors.orangeAccent.withOpacity(0.15);
    } else if (mime.contains('android') || mime.contains('apk') || ext == 'apk') {
      fileIcon = Icons.android_rounded;
      iconColor = Colors.greenAccent;
      bgColor = Colors.greenAccent.withOpacity(0.15);
    } else if (mime.contains('word') || mime.contains('doc') || ['doc', 'docx'].contains(ext)) {
      fileIcon = Icons.description_rounded;
      iconColor = const Color(0xFF2B7CD3);
      bgColor = const Color(0xFF2B7CD3).withOpacity(0.15);
    } else if (mime.contains('sheet') || mime.contains('xls') || ['xls', 'xlsx', 'csv'].contains(ext)) {
      fileIcon = Icons.table_chart_rounded;
      iconColor = Colors.green;
      bgColor = Colors.green.withOpacity(0.15);
    } else if (mime.contains('presentation') || mime.contains('ppt') || ['ppt', 'pptx'].contains(ext)) {
      fileIcon = Icons.slideshow_rounded;
      iconColor = Colors.deepOrange;
      bgColor = Colors.deepOrange.withOpacity(0.15);
    } else if (mime.contains('text') || ['txt', 'md', 'log'].contains(ext)) {
      fileIcon = Icons.article_rounded;
      iconColor = Colors.grey;
      bgColor = Colors.grey.withOpacity(0.15);
    } else if (mime.contains('image') || ['jpg', 'jpeg', 'png', 'gif', 'webp', 'svg'].contains(ext)) {
      fileIcon = Icons.image_rounded;
      iconColor = const Color(0xFF2AABEE);
      bgColor = const Color(0xFF2AABEE).withOpacity(0.15);
    } else if (mime.contains('video') || ['mp4', 'mkv', 'avi', 'mov'].contains(ext)) {
      fileIcon = Icons.videocam_rounded;
      iconColor = Colors.purpleAccent;
      bgColor = Colors.purpleAccent.withOpacity(0.15);
    } else if (mime.contains('audio') || ['mp3', 'wav', 'flac', 'aac', 'ogg'].contains(ext)) {
      fileIcon = Icons.audiotrack_rounded;
      iconColor = Colors.pinkAccent;
      bgColor = Colors.pinkAccent.withOpacity(0.15);
    }

    return GestureDetector(
      onTap: () => _openFileWith(message),
      child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: iconColor.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(fileIcon, color: iconColor, size: 32),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fileName, style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: iconColor.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(ext.toUpperCase(), style: GoogleFonts.poppins(color: iconColor, fontSize: 9, fontWeight: FontWeight.w700)),
                    ),
                    if (fileSize != null) ...[
                      const SizedBox(width: 6),
                      Text(_formatBytes(fileSize), style: GoogleFonts.poppins(color: Colors.white54, fontSize: 11)),
                    ],
                      const SizedBox(width: 6),
                      Icon(Icons.open_in_new_rounded, color: iconColor.withOpacity(0.5), size: 12),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  /// Open a file with external apps that can handle that file type.
  Future<void> _openFileWith(Map<String, dynamic> message) async {
    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                SizedBox(width: 12),
                Text('Opening file...'),
              ],
            ),
            duration: Duration(seconds: 10),
            backgroundColor: Color(0xFF6366F1),
          ),
        );
      }

      final url = await _getSignedUrlForMessage(message);
      if (url == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not load file'), backgroundColor: Colors.redAccent),
          );
        }
        return;
      }

      String localPath;
      if (url.startsWith('/') || url.startsWith('file://')) {
        localPath = url.startsWith('file://') ? url.substring(7) : url;
      } else {
        localPath = await _downloadToTempFile(url, message);
      }

      final file = File(localPath);
      if (!await file.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('File not found'), backgroundColor: Colors.redAccent),
          );
        }
        return;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
      }

      final result = await OpenFilex.open(localPath);
      final fileName = (message['media_name'] ?? '').toString();
      final ext = fileName.contains('.') ? fileName.split('.').last : 'unknown';
      
      if (mounted && result.type != ResultType.done) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No app found to open .$ext files'),
            backgroundColor: Colors.orangeAccent,
            action: SnackBarAction(
              label: 'Share instead',
              onPressed: () => _shareMessage(message),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to open file'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(1)} MB';
  }

  String _formatDurationMs(int ms) {
    final s = (ms / 1000).round();
    final m = s ~/ 60;
    final r = s % 60;
    return m > 0 ? '${m}m ${r}s' : '${r}s';
  }

  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String _formatLastSeen(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);
    if (difference.inMinutes < 60) return '${difference.inMinutes}m ago';
    if (difference.inHours < 24) return '${difference.inHours}h ago';
    return '${difference.inDays}d ago';
  }

  Widget _buildMessageInput() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inputBg = isDark ? Colors.black.withOpacity(0.2) : Colors.white;
    final inputBorder = isDark
        ? Colors.white.withOpacity(0.05)
        : Colors.grey.shade200;
    final iconColorLocal = isDark ? Colors.white70 : Colors.grey.shade600;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: inputBg,
        border: Border(top: BorderSide(color: inputBorder)),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // Rich text toolbar
            if (_showRichTextToolbar)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: RichTextToolbar(
                  controller: _messageController,
                  onFormatApplied: () => setState(() {}),
                ),
              ),
            Row(
              children: [

                // Attach file button
                IconButton(
                  icon: Icon(Icons.attach_file_rounded, color: iconColorLocal),
                  onPressed: _pickAndSendFile,
                ),
                // Image button
                PopupMenuButton<String>(
                  icon: Icon(Icons.image_rounded, color: iconColorLocal),
                  color: const Color(0xFF203A43),
                  onSelected: (val) {
                    if (val == 'image') _pickAndSendImage();
                    if (val == 'image_once') _pickAndSendImage(viewOnce: true);
                    if (val == 'video') _pickAndSendVideo();
                    if (val == 'video_once') _pickAndSendVideo(viewOnce: true);
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'image', child: Text('📷 Send Image', style: TextStyle(color: Colors.white))),
                    const PopupMenuItem(value: 'image_once', child: Text('👁️ View-Once Image', style: TextStyle(color: Colors.white))),
                    const PopupMenuItem(value: 'video', child: Text('🎥 Send Video', style: TextStyle(color: Colors.white))),
                    const PopupMenuItem(value: 'video_once', child: Text('👁️ View-Once Video', style: TextStyle(color: Colors.white))),
                  ],
                ),
                // Voice record button
                IconButton(
                  icon: Icon(_isRecording ? Icons.stop_circle_rounded : Icons.mic_rounded,
                      color: _isRecording ? Colors.redAccent : iconColorLocal),
                  onPressed: _toggleRecording,
                ),
                Expanded(
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 100),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white.withOpacity(0.05) : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: TextField(
                      controller: _messageController,
                      style: TextStyle(color: isDark ? Colors.white : Colors.black87),
                      maxLines: null,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                      scrollController: ScrollController(),
                      decoration: InputDecoration(
                        hintText: _editingMessage != null ? 'Edit message...' : 'Message...',
                        hintStyle: TextStyle(color: isDark ? Colors.white30 : Colors.grey.shade400, fontSize: 14),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                CircleAvatar(
                  radius: 22,
                  backgroundColor: _editingMessage != null ? const Color(0xFF2AABEE) : const Color(0xFF6366F1),
                  child: GestureDetector(
                    onLongPress: _editingMessage != null ? null : _scheduleMessage,
                    child: IconButton(
                      icon: Icon(
                        _editingMessage != null ? Icons.check_rounded : Icons.send_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                      onPressed: _sendMessage,
                      tooltip: _editingMessage != null ? 'Save' : 'Send (long-press to schedule)',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
