import 'dart:io';

import 'package:dmx/core/services/download_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Disk Space Check', () {
    test('hasEnoughDiskSpace returns true when space is sufficient', () async {
      final engine = DownloadEngine(enableCleanupTimer: false);
      final tempDir = await Directory.systemTemp.createTemp('dmx_space_sufficient');
      addTearDown(() {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final result = await engine.hasEnoughDiskSpace(tempDir.path, 1024);
      expect(result, isTrue);
    });

    test('hasEnoughDiskSpace returns true when check fails gracefully', () async {
      final engine = DownloadEngine(enableCleanupTimer: false);
      // Path that does not exist — the check must not crash and must allow
      // the download through (graceful fallback).
      final badPath =
          '${Directory.systemTemp.path}${Platform.pathSeparator}dmx_does_not_exist_xyz';
      final result = await engine.hasEnoughDiskSpace(badPath, 1024);
      expect(result, isTrue);
    });

    test('InsufficientStorageException carries a clear user message', () {
      const e = InsufficientStorageException();
      expect(e.message, contains('storage space'));
      expect(e.toString(), contains('storage space'));
    });
  });
}
