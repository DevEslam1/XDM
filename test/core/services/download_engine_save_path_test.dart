import 'dart:io';

import 'package:dmx/core/services/download_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('save_path_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('DownloadEngine.validateSavePath', () {
    test('Valid existing path passes validation', () async {
      expect(
        DownloadEngine.validateSavePath(tempDir.path),
        completes,
      );
    });

    test('Non-existent valid path gets created automatically', () async {
      final newSubDir = p.join(tempDir.path, 'subfolder', 'target');
      expect(await Directory(newSubDir).exists(), isFalse);

      await DownloadEngine.validateSavePath(newSubDir);

      expect(await Directory(newSubDir).exists(), isTrue);
    });

    test('Path traversal attempt is blocked with InvalidPathException',
        () async {
      final traversalPath = p.join(tempDir.path, '..', 'outside');
      expect(
        () => DownloadEngine.validateSavePath(traversalPath),
        throwsA(isA<InvalidPathException>()),
      );
    });

    test('Invalid characters in path throw InvalidPathException', () async {
      final invalidPath = p.join(tempDir.path, 'invalid*name?folder');
      expect(
        () => DownloadEngine.validateSavePath(invalidPath),
        throwsA(isA<InvalidPathException>()),
      );
    });

    test('Allowed storage roots restriction is enforced', () async {
      final allowedRoot = p.join(tempDir.path, 'allowed');
      await Directory(allowedRoot).create();
      final outsidePath = p.join(tempDir.path, 'unallowed');

      expect(
        () => DownloadEngine.validateSavePath(
          outsidePath,
          allowedStorageRoots: [allowedRoot],
        ),
        throwsA(isA<InvalidPathException>()),
      );

      final insidePath = p.join(allowedRoot, 'valid_folder');
      expect(
        DownloadEngine.validateSavePath(
          insidePath,
          allowedStorageRoots: [allowedRoot],
        ),
        completes,
      );
    });
  });
}
