import 'dart:io';

import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LoggingService rolling file rotation (H19)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('log_rotation_test_');
    });

    tearDown(() async {
      LoggingService.dispose();
      // Allow the async IOSink close to release the file handle on Windows.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<void> writeLogFile(String name, int sizeBytes) async {
      final file = File('${tempDir.path}/$name');
      final sink = file.openWrite(mode: FileMode.write);
      // Deterministic chunk avoids a huge in-memory list.
      final chunk = List<int>.filled(64 * 1024, 0x41);
      var written = 0;
      while (written < sizeBytes) {
        final take = (sizeBytes - written).clamp(0, chunk.length);
        sink.add(chunk.sublist(0, take));
        written += take;
      }
      await sink.close();
    }

    test('logs written on init land in app_log.txt', () async {
      LoggingService.init(logDir: tempDir);
      final log = LoggingService.log('rotation.test');
      log.info('hello rotation');
      LoggingService.dispose();

      final logFile = File('${tempDir.path}/app_log.txt');
      expect(await logFile.exists(), isTrue);
      final content = await logFile.readAsString();
      expect(content, contains('hello rotation'));
    });

    test('a log larger than 5MB rotates to app_log.1.txt on next init',
        () async {
      await writeLogFile('app_log.txt', 5 * 1024 * 1024 + 1024);

      LoggingService.init(logDir: tempDir);

      final log1 = File('${tempDir.path}/app_log.1.txt');
      final log2 = File('${tempDir.path}/app_log.2.txt');
      final fresh = File('${tempDir.path}/app_log.txt');

      expect(await log1.exists(), isTrue);
      expect((await log1.length()), greaterThan(5 * 1024 * 1024));
      // The fresh log is empty and open for append.
      expect(await fresh.exists(), isTrue);
      expect(await fresh.length(), lessThan(1024));
      // No app_log.2.txt yet because only one rotation slot was populated.
      expect(await log2.exists(), isFalse);
    });

    test('existing app_log.1.txt shifts to app_log.2.txt during rotation',
        () async {
      await writeLogFile('app_log.txt', 5 * 1024 * 1024 + 1024);
      await writeLogFile('app_log.1.txt', 2048);

      LoggingService.init(logDir: tempDir);

      final log1 = File('${tempDir.path}/app_log.1.txt');
      final log2 = File('${tempDir.path}/app_log.2.txt');
      expect(await log1.exists(), isTrue);
      expect((await log1.length()), greaterThan(5 * 1024 * 1024));
      expect(await log2.exists(), isTrue);
      expect((await log2.length()), 2048);
    });

    test('small logs are not rotated on init', () async {
      await writeLogFile('app_log.txt', 4096);

      LoggingService.init(logDir: tempDir);

      final log1 = File('${tempDir.path}/app_log.1.txt');
      expect(await log1.exists(), isFalse);
    });

    test('release-log buffer flushes to the file on dispose', () async {
      LoggingService.init(logDir: tempDir);
      // Simulate a release-mode buffered entry (bypasses kReleaseMode gate).
      LoggingService.bufferReleaseLogForTesting('buffered-entry-xyz');
      expect(LoggingService.hasActiveTimer, isTrue);

      LoggingService.dispose();

      final logFile = File('${tempDir.path}/app_log.txt');
      final content = await logFile.readAsString();
      expect(content, contains('buffered-entry-xyz'));
    });
  });
}
