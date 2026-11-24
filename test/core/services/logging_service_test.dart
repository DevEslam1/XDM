import 'dart:async';
import 'dart:io';

import 'package:dmx/core/services/logging_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => LoggingService.dispose());
  tearDown(() => LoggingService.dispose());

  group('LoggingService.sanitize', () {
    test('redacts bearer and basic credentials', () {
      expect(LoggingService.sanitize('Bearer abc123'), 'Bearer [REDACTED]');
      expect(LoggingService.sanitize('Basic dXNlcjpwYXNz'), 'Basic [REDACTED]');
    });

    test('redacts sensitive key/value pairs', () {
      expect(LoggingService.sanitize('api_key=secret'), 'api_key=[REDACTED]');
      expect(LoggingService.sanitize('token=abc&x=1'), 'token=[REDACTED]&x=1');
      expect(LoggingService.sanitize('x password=hunter2'),
          'x password=[REDACTED]');
    });

    test('redacts JWTs', () {
      final jwt = '${'a' * 25}.${'b' * 25}.${'c' * 25}';
      expect(LoggingService.sanitize('auth $jwt'), contains('[JWT REDACTED]'));
    });

    test('redacts cookie headers', () {
      expect(
        LoggingService.sanitize('Cookie: session=abc; other=1'),
        contains('Cookie: [REDACTED]'),
      );
    });

    test('redacts userinfo in URLs', () {
      expect(
        LoggingService.sanitize('https://user:pass@example.com/p'),
        contains('://[REDACTED]:[REDACTED]@'),
      );
    });

    test('leaves harmless strings untouched', () {
      expect(LoggingService.sanitize('download complete'), 'download complete');
    });
  });

  group('LoggingService lifecycle', () {
    test('logger returns a usable logger', () {
      final log = LoggingService.logger('unit');
      expect(log, isNotNull);
      log.info('hello');
    });

    test('init with a log directory writes a sanitized file', () async {
      final dir = await Directory.systemTemp.createTemp('dmx_logging_test_');
      try {
        LoggingService.init(logDir: dir, overrideLevel: Level.ALL);
        LoggingService.log('unit').warning('token=supersecret');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        LoggingService.closeFileLogging();

        final file = File('${dir.path}/app_log.txt');
        expect(await file.exists(), isTrue);
        final content = await file.readAsString();
        expect(content, contains('[REDACTED]'));
      } finally {
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
    });

    test('release buffer schedules and cancels a flush timer', () {
      LoggingService.init(overrideLevel: Level.ALL);
      LoggingService.bufferReleaseLogForTesting('buffered-entry');
      expect(LoggingService.hasActiveTimer, isTrue);
      LoggingService.flushLogBuffer();
      LoggingService.dispose();
      expect(LoggingService.hasActiveTimer, isFalse);
    });

    test('flush timer callback drains the release buffer', () {
      fakeAsync((async) {
        LoggingService.init(overrideLevel: Level.ALL);
        LoggingService.bufferReleaseLogForTesting('flush-me');
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 31));
        async.flushMicrotasks();
        LoggingService.dispose();
      });
    });

    test('setReleaseFlushTimerForTesting installs a timer', () {
      final timer = Timer(const Duration(hours: 1), () {});
      LoggingService.setReleaseFlushTimerForTesting(timer);
      expect(LoggingService.hasActiveTimer, isTrue);
    });

    test('adaptedIntervalForTesting is positive', () {
      expect(
        LoggingService.adaptedIntervalForTesting(),
        greaterThan(Duration.zero),
      );
    });

    test('redactUrl delegates to sanitize', () {
      expect(LoggingService.redactUrl('u?token=abc'), contains('[REDACTED]'));
    });

    test('init rotates an oversized existing log file', () async {
      final dir = await Directory.systemTemp.createTemp('dmx_log_rotate_');
      try {
        await File('${dir.path}/app_log.txt')
            .writeAsBytes(List<int>.filled(6 * 1024 * 1024, 65));
        LoggingService.init(logDir: dir, overrideLevel: Level.ALL);
        LoggingService.closeFileLogging();

        expect(await File('${dir.path}/app_log.1.txt').exists(), isTrue);
      } finally {
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
    });

    test('trace extension writes at finest level', () {
      LoggingService.init(overrideLevel: Level.ALL);
      LoggingService.log('trace.test').trace('trace message');
    });
  });
}
