import 'dart:io';

import 'package:dmx/core/services/download_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Disk Space Check', () {
    test('hasEnoughDiskSpace returns true when space is sufficient', () async {
      final engine = DownloadEngine(enableCleanupTimer: false);
      final tempDir =
          await Directory.systemTemp.createTemp('dmx_space_sufficient');
      addTearDown(() {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final result = await engine.hasEnoughDiskSpace(tempDir.path, 1024);
      expect(result, isTrue);
    });

    test('hasEnoughDiskSpace returns false (fail-safe) when check throws',
        () async {
      final engine = DownloadEngine(enableCleanupTimer: false);
      // A double-quote is an illegal path component on Windows (and invalid
      // on POSIX for filesystem ops); the check must not crash and must
      // report "not enough space" (fail-safe).
      final badPath =
          '${Directory.systemTemp.path}${Platform.pathSeparator}dmx"bad';
      final result = await engine.hasEnoughDiskSpace(badPath, 1024);
      expect(result, isFalse);
    });

    test(
        'hasEnoughDiskSpaceOrNull returns null (unknown) when check throws',
        () async {
      final engine = DownloadEngine(enableCleanupTimer: false);
      final badPath =
          '${Directory.systemTemp.path}${Platform.pathSeparator}dmx"bad';
      final result = await engine.hasEnoughDiskSpaceOrNull(badPath, 1024);
      expect(result, isNull);
    });

    test('hasEnoughDiskSpaceOrNull returns true when space is sufficient',
        () async {
      final engine = DownloadEngine(enableCleanupTimer: false);
      final tempDir =
          await Directory.systemTemp.createTemp('dmx_space_or_null');
      addTearDown(() {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final result =
          await engine.hasEnoughDiskSpaceOrNull(tempDir.path, 1024);
      expect(result, isTrue);
    });

    test('InsufficientStorageException carries a clear user message', () {
      const e = InsufficientStorageException();
      expect(e.message, contains('storage space'));
      expect(e.toString(), contains('storage space'));
    });
  });
}