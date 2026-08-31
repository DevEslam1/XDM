import 'package:dmx/core/services/mirror_health_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MirrorHealthStore Unit Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await MirrorHealthStore.init();
      await MirrorHealthStore.clear();
    });

    test('records failures and blacklists after 5 failures', () async {
      const mirror = 'https://mirror1.example.com/file';
      expect(MirrorHealthStore.isBlacklisted(mirror), isFalse);

      for (int i = 0; i < 4; i++) {
        await MirrorHealthStore.recordFailure(mirror, statusCode: 503);
      }
      expect(MirrorHealthStore.getFailureCount(mirror), equals(4));
      expect(MirrorHealthStore.isBlacklisted(mirror), isFalse);

      // 5th failure triggers blacklist
      await MirrorHealthStore.recordFailure(mirror, statusCode: 503);
      expect(MirrorHealthStore.isBlacklisted(mirror), isTrue);
    });

    test('records success and clears blacklist', () async {
      const mirror = 'https://mirror2.example.com/file';
      for (int i = 0; i < 5; i++) {
        await MirrorHealthStore.recordFailure(mirror);
      }
      expect(MirrorHealthStore.isBlacklisted(mirror), isTrue);

      await MirrorHealthStore.recordSuccess(mirror, speedBps: 5242880.0);
      expect(MirrorHealthStore.isBlacklisted(mirror), isFalse);
      expect(MirrorHealthStore.getFailureCount(mirror), equals(0));
      expect(MirrorHealthStore.getPersistedSpeed(mirror), equals(5242880.0));
    });
  });
}
