import 'package:dmx/core/services/ios_background_capability.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadTask _task() => DownloadTask(
      id: 'task-1',
      fileName: 'file.bin',
      url: 'https://example.com/file.bin',
      fileSize: 1024,
      downloadedBytes: 0,
      category: 'General',
      savePath: '/tmp',
      localFilePath: '/tmp/file.bin',
      tempFilePath: '/tmp/file.bin.dmx',
      threadCount: 1,
      chunks: const [],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      status: DownloadStatus.queued,
      cycleState: CycleState.downloading,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('IosBackgroundCapability', () {
    final capability = IosBackgroundCapability.instance;

    test('singleton is available', () {
      expect(capability, isNotNull);
    });

    test('isSupported is false on non-iOS hosts', () async {
      expect(await capability.isSupported(), isFalse);
    });

    test('start/pause/resume/cancel no-op when unsupported', () async {
      await capability.start(_task());
      await capability.pause('task-1');
      await capability.resume('task-1');
      await capability.cancel('task-1');
    });

    test('progressStream is empty on non-iOS hosts', () async {
      final events = await capability.progressStream().toList();
      expect(events, isEmpty);
    });
  });
}
