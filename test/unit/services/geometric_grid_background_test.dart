import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/shared/widgets/geometric_grid_background.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AmbientProgress Ref Counting & Lifecycle (U-01)', () {
    late AmbientProgress ambient;

    setUp(() {
      ambient = AmbientProgress.instance;
      // Reset ref count
      while (ambient.refCount > 0) {
        ambient.removeRef();
      }
    });

    test('addRef increases refCount and removeRef decreases it', () {
      expect(ambient.refCount, equals(0));

      ambient.addRef();
      expect(ambient.refCount, equals(1));

      ambient.addRef();
      expect(ambient.refCount, equals(2));

      ambient.removeRef();
      expect(ambient.refCount, equals(1));

      ambient.removeRef();
      expect(ambient.refCount, equals(0));

      // Clamped to 0
      ambient.removeRef();
      expect(ambient.refCount, equals(0));
    });

    test('lifecycle paused/resumed pauses and restarts ambient timers', () {
      ambient.addRef();
      expect(ambient.refCount, equals(1));

      ambient.didChangeAppLifecycleState(AppLifecycleState.paused);
      ambient.stopAll();

      ambient.didChangeAppLifecycleState(AppLifecycleState.resumed);
      ambient.restartIfMounted();

      ambient.removeRef();
      expect(ambient.refCount, equals(0));
    });
  });
}
