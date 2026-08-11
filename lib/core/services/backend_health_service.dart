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

/// Manages backend failover, health tracking, and cooldown recovery.
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
  Duration cooldownDuration = const Duration(seconds: 30);
  String? _lastHealthyBaseUrl;

  List<BackendConfig> get backends => List.unmodifiable(_backends);

  void registerBackend(BackendConfig config) {
    _backends.removeWhere((b) => b.baseUrl == config.baseUrl);
    _backends.add(config);
    _backends.sort((a, b) => a.priority.compareTo(b.priority));
  }

  /// Removes expired cooldowns. Called internally before every activeBackends
  /// computation. Exposed as a public method so callers can force cleanup
  /// (e.g., during maintenance) without relying on getter side-effects.
  void pruneExpiredCooldowns() {
    final now = DateTime.now();
    _unhealthyCooldowns.removeWhere((_, expiry) => now.isAfter(expiry));
  }

  List<BackendConfig> get activeBackends {
    final now = DateTime.now();
    final healthy = _backends
        .where((b) {
          final expiry = _unhealthyCooldowns[b.baseUrl];
          return expiry == null || now.isAfter(expiry);
        })
        .toList();

    healthy.sort((a, b) => a.priority.compareTo(b.priority));
    if (healthy.isNotEmpty) return healthy;

    if (_unhealthyCooldowns.isEmpty) return List.from(_backends);
    BackendConfig? soonest;
    DateTime? soonestTime;
    for (final b in _backends) {
      final cd = _unhealthyCooldowns[b.baseUrl];
      if (cd != null && (soonestTime == null || cd.isBefore(soonestTime))) {
        soonestTime = cd;
        soonest = b;
      }
    }
    return soonest != null ? [soonest] : List.from(_backends);
  }

  void markUnhealthy(String baseUrl, [Duration? customDuration]) {
    final duration = customDuration ?? cooldownDuration;
    _unhealthyCooldowns[baseUrl] = DateTime.now().add(duration);
    _log.warning(
        'Marked backend unhealthy ($baseUrl) for ${duration.inSeconds}s');
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
    return active.isNotEmpty ? active.first.baseUrl : kDefaultBackendBaseUrl;
  }

  void resetCooldowns() {
    _unhealthyCooldowns.clear();
  }
}