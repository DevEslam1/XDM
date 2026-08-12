enum CircuitBreakerState { closed, open, halfOpen }

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

  CircuitBreakerState get state => _state;
  int get consecutiveFailures => _consecutiveFailures;
  bool get isClosed => _state == CircuitBreakerState.closed;
  bool get isOpen => _state == CircuitBreakerState.open;

  bool allowRequest() {
    final now = _clock();
    switch (_state) {
      case CircuitBreakerState.closed:
        return true;
      case CircuitBreakerState.open:
        if (now.difference(_lastStateChange) >= openTimeout) {
          _transition(CircuitBreakerState.halfOpen, now);
          _probeInFlight = true;
          _probeStartedAt = now;
          return true;
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
  }
}