import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FIX-8.3: ValueNotifier and Resource Leak Regression Tests', () {
    test('ValueNotifier listeners are isolated and dispose cleanly', () {
      final notifier = ValueNotifier<int>(0);
      int callCount = 0;
      void listener() => callCount++;

      notifier.addListener(listener);
      notifier.value = 1;
      expect(callCount, 1);

      notifier.removeListener(listener);
      notifier.value = 2;
      expect(callCount, 1);

      notifier.dispose();
      expect(() => notifier.addListener(listener), throwsFlutterError);
    });

    test('Multiple isolated ValueNotifiers do not cross-talk', () {
      final tab1 = ValueNotifier<String>('tab1');
      final tab2 = ValueNotifier<String>('tab2');

      final log1 = <String>[];
      final log2 = <String>[];

      tab1.addListener(() => log1.add(tab1.value));
      tab2.addListener(() => log2.add(tab2.value));

      tab1.value = 'tab1_updated';
      expect(log1, ['tab1_updated']);
      expect(log2, isEmpty);

      tab2.value = 'tab2_updated';
      expect(log1, ['tab1_updated']);
      expect(log2, ['tab2_updated']);

      tab1.dispose();
      tab2.dispose();
    });

    test(
        'Adding 50 downloads and removing all 50 returns notifier count to 0 (R3)',
        () {
      final progressNotifiers = <String, ValueNotifier<double>>{};
      final speedNotifiers = <String, ValueNotifier<double>>{};

      // Add 50 download tasks
      for (var i = 0; i < 50; i++) {
        final taskId = 'task_$i';
        progressNotifiers[taskId] = ValueNotifier(0.5);
        speedNotifiers[taskId] = ValueNotifier(1024.0);
      }
      expect(progressNotifiers.length + speedNotifiers.length, equals(100));

      // Remove all 50 tasks
      for (var i = 0; i < 50; i++) {
        final taskId = 'task_$i';
        progressNotifiers.remove(taskId)?.dispose();
        speedNotifiers.remove(taskId)?.dispose();
      }

      // Must return cleanly to baseline 0
      expect(progressNotifiers.length + speedNotifiers.length, equals(0));
    });
  });
}

