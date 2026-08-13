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
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int failureThreshold;
  final Duration openTimeout;
  final Duration halfOpenTimeout;
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
          return false;
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
          ? openTimeout - _clock().difference(_lastStateChange).abs()
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
      recordFailure();
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
    _state = next;
    _lastStateChange = now;
    _lastStateChangeAt = now;
  }
}
