import 'dart:io';
import 'package:dmx/core/domain/cycle_state.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('journal_recovery_test_');
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Task 1: DownloadJournal Kill/Restart Recovery Matrix', () {
    test('Recovers state in DOWNLOADING lifecycle state', () async {
      final tempFile = p.join(tempDir.path, 'video.mp4');
      final state = TransferState(
        totalSize: 10485760,
        threadCount: 2,
        chunks: [
          ChunkState(start: 0, end: 5242879, downloaded: 2000000),
          ChunkState(start: 5242880, end: 10485759, downloaded: 1500000),
        ],
        url: 'https://example.com/video.mp4',
        etag: '"test-etag"',
        cycleState: CycleState.downloading.name,
      );

      await StateStore.save(tempFile, state,
          durable: true, taskId: 'task-dl-1');

      final loaded = await StateStore.load(tempFile, taskId: 'task-dl-1');
      expect(loaded, isNotNull);
      expect(loaded!.downloadedBytes, equals(3500000));
      expect(loaded.cycleState, equals(CycleState.downloading.name));
      expect(loaded.chunks.length, equals(2));
    });

    test('Recovers state in PAUSED lifecycle state', () async {
      final tempFile = p.join(tempDir.path, 'archive.zip');
      final state = TransferState(
        totalSize: 50000000,
        threadCount: 4,
        chunks: [
          ChunkState(start: 0, end: 12499999, downloaded: 12500000),
          ChunkState(start: 12500000, end: 24999999, downloaded: 5000000),
          ChunkState(start: 25000000, end: 37499999, downloaded: 0),
          ChunkState(start: 37500000, end: 49999999, downloaded: 0),
        ],
        url: 'https://example.com/archive.zip',
        status: DmxStateStatus.paused,
        cycleState: CycleState.paused.name,
      );

      await StateStore.save(tempFile, state,
          durable: true, taskId: 'task-pause-1');

      final loaded = await StateStore.load(tempFile, taskId: 'task-pause-1');
      expect(loaded, isNotNull);
      expect(loaded!.status, equals(DmxStateStatus.paused));
      expect(loaded.cycleState, equals(CycleState.paused.name));
      expect(loaded.chunks[0].isComplete, isTrue);
    });

    test('Recovers state in RETRYING lifecycle state', () async {
      final tempFile = p.join(tempDir.path, 'setup.exe');
      final state = TransferState(
        totalSize: 20000000,
        threadCount: 1,
        chunks: [
          ChunkState(start: 0, end: 19999999, downloaded: 8000000),
        ],
        url: 'https://example.com/setup.exe',
        cycleState: CycleState.retrying.name,
      );

      await StateStore.save(tempFile, state,
          durable: true, taskId: 'task-retry-1');

      final loaded = await StateStore.load(tempFile, taskId: 'task-retry-1');
      expect(loaded, isNotNull);
      expect(loaded!.cycleState, equals(CycleState.retrying.name));
      expect(loaded.downloadedBytes, equals(8000000));
    });

    test('Recovers state in MERGING lifecycle state', () async {
      final tempFile = p.join(tempDir.path, 'yt_video.mp4');
      final state = TransferState(
        totalSize: 100000000,
        threadCount: 2,
        chunks: [
          ChunkState(start: 0, end: 49999999, downloaded: 50000000),
          ChunkState(start: 50000000, end: 99999999, downloaded: 50000000),
        ],
        url: 'https://example.com/yt_video.mp4',
        cycleState: CycleState.merging.name,
      );

      await StateStore.save(tempFile, state,
          durable: true, taskId: 'task-merge-1');

      final loaded = await StateStore.load(tempFile, taskId: 'task-merge-1');
      expect(loaded, isNotNull);
      expect(loaded!.cycleState, equals(CycleState.merging.name));
      expect(loaded.isComplete, isTrue);
    });

    test('Recovers state in VERIFYING lifecycle state', () async {
      final tempFile = p.join(tempDir.path, 'os_image.iso');
      final state = TransferState(
        totalSize: 500000000,
        threadCount: 4,
        chunks: [
          ChunkState(start: 0, end: 124999999, downloaded: 125000000),
          ChunkState(start: 125000000, end: 249999999, downloaded: 125000000),
          ChunkState(start: 250000000, end: 374999999, downloaded: 125000000),
          ChunkState(start: 375000000, end: 499999999, downloaded: 125000000),
        ],
        url: 'https://example.com/os_image.iso',
        cycleState: CycleState.verifying.name,
      );

      await StateStore.save(tempFile, state,
          durable: true, taskId: 'task-verify-1');

      final loaded = await StateStore.load(tempFile, taskId: 'task-verify-1');
      expect(loaded, isNotNull);
      expect(loaded!.cycleState, equals(CycleState.verifying.name));
      expect(loaded.isComplete, isTrue);
    });

    test('Recovers state in METADATA_FETCHING lifecycle state', () async {
      final tempFile = p.join(tempDir.path, 'torrent_item.torrent');
      final state = TransferState(
        totalSize: 0,
        threadCount: 1,
        chunks: [
          ChunkState.indeterminate(downloaded: 0),
        ],
        url: 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
        cycleState: CycleState.fetchingMetadata.name,
      );

      await StateStore.save(tempFile, state,
          durable: true, taskId: 'task-meta-1');

      final loaded = await StateStore.load(tempFile, taskId: 'task-meta-1');
      expect(loaded, isNotNull);
      expect(loaded!.cycleState, equals(CycleState.fetchingMetadata.name));
    });

    test(
        'Recovers from .tmp state file if primary state file is corrupt or missing',
        () async {
      final tempFile = p.join(tempDir.path, 'corrupt_test.bin');
      final statePath = StateStore.pathFor(tempFile, taskId: 'task-tmp-1');
      final tmpFile = File('$statePath.tmp');

      await tmpFile.writeAsString(
          '{"v":3,"totalSize":5000000,"threadCount":1,"chunks":[{"start":0,"end":4999999,"downloaded":2500000}],"status":"active","cycleState":"downloading"}');

      final loaded = await StateStore.load(tempFile, taskId: 'task-tmp-1');
      expect(loaded, isNotNull);
      expect(loaded!.downloadedBytes, equals(2500000));
      expect(loaded.cycleState, equals(CycleState.downloading.name));
    });
  });
}
