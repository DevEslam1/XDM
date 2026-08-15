import 'package:logging/logging.dart';

/// Standard interface for singleton services with lifecycle resources to release.
abstract class DisposableService {
  Future<void> dispose();
}

/// Central service coordinator that ensures clean teardown of all singletons
/// when the app enters `AppLifecycleState.detached` or shuts down.
class ServiceRegistry {
  static final _log = Logger('ServiceRegistry');
  static final List<DisposableService> _services = [];

  static void register(DisposableService service) {
    if (!_services.contains(service)) {
      _services.add(service);
    }
  }

  static void unregister(DisposableService service) {
    _services.remove(service);
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
  }
}
