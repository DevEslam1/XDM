/// Current state of a [CircuitBreaker].
enum CircuitBreakerState { closed, open, halfOpen }

/// A stateful retry guard.
///
/// In the `closed` state every call is allowed; after [failureThreshold]
/// consecutive failures the breaker trips to `open`, rejecting all calls for
/// [openTimeout]. It then transitions to `halfOpen`, where a single probe is
/// allowed: success re-arms the breaker, failure re-opens it. This prevents
/// retry storms against a failing host.
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

  CircuitBreakerState get state => _state;
  int get consecutiveFailures => _consecutiveFailures;

  /// Whether a new attempt is allowed right now.
  bool get isClosed => _state == CircuitBreakerState.closed;
  bool get isOpen => _state == CircuitBreakerState.open;

  /// Whether a call may proceed. Re-opens or half-opens automatically based
  /// on elapsed time.
  bool allowRequest() {
    final now = _clock();
    switch (_state) {
      case CircuitBreakerState.closed:
        return true;
      case CircuitBreakerState.open:
        if (now.difference(_lastStateChange) >= openTimeout) {
          _transition(CircuitBreakerState.halfOpen, now);
          _probeInFlight = false;
        }
        return false;
      case CircuitBreakerState.halfOpen:
        if (_probeInFlight) return false;
        if (now.difference(_lastStateChange) >= halfOpenTimeout) {
          _probeInFlight = true;
          return true;
        }
        return false;
    }
  }

  /// Records a successful attempt (re-arms the breaker).
  void recordSuccess() {
    _consecutiveFailures = 0;
    _probeInFlight = false;
    if (_state != CircuitBreakerState.closed) {
      _transition(CircuitBreakerState.closed, _clock());
    }
  }

  /// Records a failed attempt, tripping the breaker when the threshold is met.
  void recordFailure() {
    _consecutiveFailures++;
    _probeInFlight = false;
    if (_state == CircuitBreakerState.halfOpen ||
        _consecutiveFailures >= failureThreshold) {
      _transition(CircuitBreakerState.open, _clock());
    }
  }

  /// Force-resets to the closed state.
  void reset() {
    _consecutiveFailures = 0;
    _probeInFlight = false;
    _transition(CircuitBreakerState.closed, _clock());
  }

  void _transition(CircuitBreakerState next, DateTime now) {
    _state = next;
    _lastStateChange = now;
  }
}
