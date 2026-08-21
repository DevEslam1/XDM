import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/database/repositories/task_companion_converter.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late HttpServer server;
  late Uint8List originalPayload;
  late String originalSha256;
  const fileSize = 128 * 1024; // 128 KB

  setUp(() async {
    HttpOverrides.global = null;
    tempDir = await Directory.systemTemp.createTemp('http_characterization_test_');
    originalPayload = Uint8List.fromList(
      List.generate(fileSize, (i) => (i * 31 + 7) % 256),
    );
    originalSha256 = sha256.convert(originalPayload).toString();
  });

  tearDown(() async {
    try {
      await server.close(force: true);
    } catch (_) {}
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('Money Test (D2): Stale journal after server identity change resets cleanly without zero-holes', () async {
    var currentEtag = '"v1"';
    var serverPayload = originalPayload;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      final rangeHeader = request.headers.value('range');
      final ifRange = request.headers.value('if-range');

      if (ifRange != null && ifRange != currentEtag) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.set('ETag', currentEtag);
        request.response.headers.set('Content-Length', serverPayload.length);
        request.response.headers.set('Accept-Ranges', 'bytes');
        request.response.add(serverPayload);
        await request.response.close();
        return;
      }

      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
        if (match != null) {
          final start = int.parse(match.group(1)!);
          final endStr = match.group(2);
          final end = (endStr != null && endStr.isNotEmpty)
              ? int.parse(endStr)
              : serverPayload.length - 1;

          final slice = serverPayload.sublist(start, end + 1);
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set('ETag', currentEtag);
          request.response.headers.set('Content-Range', 'bytes $start-$end/${serverPayload.length}');
          request.response.headers.set('Content-Length', slice.length);
          request.response.headers.set('Accept-Ranges', 'bytes');
          request.response.add(slice);
          await request.response.close();
          return;
        }
      }

      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set('ETag', currentEtag);
      request.response.headers.set('Content-Length', serverPayload.length);
      request.response.headers.set('Accept-Ranges', 'bytes');
      request.response.add(serverPayload);
      await request.response.close();
    });

    final serverUrl = 'http://127.0.0.1:${server.port}/testfile.bin';
    final targetPath = '${tempDir.path}/testfile.bin';
    final tempFilePath = '${tempDir.path}/testfile.bin.tmp';

    final partialState = TransferState(
      totalSize: fileSize,
      threadCount: 2,
      etag: '"v1"',
      chunks: [
        ChunkState(start: 0, end: 65535, downloaded: 25000),
        ChunkState(start: 65536, end: 131071, downloaded: 25000),
      ],
    );
    await StateStore.save(tempFilePath, partialState, durable: true);

    final journal = DownloadJournal('$tempFilePath.journal');
    await journal.open();
    await journal.writeInit(2, fileSize);
    await journal.writeCheckpoint([25000, 25000], fileSize);
    await journal.close();

    final tempFile = File(tempFilePath);
    await tempFile.writeAsBytes(originalPayload.sublist(0, 50000), flush: true);

    currentEtag = '"v2"';
    final updatedPayload = Uint8List.fromList(
      List.generate(fileSize, (i) => (i * 47 + 13) % 256),
    );
    serverPayload = updatedPayload;
    final updatedSha256 = sha256.convert(updatedPayload).toString();

    final cmd = DownloadCommand(
      taskId: 'money-test-1',
      url: serverUrl,
      punyUrl: serverUrl,
      localFilePath: targetPath,
      tempFilePath: tempFilePath,
      knownFileSize: fileSize,
      threadCount: 2,
      supportsResume: true,
    );

    final receivePort = ReceivePort();
    final job = HttpTransferJob(cmd, receivePort.sendPort);
    try {
      await job.run();
    } catch (_) {
      final restartJob = HttpTransferJob(cmd, receivePort.sendPort);
      await restartJob.run();
    } finally {
      receivePort.close();
    }

    final finalFile = File(targetPath);
    expect(await finalFile.exists(), isTrue);
    expect(await finalFile.length(), equals(fileSize));

    final downloadedBytes = await finalFile.readAsBytes();
    final actualSha256 = sha256.convert(downloadedBytes).toString();

    expect(actualSha256, equals(updatedSha256));
    expect(await File('$tempFilePath.journal').exists(), isFalse);
  });

  test('J3 & J4: Temp file externally truncated mid-multi-chunk does not produce sparse zero-holes', () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      final rangeHeader = request.headers.value('range');
      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
        if (match != null) {
          final start = int.parse(match.group(1)!);
          final endStr = match.group(2);
          final end = (endStr != null && endStr.isNotEmpty)
              ? int.parse(endStr)
              : originalPayload.length - 1;

          final slice = originalPayload.sublist(start, end + 1);
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set('Content-Range', 'bytes $start-$end/${originalPayload.length}');
          request.response.headers.set('Content-Length', slice.length);
          request.response.headers.set('Accept-Ranges', 'bytes');
          request.response.add(slice);
          await request.response.close();
          return;
        }
      }

      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set('Content-Length', originalPayload.length);
      request.response.headers.set('Accept-Ranges', 'bytes');
      request.response.add(originalPayload);
      await request.response.close();
    });

    final serverUrl = 'http://127.0.0.1:${server.port}/truncate_test.bin';
    final targetPath = '${tempDir.path}/truncate_test.bin';
    final tempFilePath = '${tempDir.path}/truncate_test.bin.tmp';

    final state = TransferState(
      totalSize: fileSize,
      threadCount: 2,
      chunks: [
        ChunkState(start: 0, end: 65535, downloaded: 30000),
        ChunkState(start: 65536, end: 131071, downloaded: 30000),
      ],
    );
    await StateStore.save(tempFilePath, state, durable: true);

    final journal = DownloadJournal('$tempFilePath.journal');
    await journal.open();
    await journal.writeInit(2, fileSize);
    await journal.writeCheckpoint([30000, 30000], fileSize);
    await journal.close();

    final tempFile = File(tempFilePath);
    await tempFile.writeAsBytes(originalPayload.sublist(0, 10000), flush: true);

    final cmd = DownloadCommand(
      taskId: 'truncate-test',
      url: serverUrl,
      punyUrl: serverUrl,
      localFilePath: targetPath,
      tempFilePath: tempFilePath,
      knownFileSize: fileSize,
      threadCount: 2,
      supportsResume: true,
    );

    final receivePort = ReceivePort();
    final job = HttpTransferJob(cmd, receivePort.sendPort);
    try {
      await job.run();
    } finally {
      receivePort.close();
    }

    final finalFile = File(targetPath);
    expect(await finalFile.exists(), isTrue);
    expect(await finalFile.length(), equals(fileSize));

    final downloadedBytes = await finalFile.readAsBytes();
    final actualSha256 = sha256.convert(downloadedBytes).toString();

    expect(actualSha256, equals(originalSha256));
  });

  test('J2: Journal is cleared after loadAndReconcileState replays it', () async {
    final tempFilePath = '${tempDir.path}/replay_clear.tmp';
    final state = TransferState(
      totalSize: 1000,
      threadCount: 2,
      chunks: [
        ChunkState(start: 0, end: 499, downloaded: 100),
        ChunkState(start: 500, end: 999, downloaded: 100),
      ],
    );
    await StateStore.save(tempFilePath, state, durable: true);

    await File(tempFilePath).writeAsBytes(List.filled(1000, 0), flush: true);

    final journal = DownloadJournal('$tempFilePath.journal');
    await journal.open();
    await journal.writeInit(2, 1000);
    await journal.writeCheckpoint([200, 250], 1000);
    await journal.close();

    expect(await File('$tempFilePath.journal').exists(), isTrue);

    final cmd = DownloadCommand(
      taskId: 'replay-test',
      url: 'https://example.com/test',
      punyUrl: 'https://example.com/test',
      localFilePath: '${tempDir.path}/test',
      tempFilePath: tempFilePath,
      knownFileSize: 1000,
      threadCount: 2,
      supportsResume: true,
    );

    final receivePort = ReceivePort();
    final job = HttpTransferJob(cmd, receivePort.sendPort);
    final reconciled = await job.loadAndReconcileState(Dio());
    receivePort.close();

    expect(reconciled.chunks[0].downloaded, equals(200));
    expect(reconciled.chunks[1].downloaded, equals(250));

    expect(await File('$tempFilePath.journal').exists(), isFalse);
  });

  test('Zombie Sweep: isInterruptedActiveRow converts active states to paused/interrupted on startup', () {
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

    final queuedRow = runningRow.copyWith(status: 'queued');
    final pausedRow = runningRow.copyWith(status: 'paused');
    final completedRow = runningRow.copyWith(status: 'completed');
    final failedRow = runningRow.copyWith(status: 'failed');

    expect(TaskCompanionConverter.isInterruptedActiveRow(runningRow), isTrue);
    expect(TaskCompanionConverter.isInterruptedActiveRow(queuedRow), isFalse);
    expect(TaskCompanionConverter.isInterruptedActiveRow(pausedRow), isFalse);
    expect(TaskCompanionConverter.isInterruptedActiveRow(completedRow), isFalse);
    expect(TaskCompanionConverter.isInterruptedActiveRow(failedRow), isFalse);
  });
}
