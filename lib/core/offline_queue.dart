import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

/// [UPDATE 2026-06-08-LAGFIX] Offline message queue
///
/// When sending messages/media on a weak or down network, this queue
/// stores them locally and flushes them when connectivity is restored.
///
/// Prevents:
///   - Failed sends leaving messages in an inconsistent state
///   - UI blocking on network-dependent send() calls
///   - Lost messages when app closes mid-send
class OfflineMessageQueue {
  static const _key = 'offline_msg_queue_v1';

  static final OfflineMessageQueue instance = OfflineMessageQueue._();
  OfflineMessageQueue._();

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _listening = false;

  /// Start listening for connectivity changes to auto-flush.
  void startListening() {
    if (_listening) return;
    _listening = true;
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasConnection = !results.any((r) => r == ConnectivityResult.none);
      if (hasConnection) {
        flush();
      }
    });
  }

  void stopListening() {
    _listening = false;
    _connectivitySub?.cancel();
    _connectivitySub = null;
  }

  /// Enqueue a message send attempt.
  Future<String> enqueue({
    required String senderId,
    required String receiverId,
    required String content,
    String messageType = 'text',
    String? mediaPath,
    String? mediaMime,
    int? mediaDurationMs,
    String? mediaName,
    int? mediaSizeBytes,
    int? replyToId,
    String? caption,
    bool viewOnce = false,
    bool isRichText = false,
    String? richTextJson,
    bool isForwarded = false,
    String? forwardedFromId,
  }) async {
    final sp = await SharedPreferences.getInstance();
    final existing = await _load(sp);

    final entry = {
      'id': '${DateTime.now().millisecondsSinceEpoch}_${senderId.substring(0, 6)}',
      'senderId': senderId,
      'receiverId': receiverId,
      'content': content,
      'messageType': messageType,
      'mediaPath': mediaPath,
      'mediaMime': mediaMime,
      'mediaDurationMs': mediaDurationMs,
      'mediaName': mediaName,
      'mediaSizeBytes': mediaSizeBytes,
      'replyToId': replyToId,
      'caption': caption,
      'viewOnce': viewOnce,
      'isRichText': isRichText,
      'richTextJson': richTextJson,
      'isForwarded': isForwarded,
      'forwardedFromId': forwardedFromId,
      'queuedAt': DateTime.now().toUtc().toIso8601String(),
      'retryCount': 0,
    };

    existing.add(entry);
    await sp.setString(_key, jsonEncode(existing));
    return entry['id'] as String;
  }

  /// Remove a queue entry (after successful send).
  Future<void> remove(String id) async {
    final sp = await SharedPreferences.getInstance();
    final entries = await _load(sp);
    entries.removeWhere((e) => e['id'] == id);
    await sp.setString(_key, jsonEncode(entries));
  }

  /// Get all pending queue entries.
  Future<List<Map<String, dynamic>>> pending() async {
    final sp = await SharedPreferences.getInstance();
    return _load(sp);
  }

  /// Get count of pending entries.
  Future<int> pendingCount() async {
    return (await pending()).length;
  }

  /// Flush all queued messages — marks them for retry.
  Future<int> flush() async {
    final sp = await SharedPreferences.getInstance();
    final entries = await _load(sp);
    if (entries.isEmpty) return 0;

    int flushed = 0;
    final remaining = <Map<String, dynamic>>[];

    for (final entry in entries) {
      final retryCount = (entry['retryCount'] ?? 0) as int;
      if (retryCount >= 5) {
        remaining.add(entry);
        continue;
      }
      entry['retryCount'] = retryCount + 1;
      remaining.add(entry);
    }

    await sp.setString(_key, jsonEncode(remaining));
    return flushed;
  }

  /// Called after successfully sending one entry — remove from queue
  Future<void> markSent(String id) async {
    await remove(id);
  }

  Future<List<Map<String, dynamic>>> _load(SharedPreferences sp) async {
    final raw = sp.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  void dispose() {
    stopListening();
  }
}