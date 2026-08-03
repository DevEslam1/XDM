import 'dart:async';
import 'dart:collection';

class Semaphore {
  final int maxCount;
  int _currentCount = 0;
  final Queue<Completer<void>> _waiters = Queue();

  Semaphore(this.maxCount);

  Future<void> acquire() async {
    if (_currentCount < maxCount) {
      _currentCount++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      _currentCount--;
    }
  }
}
