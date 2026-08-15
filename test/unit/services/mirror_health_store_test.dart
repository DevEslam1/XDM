import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dmx/core/services/mirror/mirror_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MirrorHealthStore Unit Tests', () {
    final store = MirrorHealthStore.instance;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await store.init();
      await store.clear();
    });

    test('records failures and blacklists after 5 failures', () async {
      const mirror = 'https://mirror1.example.com/file';
      expect(store.isBlacklisted(mirror), isFalse);

      for (int i = 0; i < 4; i++) {
        await store.recordFailure(mirror, statusCode: 503);
      }
      expect(store.getFailureCount(mirror), equals(4));
      expect(store.isBlacklisted(mirror), isFalse);

      // 5th failure triggers blacklist
      await store.recordFailure(mirror, statusCode: 503);
      expect(store.isBlacklisted(mirror), isTrue);
    });

    test('records success and clears blacklist', () async {
      const mirror = 'https://mirror2.example.com/file';
      for (int i = 0; i < 5; i++) {
        await store.recordFailure(mirror);
      }
      expect(store.isBlacklisted(mirror), isTrue);

      await store.recordSuccess(mirror, speedBps: 5242880.0);
      expect(store.isBlacklisted(mirror), isFalse);
      expect(store.getFailureCount(mirror), equals(0));
      expect(store.getPersistedSpeed(mirror), equals(5242880.0));
    });

    test('enforces LRU cap of 200 entries with timestamp-based eviction', () async {
      for (int i = 0; i < 250; i++) {
        await store.recordSuccess('https://mirror$i.example.com', speedBps: 1000.0 + i);
      }
      // Oldest entries (e.g. mirror0) should have been evicted
      expect(store.getPersistedSpeed('https://mirror0.example.com'), equals(0.0));
      expect(store.getPersistedSpeed('https://mirror249.example.com'), isNonZero);
    });
  });
}
