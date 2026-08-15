import 'package:dmx/features/browser/services/adblock_filter_updater.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AdBlockFilterUpdater', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('init loads empty state gracefully', () async {
      final updater = AdBlockFilterUpdater();
      await updater.init();

      expect(updater.downloadedDomainCount, 0);
      expect(updater.downloadedTrackingCount, 0);
    });

    test('shouldBlock returns false for unknown domains', () async {
      final updater = AdBlockFilterUpdater();
      await updater.init();

      expect(updater.shouldBlock('example.com'), isFalse);
      expect(updater.shouldBlock('google.com'), isFalse);
    });

    test('domain validation rejects invalid entries', () async {
      final updater = AdBlockFilterUpdater();
      await updater.init();

      expect(updater.shouldBlock(''), isFalse);
      expect(updater.shouldBlock('.invalid'), isFalse);
      expect(updater.shouldBlock('no-dot'), isFalse);
    });

    test('getLastUpdateTime returns null when never updated', () async {
      final updater = AdBlockFilterUpdater();
      await updater.init();

      final lastUpdate = await updater.getLastUpdateTime();
      expect(lastUpdate, isNull);
    });

    test('getDaysUntilNextUpdate returns 0 when never updated', () async {
      final updater = AdBlockFilterUpdater();
      await updater.init();

      final days = await updater.getDaysUntilNextUpdate();
      expect(days, 0);
    });

    test('clearDownloadedDomains resets state', () async {
      final updater = AdBlockFilterUpdater();
      await updater.init();
      await updater.clearDownloadedDomains();

      expect(updater.downloadedDomainCount, 0);
      expect(updater.downloadedTrackingCount, 0);
    });

    test('setAutoUpdateEnabled persists', () async {
      final updater = AdBlockFilterUpdater();
      await updater.setAutoUpdateEnabled(false);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('adblock_auto_update_enabled'), isFalse);
    });

    test('isStale returns true when never updated', () async {
      final updater = AdBlockFilterUpdater();
      await updater.init();
      expect(await updater.isStale(), isTrue);
    });

    test('updateIfNeeded single-flight collapses concurrent calls', () async {
      final updater = AdBlockFilterUpdater();
      await updater.init();
      final f1 = updater.updateIfNeeded(force: false);
      final f2 = updater.updateIfNeeded(force: false);
      final results = await Future.wait([f1, f2]);
      expect(results[0], equals(results[1]));
    });
  });
}
