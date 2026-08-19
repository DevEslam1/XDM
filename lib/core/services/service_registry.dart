import 'package:logging/logging.dart';

/// Standard interface for singleton services with lifecycle resources to release.
abstract class DisposableService {
  Future<void> dispose();
}

abstract class MemoryPressureListener {
  void onMemoryPressure();
}

/// Central service coordinator that ensures clean teardown of all singletons
/// when the app enters `AppLifecycleState.detached` or shuts down, and distributes
/// memory pressure notifications via WeakReferences to prevent retention leaks.
class ServiceRegistry {
  static final _log = Logger('ServiceRegistry');
  static final List<DisposableService> _services = [];
  static final List<WeakReference<MemoryPressureListener>> _memoryListeners = [];

  static int get activeServicesCount => _services.length;
  static int get activeMemoryListenersCount {
    _memoryListeners.removeWhere((ref) => ref.target == null);
    return _memoryListeners.length;
  }

  static void register(DisposableService service) {
    if (!_services.contains(service)) {
      _services.add(service);
    }
  }

  static void unregister(DisposableService service) {
    _services.remove(service);
  }

  static void registerMemoryPressureListener(MemoryPressureListener listener) {
    _memoryListeners.removeWhere((ref) => ref.target == null);
    final alreadyRegistered = _memoryListeners.any((ref) => ref.target == listener);
    if (!alreadyRegistered) {
      _memoryListeners.add(WeakReference(listener));
    }
  }

  static void unregisterMemoryPressureListener(
      MemoryPressureListener listener) {
    _memoryListeners.removeWhere((ref) => ref.target == null || ref.target == listener);
  }

  static void broadcastMemoryPressure() {
    _memoryListeners.removeWhere((ref) => ref.target == null);
    _log.info(
        'Broadcasting memory pressure event to ${_memoryListeners.length} listeners');
    for (final ref in List<WeakReference<MemoryPressureListener>>.from(_memoryListeners)) {
      final listener = ref.target;
      if (listener != null) {
        try {
          listener.onMemoryPressure();
        } catch (e, st) {
          _log.warning('Error in memory pressure listener: $e', e, st);
        }
      }
    }
  }

  static Future<void> shutdownAll() async {
    _log.info('Shutting down ${_services.length} registered services...');
    for (final service in List<DisposableService>.from(_services.reversed)) {
      try {
        await service.dispose();
      } catch (e, st) {
        _log.severe('Error disposing service $service: $e', e, st);
      }
    }
    _services.clear();
    _memoryListeners.clear();
  }
}
