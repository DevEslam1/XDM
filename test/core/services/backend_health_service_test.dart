import 'package:dmx/core/services/backend_health_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('BackendConfig.fromJson', () {
    test('parses explicit fields', () {
      final config = BackendConfig.fromJson({
        'baseUrl': 'https://a.example',
        'name': 'A',
        'priority': 2,
      });
      expect(config.baseUrl, 'https://a.example');
      expect(config.name, 'A');
      expect(config.priority, 2);
    });

    test('falls back to url, default name and priority', () {
      final config = BackendConfig.fromJson({'url': 'https://b.example'});
      expect(config.baseUrl, 'https://b.example');
      expect(config.name, 'Backend');
      expect(config.priority, 1);
    });

    test('tolerates an empty map', () {
      final config = BackendConfig.fromJson({});
      expect(config.baseUrl, '');
      expect(config.name, 'Backend');
      expect(config.priority, 1);
    });
  });

  group('BackendHealthService', () {
    late BackendHealthService health;

    setUp(() {
      health = BackendHealthService.instance;
      health.resetCooldowns();
    });

    test('registerBackend replaces and sorts by priority', () {
      health.registerBackend(
        const BackendConfig(
            baseUrl: 'https://zzz.test', name: 'Z', priority: 9),
      );
      health.registerBackend(
        const BackendConfig(
            baseUrl: 'https://aaa.test', name: 'A', priority: 0),
      );
      // Replacing the same base URL must not duplicate.
      health.registerBackend(
        const BackendConfig(
            baseUrl: 'https://aaa.test', name: 'A2', priority: 0),
      );

      final urls = health.backends.map((b) => b.baseUrl).toList();
      expect(urls.where((u) => u == 'https://aaa.test').length, 1);

      for (var i = 0; i < health.backends.length - 1; i++) {
        expect(
          health.backends[i].priority,
          lessThanOrEqualTo(health.backends[i + 1].priority),
        );
      }
    });

    test('backends getter is unmodifiable', () {
      expect(
          () => health.backends.add(const BackendConfig(
                baseUrl: 'x',
                name: 'x',
                priority: 1,
              )),
          throwsUnsupportedError);
    });

    test('markUnhealthy excludes a backend from active list', () {
      const url = 'https://unhealthy.test';
      health.registerBackend(const BackendConfig(
        baseUrl: url,
        name: 'U',
        priority: 0,
      ));
      expect(health.activeBackends.any((b) => b.baseUrl == url), isTrue);

      health.markUnhealthy(url, const Duration(hours: 1));
      expect(health.activeBackends.any((b) => b.baseUrl == url), isFalse);
    });

    test('pruneExpiredCooldowns restores a backend after expiry', () async {
      const url = 'https://expires.test';
      health.registerBackend(const BackendConfig(
        baseUrl: url,
        name: 'E',
        priority: 0,
      ));
      health.markUnhealthy(url, const Duration(milliseconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      health.pruneExpiredCooldowns();
      expect(health.activeBackends.any((b) => b.baseUrl == url), isTrue);
    });

    test('markHealthy records and re-enables the backend', () {
      const url = 'https://healthy.test';
      health.registerBackend(const BackendConfig(
        baseUrl: url,
        name: 'H',
        priority: 0,
      ));
      health.markUnhealthy(url, const Duration(hours: 1));
      health.markHealthy(url);
      expect(health.activeBaseUrl, url);
    });

    test('activeBackends falls back to soonest when all unhealthy', () {
      const first = 'https://first-soonest.test';
      expect(health.backends, isNotEmpty);
      final existing = health.backends.map((b) => b.baseUrl).toSet();
      health.registerBackend(const BackendConfig(
        baseUrl: first,
        name: 'first',
        priority: 0,
      ));

      var minutes = 10;
      for (final url in existing) {
        health.markUnhealthy(url, Duration(minutes: minutes));
        minutes++;
      }
      health.markUnhealthy(first, const Duration(minutes: 1));

      final active = health.activeBackends;
      expect(active.length, 1);
      expect(active.single.baseUrl, first);
      health.resetCooldowns();
    });

    test('resetCooldowns clears all cooldowns', () {
      const url = 'https://reset.test';
      health.registerBackend(const BackendConfig(
        baseUrl: url,
        name: 'R',
        priority: 0,
      ));
      health.markUnhealthy(url, const Duration(hours: 1));
      health.resetCooldowns();
      expect(health.activeBackends.any((b) => b.baseUrl == url), isTrue);
    });

    test('refreshBackends swallows network failures', () async {
      await health.refreshBackends('http://127.0.0.1:1/manifest.json');
      expect(health.backends, isNotEmpty);
    });
  });
}
