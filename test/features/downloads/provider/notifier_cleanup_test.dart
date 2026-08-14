import 'package:flutter_test/flutter_test.dart';
import '../../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DownloadProvider Notifier Cleanup (NEW-01)', () {
    test(
        'disposeTaskNotifier removes and disposes progress and speed notifiers',
        () {
      final provider = createMockDownloadProvider();

      final pNotif = provider.progressNotifier('task_123');
      final sNotif = provider.speedNotifier('task_123');

      expect(pNotif.value, equals(0.0));
      expect(sNotif.value, equals(0.0));

      provider.disposeTaskNotifier('task_123');

      // Subsequent access creates a new notifier rather than returning the disposed one
      final newPNotif = provider.progressNotifier('task_123');
      expect(identical(pNotif, newPNotif), isFalse);
    });
  });
}
