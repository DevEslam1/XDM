import 'dart:async';

/// Global registry for active timers across the application to detect and prevent leaks.
class TimerRegistry {
  static final Map<String, Timer> _activeTimers = {};

  /// Registers a named timer into the registry.
  static Timer register(String id, Timer timer) {
    _activeTimers[id]?.cancel();
    _activeTimers[id] = timer;
    return timer;
  }

  /// Cancels and unregisters a timer by its id.
  static void unregister(String id) {
    _activeTimers[id]?.cancel();
    _activeTimers.remove(id);
  }

  /// Cancels all registered active timers and clears registry.
  static void cancelAll() {
    for (final timer in _activeTimers.values) {
      timer.cancel();
    }
    _activeTimers.clear();
  }

  /// Current active timers count.
  static int get activeCount => _activeTimers.length;

  /// List of IDs of all currently active timers.
  static List<String> get activeTimers => _activeTimers.keys.toList();
}
