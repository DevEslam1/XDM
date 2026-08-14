import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/provider/download_queue_provider.dart';

void main() {
  group('DownloadQueueProvider Tests (D-02 / D-03)', () {
    test('reorderQueue reorders task IDs correctly in queue (D-02)', () {
      final queueProvider = DownloadQueueProvider(maxConcurrentDownloads: 2);

      queueProvider.addToQueue('task_1');
      queueProvider.addToQueue('task_2');
      queueProvider.addToQueue('task_3');

      expect(
          queueProvider.queueTaskIds, equals(['task_1', 'task_2', 'task_3']));

      // Move task_3 to first position
      queueProvider.reorderQueue(2, 0);
      expect(
          queueProvider.queueTaskIds, equals(['task_3', 'task_1', 'task_2']));
    });
  });
}
