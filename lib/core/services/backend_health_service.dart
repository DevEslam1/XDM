import 'dart:convert';
import 'package:dio/dio.dart';
import '../../features/settings/provider/settings_provider.dart';
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

  factory BackendConfig.fromJson(Map<String, dynamic> json) {
    return BackendConfig(
      baseUrl: json['baseUrl'] as String? ?? json['url'] as String? ?? '',
      name: json['name'] as String? ?? 'Backend',
      priority: (json['priority'] as num?)?.toInt() ?? 1,
    );
  }
}

/// Manages backend failover, health tracking, and cooldown recovery.
class BackendHealthService {
  BackendHealthService._internal() {
    _loadFromSettings();
  }
  static final BackendHealthService instance = BackendHealthService._internal();

  static const List<BackendConfig> _defaultFallbackBackends = [
    BackendConfig(
      baseUrl: kDefaultBackendBaseUrl,
      name: 'Primary Backend',
      priority: 1,
    ),
    BackendConfig(
      baseUrl: 'https://xdm-backend-fallback.europe-west1.run.app',
      name: 'Fallback Backend',
      priority: 2,
    ),
  ];

  final List<BackendConfig> _backends = List.from(_defaultFallbackBackends);

  void _loadFromSettings() {
    try {
      final customUrl = SettingsProvider.instance.backendUrl;
      if (customUrl.isNotEmpty && customUrl.startsWith('http')) {
        registerBackend(BackendConfig(
          baseUrl: customUrl,
          name: 'Custom Backend',
          priority: 0,
        ));
      }
    } catch (_) {}
  }

  Future<void> refreshBackends([String? manifestUrl]) async {
    final targetUrl = manifestUrl ?? '$activeBaseUrl/api/manifest.json';
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ));
      final response = await dio.get(targetUrl);
      if (response.statusCode == 200 && response.data != null) {
        dynamic data = response.data;
        if (data is String) {
          data = jsonDecode(data);
        }
        if (data is Map && data['backends'] is List) {
          final list = (data['backends'] as List)
              .whereType<Map>()
              .map((m) => BackendConfig.fromJson(Map<String, dynamic>.from(m)))
              .where((b) => b.baseUrl.isNotEmpty)
              .toList();
          if (list.isNotEmpty) {
            for (final b in list) {
              registerBackend(b);
            }
            _log.info('Refreshed ${list.length} backends from manifest');
          }
        }
      }
    } catch (e, st) {
      _log.warning('Failed to refresh backends from manifest: $e', e, st);
    }
  }

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
    final healthy = _backends.where((b) {
      final expiry = _unhealthyCooldowns[b.baseUrl];
      return expiry == null || now.isAfter(expiry);
    }).toList();

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
