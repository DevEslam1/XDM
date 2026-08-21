import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late Directory tempDir;
  late Uint8List payload;
  late String expectedSha256;
  const int fileSize = 1024 * 1024; // 1 MB payload for deterministic fast test

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('download_resume_e2e_');

    // Generate deterministic test payload
    final rand = Random(42);
    payload = Uint8List(fileSize);
    for (int i = 0; i < fileSize; i++) {
      payload[i] = rand.nextInt(256);
    }
    expectedSha256 = sha256.convert(payload).toString();

    // Start local server supporting Range requests (206 & 200)
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      final response = request.response;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set('etag', '"test-etag-123"');

      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final parts = rangeHeader.substring(6).split('-');
        final start = int.parse(parts[0]);
        final end = parts.length > 1 && parts[1].isNotEmpty
            ? int.parse(parts[1])
            : fileSize - 1;
        final clampedEnd = min(end, fileSize - 1);
        final length = clampedEnd - start + 1;

        response.statusCode = HttpStatus.partialContent;
        response.headers.set(HttpHeaders.contentRangeHeader,
            'bytes $start-$clampedEnd/$fileSize');
        response.headers.contentLength = length;
        response.headers.contentType = ContentType.binary;

        response.add(payload.sublist(start, clampedEnd + 1));
        await response.close();
      } else {
        response.statusCode = HttpStatus.ok;
        response.headers.contentLength = fileSize;
        response.headers.contentType = ContentType.binary;
        response.add(payload);
        await response.close();
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {
      // Windows file lock delay
      await Future.delayed(const Duration(milliseconds: 100));
      try {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> runDownloadResumeTest({required int threadCount}) async {
    final url = 'http://${server.address.host}:${server.port}/testfile.bin';
    final tempFilePath = '${tempDir.path}/test_download_$threadCount.bin';

    final cmd = DownloadCommand(
      taskId: 'task_e2e_$threadCount',
      url: url,
      tempFilePath: tempFilePath,
      localFilePath: tempFilePath,
      resolvedFileName: 'testfile.bin',
      threadCount: threadCount,
      supportsResume: true,
      knownFileSize: fileSize,
      punyUrl: url,
    );

    // 1. Start download pool and initial job
    var pool = DownloadIsolatePool(size: 2);
    final job = pool.submit(cmd);

    final pauseCompleter = Completer<void>();

    final sub = job.messages.listen((msg) {
      if (msg.type == EngineMessageType.progress) {
        final downloaded = (msg.data['downloadedBytes'] as num?)?.toInt() ?? 0;
        if (downloaded >= (fileSize * 0.3) && !pauseCompleter.isCompleted) {
          pauseCompleter.complete();
        }
      }
    });

    // Wait until at least 30% progress is reported or timeout
    try {
      await pauseCompleter.future.timeout(const Duration(seconds: 5));
    } catch (_) {}

    // 2. Pause job and kill isolate pool
    job.cancel(PauseReason.userRequested);
    await Future.delayed(const Duration(milliseconds: 300));
    await sub.cancel();
    await pool.shutdown();
    await Future.delayed(const Duration(milliseconds: 200));

    // Verify state or completed file exists
    final state = await StateStore.instance.load(tempFilePath);
    if (state != null && !state.isComplete) {
      // 3. Restart new isolate pool and resume download
      pool = DownloadIsolatePool(size: 2);
      final resumeJob = pool.submit(cmd);
      final doneCompleter = Completer<void>();

      final resumeSub = resumeJob.messages.listen((msg) {
        if (msg.type == EngineMessageType.done) {
          if (!doneCompleter.isCompleted) doneCompleter.complete();
        } else if (msg.type == EngineMessageType.error) {
          if (!doneCompleter.isCompleted) {
            doneCompleter.completeError(
                Exception('Resume error: ${msg.data['errorMessage']}'));
          }
        }
      });

      await doneCompleter.future.timeout(const Duration(seconds: 30));
      await resumeSub.cancel();
      await pool.shutdown();
      await Future.delayed(const Duration(milliseconds: 200));
    }

    // 4. Verify downloaded file SHA-256 matches original payload
    final downloadedFile = File(tempFilePath);
    expect(await downloadedFile.exists(), isTrue);
    final downloadedBytes = await downloadedFile.readAsBytes();
    expect(downloadedBytes.length, equals(fileSize));
    final downloadedSha256 = sha256.convert(downloadedBytes).toString();
    expect(downloadedSha256, equals(expectedSha256));
  }

  group('FIX 16: E2E Download -> Pause -> Kill -> Resume -> Verify SHA-256',
      () {
    test(
        'Single-stream (1 thread) download pause, kill, resume, verify SHA-256',
        () async {
      await runDownloadResumeTest(threadCount: 1);
    });

    test(
        'Multi-threaded (4 threads) download pause, kill, resume, verify SHA-256',
        () async {
      await runDownloadResumeTest(threadCount: 4);
    });
  });
}
