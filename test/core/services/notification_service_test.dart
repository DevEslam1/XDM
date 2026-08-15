import 'package:dmx/core/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NotificationService', () {
    test('singleton instance is consistent', () {
      final s1 = NotificationService();
      final s2 = NotificationService();
      expect(identical(s1, s2), true);
    });

    test('isSupported evaluates platform capability safely', () {
      expect(NotificationService.isSupported, isA<bool>());
    });

    test('action stream is non-null BroadcastStream', () {
      final service = NotificationService();
      expect(service.onActionTapped, isNotNull);
      expect(service.onActionTapped.isBroadcast, true);
    });

    test('cancelNotification executes gracefully for valid ID', () async {
      final service = NotificationService();
      expect(() => service.cancelNotification(100), returnsNormally);
    });

    test('cancelAll does not throw', () async {
      final service = NotificationService();
      expect(() => service.cancelAll(), returnsNormally);
    });
  });
}
