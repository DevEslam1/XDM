import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:flutter_test/flutter_test.dart';

/// Live start / pause / resume / data-loss check for the exact HTTP link
/// supplied for manual verification:
///
///   https://dl2.downloadly.ir/Files/Software/
///   Notepad_8.9.8.1_Multilingual_x86_Downloadly.ir.rar?nocache=1790609148
///
/// The CDN is unreachable from restricted CI sandboxes, so the test first
/// probes the host and skips (rather than fails) when it cannot connect. Run it
/// from a network with access to the origin to exercise the real engine.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // Real sockets.

  const testUrl = 'https://dl2.downloadly.ir/Files/Software/'
      'Notepad_8.9.8.1_Multilingual_x86_Downloadly.ir.rar'
      '?nocache=1790609148';

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dmx_live_notepad_');
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  Future<bool> hostReachable() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client
          .getUrl(Uri.parse(testUrl))
          .timeout(const Duration(seconds: 20));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final res = await req.close().timeout(const Duration(seconds: 20));
      await res.drain<void>();
      return res.statusCode == HttpStatus.ok ||
          res.statusCode == HttpStatus.partialContent;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<String> referenceSha256() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(testUrl));
      final res = await req.close();
      final digest = await res.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      return sha256.convert(digest).toString();
    } finally {
      client.close(force: true);
    }
  }

  test(
    'live HTTP start -> pause -> resume preserves every byte (Notepad rar)',
    () async {
      if (!await hostReachable()) {
        markTestSkipped('downloadly CDN unreachable from this network');
        return;
      }

      final tempFilePath = '${tempDir.path}/notepad.dmxpart';
      final cmd = DownloadCommand(
        taskId: 'live-notepad',
        url: testUrl,
        tempFilePath: tempFilePath,
        localFilePath: tempFilePath,
        resolvedFileName: 'Notepad_8.9.8.1_Multilingual_x86.rar',
        threadCount: 4,
        supportsResume: true,
        knownFileSize: 0,
        punyUrl: testUrl,
      );

      var pool = DownloadIsolatePool(size: 2);
      final job = pool.submit(cmd);

      final pauseSignal = Completer<void>();
      final sub = job.messages.listen((msg) {
        if (msg.type == EngineMessageType.progress) {
          final downloaded =
              (msg.data['downloadedBytes'] as num?)?.toInt() ?? 0;
          // Pause once a meaningful slice has landed mid-transfer.
          if (downloaded > 256 * 1024 && !pauseSignal.isCompleted) {
            pauseSignal.complete();
          }
        }
      });

      await pauseSignal.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () {},
      );

      job.cancel(PauseReason.userRequested);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await sub.cancel();
      await pool.shutdown();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final state =
          await StateStore.instance.load(tempFilePath, taskId: cmd.taskId);
      final pausedAt = state?.downloadedBytes ?? 0;

      if (state != null && !state.isComplete) {
        pool = DownloadIsolatePool(size: 2);
        final resumeJob = pool.submit(cmd);
        final done = Completer<void>();
        final resumeSub = resumeJob.messages.listen((msg) {
          if (msg.type == EngineMessageType.done) {
            if (!done.isCompleted) done.complete();
          } else if (msg.type == EngineMessageType.error) {
            if (!done.isCompleted) {
              done.completeError(
                Exception('Resume error: ${msg.data['errorMessage']}'),
              );
            }
          }
        });
        await done.future.timeout(const Duration(minutes: 5));
        await resumeSub.cancel();
        await pool.shutdown();
        await Future<void>.delayed(const Duration(milliseconds: 200));

        // Progress must never regress across pause/resume.
        final afterState =
            await StateStore.instance.load(tempFilePath, taskId: cmd.taskId);
        if (afterState != null && pausedAt > 0) {
          expect(afterState.downloadedBytes, greaterThanOrEqualTo(pausedAt),
              reason: 'resume lost previously downloaded bytes');
        }
      }

      final file = File(tempFilePath);
      expect(await file.exists(), isTrue);
      final actual = sha256.convert(await file.readAsBytes()).toString();
      final expected = await referenceSha256();
      expect(actual, equals(expected),
          reason: 'paused/resumed file differs from a clean download');
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
