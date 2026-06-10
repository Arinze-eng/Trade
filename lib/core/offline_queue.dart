import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../services/supabase_service.dart';

/// [UPDATE 2026-06-10-WA] Offline message queue (WhatsApp-style)
///
/// When sending messages on a weak or down network, this queue stores
/// them locally and *actually re-sends* them when connectivity is restored.
///
/// Prevents:
///   - Failed sends being lost
///   - UI blocking on network-dependent send() calls
///   - Lost messages when app closes mid-send
///
/// Notes:
///   - flush() now performs real retries through SupabaseService.sendMessage.
///   - Successfully sent entries are removed from disk immediately.
///   - Entries that fail get retryCount incremented; once retryCount >= 5
///     they are kept on disk but skipped (manual retry possible).
class OfflineMessageQueue {
  static const _key = 'offline_msg_queue_v1';

  static final OfflineMessageQueue instance = OfflineMessageQueue._();
  OfflineMessageQueue._();

  final SupabaseService _supabase = SupabaseService();

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _listening = false;
  bool _flushing = false;

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

  /// [UPDATE 2026-06-10-WA] Flush queued messages — actually re-send them
  /// through Supabase and drop successful entries from disk.
  /// Returns number of messages successfully sent.
  Future<int> flush() async {
    if (_flushing) return 0;
    _flushing = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final entries = await _load(sp);
      if (entries.isEmpty) return 0;

      int flushed = 0;
      final remaining = <Map<String, dynamic>>[];

      for (final entry in entries) {
        final retryCount = (entry['retryCount'] ?? 0) as int;
        if (retryCount >= 5) {
          // Skip — keep on disk so the user can manually retry / clear.
          remaining.add(entry);
          continue;
        }

        try {
          await _supabase.sendMessage(
            senderId: (entry['senderId'] ?? '').toString(),
            receiverId: (entry['receiverId'] ?? '').toString(),
            content: (entry['content'] ?? '').toString(),
            messageType: (entry['messageType'] ?? 'text').toString(),
            mediaPath: entry['mediaPath']?.toString(),
            mediaMime: entry['mediaMime']?.toString(),
            mediaDurationMs: entry['mediaDurationMs'] is int ? entry['mediaDurationMs'] as int : null,
            mediaName: entry['mediaName']?.toString(),
            mediaSizeBytes: entry['mediaSizeBytes'] is int ? entry['mediaSizeBytes'] as int : null,
            replyToId: entry['replyToId'] is int ? entry['replyToId'] as int : null,
            caption: entry['caption']?.toString(),
            viewOnce: entry['viewOnce'] == true,
            isRichText: entry['isRichText'] == true,
            richTextJson: entry['richTextJson']?.toString(),
            isForwarded: entry['isForwarded'] == true,
            forwardedFromId: entry['forwardedFromId']?.toString(),
          );
          flushed++;
        } catch (e) {
          debugPrint('OfflineQueue: send failed for ${entry['id']}: $e');
          entry['retryCount'] = retryCount + 1;
          remaining.add(entry);
        }
      }

      await sp.setString(_key, jsonEncode(remaining));
      return flushed;
    } finally {
      _flushing = false;
    }
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
