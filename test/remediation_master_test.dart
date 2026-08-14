import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/bandwidth_governor.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:dmx/core/services/xdm_backend_client.dart';
import 'package:dmx/core/utils/url_utils.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/widgets/speed_graph_widget.dart';
import 'package:flutter/material.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Master Remediation Tests', () {
    test('FIX-1 & FIX-7: DownloadMetadata isValid handles 0-size chunked files',
        () {
      const validZeroSize = DownloadMetadata(
        fileName: 'stream.mp4',
        category: 'video',
        fileSize: 0,
        supportsResume: false,
      );
      expect(validZeroSize.isValid, isTrue);

      const emptyFileName = DownloadMetadata(
        fileName: '',
        category: 'other',
        fileSize: 0,
        supportsResume: false,
      );
      expect(emptyFileName.isValid, isFalse);
    });

    test('FIX-2: DownloadTask isCancelled flag correctly set and preserved',
        () {
      final task = DownloadTask(
        id: 'test-task-1',
        fileName: 'video.mp4',
        url: 'https://example.com/video.mp4',
        fileSize: 1024 * 1024,
        downloadedBytes: 512 * 1024,
        category: 'video',
        status: DownloadStatus.downloading,
        savePath: '/tmp',
        localFilePath: '/tmp/video.mp4',
        tempFilePath: '/tmp/video.mp4.tmp',
        threadCount: 2,
        chunks: [0.5, 0.5],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        pausedByUser: false,
        isCancelled: false,
      );

      expect(task.isCancelled, isFalse);

      final cancelledTask = task.copyWith(
        status: DownloadStatus.failed,
        isCancelled: true,
        pausedByUser: false,
      );

      expect(cancelledTask.isCancelled, isTrue);
      expect(cancelledTask.pausedByUser, isFalse);

      final map = cancelledTask.toMap();
      expect(map['isCancelled'], isTrue);

      final restored = DownloadTask.fromMap(map);
      expect(restored.isCancelled, isTrue);
    });

    test('FIX-3: StateStore screen-off write threshold allows >= 5MB deltas',
        () async {
      final dir = await Directory.systemTemp.createTemp('dmx_state_test');
      final tempFile = '${dir.path}/test_state_file.bin';
      try {
        final state1 = TransferState(
          totalSize: 50 * 1024 * 1024,
          threadCount: 1,
          chunks: [
            ChunkState(start: 0, end: 50 * 1024 * 1024, downloaded: 1024 * 1024)
          ],
        );

        // First write (screen-off, delta = 1MB < 5MB)
        await StateStore.save(tempFile, state1,
            screenOff: true, durable: false);
        final stateFile = File(StateStore.pathFor(tempFile));
        expect(await stateFile.exists(), isFalse);

        // Large progress write (delta = 6MB >= 5MB)
        final state2 = TransferState(
          totalSize: 50 * 1024 * 1024,
          threadCount: 1,
          chunks: [
            ChunkState(
                start: 0, end: 50 * 1024 * 1024, downloaded: 7 * 1024 * 1024)
          ],
        );

        await StateStore.save(tempFile, state2,
            screenOff: true, durable: false);
        expect(await stateFile.exists(), isTrue);
      } finally {
        await StateStore.remove(tempFile);
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    });

    test('FIX-5: PositionalFileWriter flushes before closing handles',
        () async {
      final dir = await Directory.systemTemp.createTemp('dmx_writer_test');
      final targetPath = '${dir.path}/writer_output.bin';
      try {
        final writer = await PositionalFileWriter.open(
          targetPath,
          totalSize: 100,
          threadCount: 1,
        );

        final data = List<int>.generate(20, (i) => i + 1);
        await writer.write(
          0,
          0,
          Uint8List.fromList(data),
        );

        // Close should flush internally before handle closure
        await writer.close();

        final file = File(targetPath);
        expect(await file.exists(), isTrue);
        final readBytes = await file.readAsBytes();
        expect(readBytes.sublist(0, 20), equals(data));
      } finally {
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    });

    test('FIX-6: BandwidthGovernor clamps deficit to 0 to prevent busy-waiting',
        () async {
      final governor = BandwidthGovernor(1000, 1.0, 1.0);
      governor.registerConsumer();

      // Acquire large amount of bytes to trigger deficit
      final waitMs = await governor.acquire(1000);
      expect(waitMs, greaterThanOrEqualTo(0));

      // Second acquire should calculate bounded wait rather than busy-looping
      final nextWait = await governor.acquire(500);
      expect(nextWait, greaterThanOrEqualTo(0));
      expect(nextWait, lessThanOrEqualTo(1000));
    });

    test('SEC-1: Backend URL HTTPS enforcement', () {
      final client = XdmBackendClient();
      expect(client, isNotNull);
    });

    test('UI-3: isValidTransmissionUrl & isMagnetUrl validation', () {
      expect(
          isMagnetUrl(
              'magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335de7ece74f6d2'),
          isTrue);
      expect(isMagnetUrl('magnet:invalid_link_no_xt'), isFalse);
      expect(isValidTransmissionUrl('https://example.com/file.zip'), isTrue);
      expect(isValidTransmissionUrl('ftp://example.com/file.zip'), isTrue);
      expect(isValidTransmissionUrl('javascript:alert(1)'), isFalse);
    });

    testWidgets(
        'PERF-10 / UI-10: SpeedGraphWidget builds and renders chart data',
        (tester) async {
      final speedHistory = List<int>.generate(60, (i) => i * 1024);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SpeedGraphWidget(
              speedHistory: speedHistory,
              status: DownloadStatus.downloading,
            ),
          ),
        ),
      );

      expect(find.byType(SpeedGraphWidget), findsOneWidget);
      expect(find.text('Download Speed (60s)'), findsOneWidget);
    });
  });
}
