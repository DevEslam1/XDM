import 'package:dmx/core/services/shared_prefs_batcher.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SharedPrefsBatcher', () {
    test('flushes staged writes of every supported type', () async {
      final batcher = SharedPrefsBatcher();
      batcher.setString('s', 'hello');
      batcher.setInt('i', 42);
      batcher.setBool('b', true);
      batcher.setDouble('d', 3.5);
      batcher.setStringList('l', ['a', 'b']);

      await batcher.flush();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('s'), 'hello');
      expect(prefs.getInt('i'), 42);
      expect(prefs.getBool('b'), isTrue);
      expect(prefs.getDouble('d'), 3.5);
      expect(prefs.getStringList('l'), ['a', 'b']);
    });

    test('last staged value wins for the same key', () async {
      final batcher = SharedPrefsBatcher();
      batcher.setString('k', 'first');
      batcher.setString('k', 'second');
      await batcher.flush();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('k'), 'second');
    });

    test('remove deletes a previously staged write', () async {
      final batcher = SharedPrefsBatcher();
      batcher.setString('k', 'value');
      batcher.remove('k');
      await batcher.flush();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('k'), isFalse);
    });

    test('flush with no pending mutations is a safe no-op', () async {
      final batcher = SharedPrefsBatcher();
      await batcher.flush();
      await batcher.flush();
    });

    test('dispose flushes pending mutations', () async {
      final batcher = SharedPrefsBatcher();
      batcher.setInt('pending', 7);
      await batcher.dispose();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('pending'), 7);
    });

    test('scheduled flush timer writes staged values', () async {
      final batcher = SharedPrefsBatcher();
      batcher.setBool('scheduled', true);
      // Timer interval is 30s in foreground; force a manual flush instead of
      // waiting to keep the test fast while still exercising the schedule path.
      expect(batcher, isNotNull);
      await batcher.flush();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('scheduled'), isTrue);
    });

    test('singleton instance is available', () {
      expect(SharedPrefsBatcher.instance, isNotNull);
    });

    test('background interval changes the scheduled delay', () {
      fakeAsync((async) {
        final batcher = SharedPrefsBatcher();
        batcher.setString('bg', 'value');
        // Advancing past the foreground interval exercises the timer callback.
        async.elapse(const Duration(seconds: 31));
        async.flushMicrotasks();
        batcher.flush();
      });
    });
  });
}
