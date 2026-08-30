import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/notification_service.dart';

import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('NotificationService Action Stream & Queue', () {
    test('Actions are buffered when no listeners are active', () async {
      final service = NotificationService();

      // Trigger actions without subscriber
      service.dispatchActionForTest({'action': 'pause', 'taskId': 'task_1'});
      service.dispatchActionForTest({'action': 'resume', 'taskId': 'task_2'});

      final received = <Map<String, String>>[];
      final sub = service.onActionTapped.listen(received.add);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(received.length, equals(2));
      expect(received[0]['taskId'], equals('task_1'));
      expect(received[1]['taskId'], equals('task_2'));

      await sub.cancel();
    });

    test('Buffer caps at maximum 50 actions on overflow', () async {
      final service = NotificationService();

      for (var i = 0; i < 60; i++) {
        service.dispatchActionForTest({'action': 'open', 'taskId': 'task_$i'});
      }

      final received = <Map<String, String>>[];
      final sub = service.onActionTapped.listen(received.add);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(received.length, equals(50));
      // First 10 should have been dropped (0..9 dropped, 10..59 kept)
      expect(received.first['taskId'], equals('task_10'));
      expect(received.last['taskId'], equals('task_59'));

      await sub.cancel();
    });

    test('Rapid subscribe and unsubscribe does not lose active events',
        () async {
      final service = NotificationService();

      service.dispatchActionForTest({'action': 'pause', 'taskId': 'task_rap_1'});

      final sub1 = service.onActionTapped.listen((_) {});
      await sub1.cancel();

      service.dispatchActionForTest({'action': 'resume', 'taskId': 'task_rap_2'});

      final received = <Map<String, String>>[];
      final sub2 = service.onActionTapped.listen(received.add);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(received.any((m) => m['taskId'] == 'task_rap_2'), isTrue);

      await sub2.cancel();
    });

    test('Concurrent action submission is handled safely', () async {
      final service = NotificationService();
      final received = <Map<String, String>>[];
      final sub = service.onActionTapped.listen(received.add);

      await Future.wait([
        Future(() => service
            .dispatchActionForTest({'action': 'pause', 'taskId': 'concurrent_1'})),
        Future(() => service
            .dispatchActionForTest({'action': 'resume', 'taskId': 'concurrent_2'})),
        Future(() => service
            .dispatchActionForTest({'action': 'stop', 'taskId': 'concurrent_3'})),
      ]);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(received.length, equals(3));

      await sub.cancel();
    });
  });
}

extension NotificationServiceTestExtension on NotificationService {
  void dispatchActionForTest(Map<String, String> event) {
    // Access private _addAction via public method wrapper or mirror
    // NotificationService exposes internal action processing
    // ignore: invalid_use_of_visible_for_testing_member
    handleNotificationActionForTest(event);
  }
}
