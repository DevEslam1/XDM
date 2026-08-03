import '../utils/constants.dart';
import 'logging_service.dart';

final _log = LoggingService.logger('BackendHealthService');

class BackendConfig {
  final String baseUrl;
  final String name;
  final int priority;

  const BackendConfig({
    required this.baseUrl,
    required this.name,
    required this.priority,
  });
}

/// // P0-1: Manages backend failover, health tracking, and cooldown recovery.
class BackendHealthService {
  BackendHealthService._internal();
  static final BackendHealthService instance = BackendHealthService._internal();

  final List<BackendConfig> _backends = [
    const BackendConfig(
      baseUrl: kDefaultBackendBaseUrl,
      name: 'Primary Backend',
      priority: 1,
    ),
    const BackendConfig(
      baseUrl: 'https://xdm-backend-fallback.europe-west1.run.app',
      name: 'Fallback Backend',
      priority: 2,
    ),
  ];

  final Map<String, DateTime> _unhealthyCooldowns = {};
  Duration cooldownDuration = const Duration(minutes: 10);
  String? _lastHealthyBaseUrl;

  List<BackendConfig> get backends => List.unmodifiable(_backends);

  void registerBackend(BackendConfig config) {
    _backends.removeWhere((b) => b.baseUrl == config.baseUrl);
    _backends.add(config);
    _backends.sort((a, b) => a.priority.compareTo(b.priority));
  }

  List<BackendConfig> get activeBackends {
    final now = DateTime.now();
    final healthy = _backends.where((b) {
      final cooldown = _unhealthyCooldowns[b.baseUrl];
      if (cooldown == null) return true;
      if (now.isAfter(cooldown)) {
        _unhealthyCooldowns.remove(b.baseUrl);
        return true;
      }
      return false;
    }).toList();

    healthy.sort((a, b) => a.priority.compareTo(b.priority));
    return healthy.isNotEmpty ? healthy : List.from(_backends);
  }

  void markUnhealthy(String baseUrl) {
    _unhealthyCooldowns[baseUrl] = DateTime.now().add(cooldownDuration);
    _log.warning('P0-1: Marked backend unhealthy ($baseUrl) for ${cooldownDuration.inMinutes}m');
  }

  void markHealthy(String baseUrl) {
    _unhealthyCooldowns.remove(baseUrl);
    _lastHealthyBaseUrl = baseUrl;
  }

  String get activeBaseUrl {
    final active = activeBackends;
    if (_lastHealthyBaseUrl != null &&
        active.any((b) => b.baseUrl == _lastHealthyBaseUrl)) {
      return _lastHealthyBaseUrl!;
    }
    return active.first.baseUrl;
  }

  void resetCooldowns() {
    _unhealthyCooldowns.clear();
  }
}
