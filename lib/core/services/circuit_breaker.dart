import 'package:dmx/core/services/shared_prefs_batcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'error_taxonomy.dart';

enum CircuitBreakerState { closed, open, halfOpen }

/// Thrown when a [CircuitBreaker] is OPEN (or not yet allowed) and the caller
/// attempts a guarded operation.
class CircuitOpenException implements Exception {
  final String? service;
  final Duration retryAfter;
  const CircuitOpenException({this.service, this.retryAfter = Duration.zero});
  @override
  String toString() =>
      'CircuitOpenException: ${service ?? 'service'} is temporarily '
      'unavailable';
}

class CircuitBreaker {
  CircuitBreaker({
    this.failureThreshold = 3,
    this.openTimeout = const Duration(seconds: 30),
    this.halfOpenTimeout = const Duration(seconds: 5),
    this.key,
    this.onStateChange,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int failureThreshold;
  final Duration openTimeout;
  final Duration halfOpenTimeout;
  final String? key;
  final void Function(CircuitBreakerState, String?)? onStateChange;
  final DateTime Function() _clock;

  CircuitBreakerState _state = CircuitBreakerState.closed;
  int _consecutiveFailures = 0;
  DateTime _lastStateChange = DateTime.fromMillisecondsSinceEpoch(0);
  bool _probeInFlight = false;
  DateTime? _probeStartedAt;

  // Metrics (ERR-RESILIENCE-2.2)
  int _totalRequests = 0;
  int _totalFailures = 0;
  DateTime _lastStateChangeAt = DateTime.fromMillisecondsSinceEpoch(0);

  CircuitBreakerState get state => _state;
  int get consecutiveFailures => _consecutiveFailures;
  bool get isClosed => _state == CircuitBreakerState.closed;
  bool get isOpen => _state == CircuitBreakerState.open;
  int get totalRequests => _totalRequests;
  int get totalFailures => _totalFailures;
  DateTime get lastStateChange => _lastStateChangeAt;

  bool allowRequest() {
    _totalRequests++;
    final now = _clock();
    switch (_state) {
      case CircuitBreakerState.closed:
        return true;
      case CircuitBreakerState.open:
        if (now.difference(_lastStateChange) >= openTimeout) {
          _transition(CircuitBreakerState.halfOpen, now);
          // FIX P1-8b: Allow the request that triggers halfOpen to probe immediately,
          // instead of requiring one extra request (saves openTimeout latency).
          if (!_probeInFlight) {
            _probeInFlight = true;
            _probeStartedAt = now;
            return true;
          }
        }
        return false;
      case CircuitBreakerState.halfOpen:
        // If a probe is stuck, timeout and allow a new one
        if (_probeInFlight && _probeStartedAt != null) {
          if (now.difference(_probeStartedAt!) >= halfOpenTimeout) {
            _probeInFlight = false;
          } else {
            return false;
          }
        }

        if (!_probeInFlight) {
          _probeInFlight = true;
          _probeStartedAt = now;
          return true;
        }
        return false;
    }
  }

  /// Runs [operation] behind the breaker: rejects immediately with a
  /// [CircuitOpenException] when the circuit is OPEN, allows a single probe in
  /// HALF_OPEN, and records success/failure against the breaker.
  Future<T> guard<T>(
    Future<T> Function() operation, {
    String? service,
  }) async {
    if (!allowRequest()) {
      final remaining = isOpen
          ? openTimeout - _clock().difference(_lastStateChange)
          : halfOpenTimeout;
      throw CircuitOpenException(
        service: service,
        retryAfter: remaining > Duration.zero ? remaining : Duration.zero,
      );
    }
    try {
      final result = await operation();
      recordSuccess();
      return result;
    } catch (e) {
      final classified = ErrorTaxonomy.classify(e);
      if (classified.retryable ||
          classified.isServerError ||
          classified.isNetworkError) {
        recordFailure();
      }
      rethrow;
    }
  }

  void recordSuccess() {
    _consecutiveFailures = 0;
    _probeInFlight = false;
    _probeStartedAt = null;
    if (_state != CircuitBreakerState.closed) {
      _transition(CircuitBreakerState.closed, _clock());
    }
  }

  DateTime? _lastFailureTimestamp;
  void recordFailure() {
    final now = _clock();
    _totalFailures++;
    // Debounce rapid concurrent failures
    if (_state != CircuitBreakerState.closed &&
        _lastFailureTimestamp != null &&
        now.difference(_lastFailureTimestamp!) <
            const Duration(milliseconds: 500)) {
      return;
    }

    _lastFailureTimestamp = now;
    _consecutiveFailures++;
    _probeInFlight = false;
    _probeStartedAt = null;

    if (_state == CircuitBreakerState.halfOpen ||
        _consecutiveFailures >= failureThreshold) {
      _transition(CircuitBreakerState.open, now);
    }
  }

  void reset() {
    _consecutiveFailures = 0;
    _probeInFlight = false;
    _probeStartedAt = null;
    _transition(CircuitBreakerState.closed, _clock());
  }

  void _transition(CircuitBreakerState next, DateTime now) {
    if (_state == next) return;
    _state = next;
    _lastStateChange = now;
    _lastStateChangeAt = now;
    onStateChange?.call(next, key);
  }
}

class CircuitBreakerRegistry {
  static const String _prefsPrefix = 'cb_open_';
  final Map<String, CircuitBreaker> _breakers = {};

  Future<void> restoreState() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefsPrefix));
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final key in keys) {
      final expireTime = prefs.getInt(key);
      if (expireTime != null && expireTime > now) {
        final hostKey = key.substring(_prefsPrefix.length);
        final cb = getBreaker(hostKey);
        // Pre-open the circuit breaker
        cb._transition(CircuitBreakerState.open, DateTime.now());
      } else {
        SharedPrefsBatcher.instance.remove(key);
      }
    }
  }

  CircuitBreaker getBreaker(
    String hostKey, {
    int failureThreshold = 3,
    Duration openTimeout = const Duration(seconds: 30),
    Duration halfOpenTimeout = const Duration(seconds: 5),
  }) {
    if (_breakers.containsKey(hostKey)) {
      return _breakers[hostKey]!;
    }

    final breaker = CircuitBreaker(
      failureThreshold: failureThreshold,
      openTimeout: openTimeout,
      halfOpenTimeout: halfOpenTimeout,
      key: hostKey,
      onStateChange: _onStateChange,
    );
    _breakers[hostKey] = breaker;
    return breaker;
  }

  void _onStateChange(CircuitBreakerState state, String? key) {
    if (key == null) return;
    final prefsKey = '$_prefsPrefix$key';

    if (state == CircuitBreakerState.open) {
      final breaker = _breakers[key];
      if (breaker != null) {
        final ttl = breaker.openTimeout * 3;
        final expireTime = DateTime.now().add(ttl).millisecondsSinceEpoch;
        SharedPrefsBatcher.instance.setInt(prefsKey, expireTime);
      }
    } else if (state == CircuitBreakerState.closed) {
      SharedPrefsBatcher.instance.remove(prefsKey);
    }
  }
}

