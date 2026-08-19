import 'dart:async';
import 'dart:collection';

class Semaphore {
  final int maxCount;
  int _currentCount = 0;
  final Queue<Completer<void>> _waiters = Queue();

  Semaphore(this.maxCount);

  int get currentCount => _currentCount;
  int get waiterCount => _waiters.length;

  Future<void> acquire() async {
    if (_currentCount < maxCount) {
      _currentCount++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
  }

  /// Acquires a permit with a timeout. If the timeout fires before a permit
  /// is obtained, throws [TimeoutException] without leaking any permits.
  Future<void> acquireWithTimeout(Duration timeout) async {
    if (_currentCount < maxCount) {
      _currentCount++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      if (_waiters.remove(completer)) {
        // Successfully removed while still waiting in queue; no permit was taken.
        throw TimeoutException(
            'Semaphore acquisition timed out after $timeout');
      } else {
        // Permit was granted right at the timeout race boundary; release it back.
        release();
        throw TimeoutException(
            'Semaphore acquisition timed out after $timeout');
      }
    }
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      if (_currentCount <= 0) {
        assert(false, 'Semaphore.release() called when count is already 0');
        return;
      }
      _currentCount--;
    }
  }
}
