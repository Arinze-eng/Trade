/// [UPDATE 2026-06-08-LAGFIX] Paginated message loader
///
/// Instead of loading ALL messages into the StreamBuilder at once (which causes
/// massive lag on Supabase Realtime emit), this loads messages in batches.
///
/// Strategy:
///   1. Initial load: fetch most recent [pageSize] messages from Supabase REST
///   2. Stream: subscribe to NEW messages only (created_at > last loaded)
///   3. Scroll-back: load older pages on demand
///   4. Memory: limit in-memory messages to [maxCachedMessages]
///
/// This reduces per-frame build cost from O(n) to O(pageSize).
class PaginatedMessageLoader {
  final int pageSize;
  final int maxCachedMessages;

  PaginatedMessageLoader({
    this.pageSize = 50,
    this.maxCachedMessages = 200,
  });

  List<Map<String, dynamic>> _cachedMessages = [];
  bool _hasMoreOlder = true;
  bool _isLoadingOlder = false;

  /// Currently displayed messages (sorted chronologically for the ListView).
  List<Map<String, dynamic>> get messages => _cachedMessages;

  bool get hasMoreOlder => _hasMoreOlder;
  bool get isLoadingOlder => _isLoadingOlder;
  int get count => _cachedMessages.length;

  /// Replace all messages (initial load or full refresh).
  void resetWith(List<Map<String, dynamic>> messages) {
    final sorted = List<Map<String, dynamic>>.from(messages)
      ..sort((a, b) => (a['created_at'] ?? '').toString().compareTo(
            (b['created_at'] ?? '').toString(),
          ));

    _cachedMessages = sorted;
    _hasMoreOlder = true;
    _isLoadingOlder = false;

    _enforceCacheLimit();
  }

  /// Prepend older messages (loaded from scrolling back).
  void prependOlder(List<Map<String, dynamic>> olderMessages) {
    final sorted = List<Map<String, dynamic>>.from(olderMessages)
      ..sort((a, b) => (a['created_at'] ?? '').toString().compareTo(
            (b['created_at'] ?? '').toString(),
          ));

    if (sorted.isEmpty) {
      _hasMoreOlder = false;
      return;
    }

    _cachedMessages = [...sorted, ..._cachedMessages];
    _hasMoreOlder = sorted.length >= pageSize;
    _isLoadingOlder = false;

    _enforceCacheLimit();
  }

  /// Insert a single new message (from Realtime stream) at the correct position.
  /// Returns true if the message was new (not a duplicate).
  bool insertNew(Map<String, dynamic> message) {
    final id = message['id'];
    // Check duplicate
    if (_cachedMessages.any((m) => m['id'] == id)) {
      // Update existing in-place
      final idx = _cachedMessages.indexWhere((m) => m['id'] == id);
      if (idx >= 0) {
        _cachedMessages[idx] = message;
      }
      return false;
    }

    _cachedMessages.add(message);
    // Keep sorted
    _cachedMessages.sort((a, b) => (a['created_at'] ?? '').toString().compareTo(
          (b['created_at'] ?? '').toString(),
        ));

    _enforceCacheLimit();
    return true;
  }

  /// Mark that older messages are being loaded.
  void markLoadingOlder() {
    _isLoadingOlder = true;
  }

  /// Mark that there are no more older messages.
  void markNoMoreOlder() {
    _hasMoreOlder = false;
    _isLoadingOlder = false;
  }

  void _enforceCacheLimit() {
    if (_cachedMessages.length > maxCachedMessages) {
      final excess = _cachedMessages.length - maxCachedMessages;
      if (excess > 0) {
        _cachedMessages = _cachedMessages.sublist(excess);
      }
    }
  }

  void dispose() {
    _cachedMessages = [];
  }
}