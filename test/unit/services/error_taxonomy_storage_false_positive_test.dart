// Regression tests for the false-positive "no storage" bug:
// the app used to report unrelated IO/permission/invalid-path failures as
// "Not enough storage space" / "Storage full" even when the device had space.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/error_taxonomy.dart';
import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:dmx/features/downloads/domain/orchestrators/http_download_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('false-positive "no storage" regressions', () {
    test('errno 13 FileSystemException on an Android path is not storage-full',
        () {
      const err = FileSystemException(
        'Cannot open file',
        '/storage/emulated/0/Download/x.mp4',
        OSError('Permission denied', 13),
      );
      final res = ErrorTaxonomy.classify(err);
      expect(res.family, isNot(ErrorFamily.disk));
      expect(res.message, isNot('Storage full'));
    });

    test('errno 28 FileSystemException stays "Storage full"', () {
      const err = FileSystemException(
        'Cannot write to file',
        '/storage/emulated/0/Download/x.mp4',
        OSError('No space left on device', 28),
      );
      final res = ErrorTaxonomy.classify(err);
      expect(res.family, ErrorFamily.disk);
      expect(res.message, 'Storage full');
    });

    test('writer error mentioning "SpaceX" is not "not enough storage"', () {
      const err = PositionalFileWriterException(
          'write failed: FileSystemException: Cannot write to file, path = '
          "'/storage/emulated/0/Download/SpaceX launch.mp4' "
          '(OS Error: Permission denied, errno = 13)');
      final res = ErrorTaxonomy.classify(err);
      expect(res.message, isNot('Not enough storage space'));
      expect(res.family, isNot(ErrorFamily.disk));
    });

    test('writer error with a real ENOSPC message stays disk-full', () {
      const err = PositionalFileWriterException(
          'write failed: No space left on device');
      final res = ErrorTaxonomy.classify(err);
      expect(res.family, ErrorFamily.disk);
      expect(res.message, 'Not enough storage space');
    });

    test(
        'generic error containing an Android storage path is not "Storage full"',
        () {
      final res = ErrorTaxonomy.classify(Exception(
          "Cannot open file, path = '/storage/emulated/0/Download/x.mp4' "
          '(OS Error: Permission denied, errno = 13)'));
      expect(res.family, isNot(ErrorFamily.disk));
      expect(res.message, isNot('Storage full'));
    });

    test('InvalidPathException keeps its own user-facing message', () {
      final res = ErrorTaxonomy.classify(const InvalidPathException(
          'Save path contains invalid characters'));
      expect(res.message, 'Invalid storage path');
    });

    test(
        'mapWorkerError: disk + space message -> InsufficientStorageException',
        () {
      final e = HttpDownloadOrchestrator.mapWorkerError(const {
        'taxonomyCode': 'disk',
        'message': 'Not enough storage space',
      }, 'https://example.com/file.zip');
      expect(e, isA<InsufficientStorageException>());
    });

    test('mapWorkerError: disk + invalid path -> InvalidPathException', () {
      final e = HttpDownloadOrchestrator.mapWorkerError(const {
        'taxonomyCode': 'disk',
        'message': 'Invalid storage path',
      }, 'https://example.com/file.zip');
      expect(e, isA<InvalidPathException>());
    });

    test('mapWorkerError: disk + generic IO error is NOT "no storage"', () {
      final e = HttpDownloadOrchestrator.mapWorkerError(const {
        'taxonomyCode': 'disk',
        'message': 'File system error',
      }, 'https://example.com/file.zip');
      expect(e, isNot(isA<InsufficientStorageException>()));
      expect(e, isA<DioException>());
    });

    test('mapWorkerError: diskFull stays InsufficientStorageException', () {
      final e = HttpDownloadOrchestrator.mapWorkerError(const {
        'taxonomyCode': 'diskFull',
        'message': 'Storage full',
      }, 'https://example.com/file.zip');
      expect(e, isA<InsufficientStorageException>());
    });
  });
}