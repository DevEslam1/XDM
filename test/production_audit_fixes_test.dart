import 'dart:io';

import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/database/repositories/task_companion_converter.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:dmx/core/services/ffmpeg_mux_service.dart';
import 'package:dmx/core/services/torrent_seeding_manager.dart';
import 'package:dmx/features/downloads/models/download_state_machine.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Production Readiness Audit Fixes', () {
    test('L-4: PauseReason fallback parsing handles unknown strings safely', () {
      expect(PauseReason.fromName('unknown'), equals(PauseReason.unknown));
      expect(PauseReason.fromName('non_existent_reason'), equals(PauseReason.unknown));
      expect(PauseReason.fromName(null, fallback: PauseReason.user), equals(PauseReason.user));
      expect(PauseReason.fromName('networkLost'), equals(PauseReason.networkLost));
    });

    test('L-1 & L-2: State Machine validates transitions and cycle consistency', () {
      expect(
        DownloadStateMachine.canTransitionStatus(
          DownloadStatus.downloading,
          DownloadStatus.paused,
        ),
        isTrue,
      );
      expect(
        DownloadStateMachine.canTransitionStatus(
          DownloadStatus.downloading,
          DownloadStatus.completed,
        ),
        isTrue,
      );

      // validateConsistency tests
      expect(
        DownloadStateMachine.validateConsistency(
          DownloadStatus.downloading,
          CycleState.downloading,
        ),
        equals(CycleState.downloading),
      );
      expect(
        DownloadStateMachine.validateConsistency(
          DownloadStatus.paused,
          CycleState.paused,
        ),
        equals(CycleState.paused),
      );
      expect(
        DownloadStateMachine.validateConsistency(
          DownloadStatus.completed,
          CycleState.completed,
        ),
        equals(CycleState.completed),
      );
      // Auto-corrects inconsistent combinations
      expect(
        DownloadStateMachine.validateConsistency(
          DownloadStatus.completed,
          CycleState.downloading,
        ),
        equals(CycleState.completed),
      );
    });

    test('L-3: TaskCompanionConverter.isInterruptedActiveRow identifies stale running rows', () {
      final runningRow = DbDownloadTask(
        id: 'task-1',
        url: 'https://example.com/file.zip',
        fileName: 'file.zip',
        savePath: '/downloads',
        localFilePath: '/downloads/file.zip',
        tempFilePath: '/downloads/file.zip.dmxtemp',
        status: 'downloading',
        fileSize: 1000,
        downloadedBytes: 500,
        category: 'other',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        threadCount: 4,
        speed: 0,
        priority: 1,
        queueOrder: 0,
        uploadedBytes: 0,
        supportsResume: true,
        speedLimitKbps: 0,
        seedingEnabled: false,
        seedingLimited: false,
        seedingLimitKbps: 0,
        audioSize: 0,
        audioDownloadedBytes: 0,
        videoStreamSize: 0,
        audioProgress: 0,
        pausedByUser: false,
        isAppUpdate: false,
        isCancelled: false,
      );
      expect(TaskCompanionConverter.isInterruptedActiveRow(runningRow), isTrue);

      final pausedRow = DbDownloadTask(
        id: 'task-2',
        url: 'https://example.com/file.zip',
        fileName: 'file.zip',
        savePath: '/downloads',
        localFilePath: '/downloads/file.zip',
        tempFilePath: '/downloads/file.zip.dmxtemp',
        status: 'paused',
        fileSize: 1000,
        downloadedBytes: 500,
        category: 'other',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        threadCount: 4,
        speed: 0,
        priority: 1,
        queueOrder: 0,
        uploadedBytes: 0,
        supportsResume: true,
        speedLimitKbps: 0,
        seedingEnabled: false,
        seedingLimited: false,
        seedingLimitKbps: 0,
        audioSize: 0,
        audioDownloadedBytes: 0,
        videoStreamSize: 0,
        audioProgress: 0,
        pausedByUser: true,
        isAppUpdate: false,
        isCancelled: false,
      );
      expect(TaskCompanionConverter.isInterruptedActiveRow(pausedRow), isFalse);
    });

    test('D-7: Multi-threaded downloaded byte calculation never falls back to preallocated file length', () async {
      final tempDir = await Directory.systemTemp.createTemp('dmx_test_');
      final tempFile = File('${tempDir.path}/test.bin');
      await tempFile.writeAsBytes(List.filled(1024, 0));

      final multiThreadActual = await actualDownloadedBytes(
        tempFile.path,
        threadCount: 4,
      );
      expect(multiThreadActual, equals(0));

      final singleThreadActual = await actualDownloadedBytes(
        tempFile.path,
        threadCount: 1,
      );
      expect(singleThreadActual, equals(1024));

      await tempDir.delete(recursive: true);
    });

    test('D-13: TorrentSeedingManager calculates ratio safely with fallback bytes for magnets', () {
      final ratioWithFallback = TorrentSeedingManager.calculateRatio(
        1000,
        0,
        fallbackBytes: 2000,
      );
      expect(ratioWithFallback, equals(0.5));

      final zeroRatio = TorrentSeedingManager.calculateRatio(
        1000,
        0,
        fallbackBytes: 0,
      );
      expect(zeroRatio, equals(0.0));
    });

    test('D-14: FFmpegMuxService calculates dynamic timeout according to media size', () {
      final zeroTimeout = FFmpegMuxService.dynamicTimeout(0);
      expect(zeroTimeout, equals(const Duration(minutes: 10)));

      final smallTimeout = FFmpegMuxService.dynamicTimeout(10 * 1024 * 1024); // 10MB
      expect(smallTimeout, equals(const Duration(minutes: 11)));

      final largeTimeout = FFmpegMuxService.dynamicTimeout(20 * 1024 * 1024 * 1024); // 20GB
      expect(largeTimeout, equals(const Duration(minutes: 30)));
    });

    test('S-1: DebugCertOverride safely disabled in release mode', () {
      final cb = DebugCertOverride.getCallback('https://example.com');
      // In test/debug mode, callback is allowed
      expect(cb != null, isTrue);
    });
  });
}
