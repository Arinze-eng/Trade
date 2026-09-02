import 'dart:async' show Timer, VoidCallback;
import 'dart:collection';

/// [UPDATE 2026-06-08-LAGFIX] Debounce & throttle utilities
///
/// Used across chat screens to prevent expensive setState() calls,
/// Supabase streams, and file operations from causing UI jank.
///
/// Three patterns:
///   1. Debouncer — delays execution until activity stops
///   2. Throttler — limits execution to once per interval
///   3. Batcher — collects calls and runs them as a batch

/// Standard debouncer: waits [delay] of silence then fires.
class Debouncer {
  final Duration delay;
  Timer? _timer;

  Debouncer({this.delay = const Duration(milliseconds: 300)});

  void call(void Function() action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void flush() {
    // If there's a pending timer, it will fire on its own.
    // Cancel + manual fire not needed since we just let it run.
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Throttled action: executes at most once per [interval].
/// If called again within the interval, the latest call is queued.
/// The queued call fires when the interval expires.
class Throttler {
  final Duration interval;
  Timer? _timer;
  VoidCallback? _pending;

  Throttler({this.interval = const Duration(milliseconds: 500)});

  void call(void Function() action) {
    if (_timer?.isActive == true) {
      _pending = action;
      return;
    }
    _run(action);
  }

  void _run(void Function() action) {
    action();
    _timer = Timer(interval, () {
      final next = _pending;
      _pending = null;
      if (next != null) _run(next);
    });
  }

  void cancel() {
    _timer?.cancel();
    _pending = null;
  }

  void dispose() {
    _timer?.cancel();
    _pending = null;
  }
}

/// Batches function calls and runs them as a single batch after [delay] of
/// inactivity. The [batchAction] receives all accumulated arguments.
class Batcher<T> {
  final Duration delay;
  final void Function(List<T> batch) batchAction;
  Timer? _timer;
  final List<T> _items = [];

  Batcher({this.delay = const Duration(milliseconds: 300), required this.batchAction});

  void add(T item) {
    _items.add(item);
    _timer?.cancel();
    _timer = Timer(delay, _flush);
  }

  void _flush() {
    if (_items.isEmpty) return;
    final copy = List<T>.from(_items);
    _items.clear();
    batchAction(copy);
  }

  void flush() {
    _timer?.cancel();
    _flush();
  }

  void dispose() {
    _timer?.cancel();
    _items.clear();
  }
}

/// Efficient setState throttler for Flutter widgets.
/// Wraps a [Debouncer] + [Throttler] combo to avoid both rapid-fire and
/// stale updates. Guarantees the last requested update will fire, but
/// never more than once per [throttleInterval].
class SetStateThrottler {
  final Throttler _throttler;
  final Debouncer _debouncer;
  bool _mounted = true;

  SetStateThrottler({
    Duration throttleInterval = const Duration(milliseconds: 100),
    Duration debounceDelay = const Duration(milliseconds: 250),
  })  : _throttler = Throttler(interval: throttleInterval),
        _debouncer = Debouncer(delay: debounceDelay);

  /// Request a setState update. The action will fire:
  /// 1. At most once every [throttleInterval]
  /// 2. Always once after [debounceDelay] of inactivity
  void request(void Function() action) {
    if (!_mounted) return;
    _throttler.call(action);
    _debouncer.call(action);
  }

  void markDisposed() {
    _mounted = false;
  }

  void dispose() {
    _mounted = false;
    _throttler.dispose();
    _debouncer.dispose();
  }
}