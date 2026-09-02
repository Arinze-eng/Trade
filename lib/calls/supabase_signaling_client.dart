import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase-based WebRTC signaling.
///
/// IMPORTANT: Supabase `.stream()` emits the *full* row set on each change,
/// so we must deduplicate events locally.
///
/// FIX: After processing a signal, we delete it from the database.
/// This prevents signal accumulation which was causing:
/// 1. Memory leaks from growing _seenSignalIds set
/// 2. Slower stream processing over time
/// 3. Stale signals triggering unwanted call dialogs
class SupabaseSignalingClient {
  final SupabaseClient client;
  final String selfId;

  StreamSubscription<List<Map<String, dynamic>>>? _sub;
  final Set<String> _seenSignalIds = {};

  SupabaseSignalingClient({required this.client, required this.selfId});

  Future<void> connect({required void Function(Map<String, dynamic>) onSignal}) async {
    _sub?.cancel();
    _seenSignalIds.clear();

    _sub = client
        .from('call_signals')
        .stream(primaryKey: ['id'])
        .eq('to_id', selfId)
        .order('created_at', ascending: true)
        .listen((rows) {
      for (final r in rows) {
        final m = Map<String, dynamic>.from(r);
        final id = (m['id'] ?? '').toString();
        if (id.isEmpty) continue;
        if (_seenSignalIds.contains(id)) continue;
        _seenSignalIds.add(id);

        // Process the signal
        onSignal(m);

        // ── FIX: Delete processed signals to prevent accumulation ──
        // Old signals were piling up, causing the stream to emit more data
        // on each change, slowing everything down and causing phantom calls.
        _deleteSignal(id);
      }
    });
  }

  /// Delete a processed signal from the database.
  Future<void> _deleteSignal(String id) async {
    try {
      await client.from('call_signals').delete().eq('id', id);
    } catch (_) {}
  }

  Future<void> send({
    required String toId,
    required String type,
    required Map<String, dynamic> payload,
  }) async {
    await client.from('call_signals').insert({
      'from_id': selfId,
      'to_id': toId,
      'type': type,
      'payload': payload,
    });
  }

  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    _seenSignalIds.clear();
  }
}