/// FIX-23: Circuit breaker helper specifically for URLs/hosts
class UrlCircuitBreaker {
  UrlCircuitBreaker._();
  static final UrlCircuitBreaker instance = UrlCircuitBreaker._();

  final Map<String, int> _urlFailures = {};
  final Map<String, DateTime> _lastFailures = {};

  bool shouldBlock(String url) {
    try {
      final uri = Uri.tryParse(url);
      final host = uri?.host ?? url;
      final failures = _urlFailures[host] ?? 0;
      final last = _lastFailures[host];
      if (failures >= 5 &&
          last != null &&
          DateTime.now().difference(last) < const Duration(minutes: 30)) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  void recordFailure(String url) {
    try {
      final uri = Uri.tryParse(url);
      final host = uri?.host ?? url;
      _urlFailures[host] = (_urlFailures[host] ?? 0) + 1;
      _lastFailures[host] = DateTime.now();
      // FIX P1-8c: Bound map to prevent leak on burst 429/5xx across many hosts.
      if (_urlFailures.length > 500) {
        final oldest = _lastFailures.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value));
        for (var i = 0; i < 100 && i < oldest.length; i++) {
          _urlFailures.remove(oldest[i].key);
          _lastFailures.remove(oldest[i].key);
        }
      }
    } catch (_) {}
  }

  void recordSuccess(String url) {
    try {
      final uri = Uri.tryParse(url);
      final host = uri?.host ?? url;
      _urlFailures.remove(host);
      _lastFailures.remove(host);
    } catch (_) {}
  }

  void reset() {
    _urlFailures.clear();
    _lastFailures.clear();
  }
}
