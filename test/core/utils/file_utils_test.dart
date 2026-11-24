import 'dart:io';

import 'package:dmx/core/services/site_intelligence/site_intelligence_service.dart';
import 'package:dmx/core/utils/file_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('FileUtils', () {
    test('formatBytes formats zero, B, KB, MB, GB properly', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(1024 * 1024 * 1024 * 2.5), '2.5 GB');
      expect(formatBytes(-100), '0 B');
    });

    test('categoryFromFileName classifies extensions into correct buckets', () {
      expect(categoryFromFileName('movie.mp4'), 'Video');
      expect(categoryFromFileName('song.mp3'), 'Audio');
      expect(categoryFromFileName('document.pdf'), 'Document');
      expect(categoryFromFileName('package.zip'), 'Archive');
      expect(categoryFromFileName('app.apk'), 'APK');
      expect(categoryFromFileName('unknown.xyz'), 'Other');
    });

    test('safeFileName removes illegal filesystem characters', () {
      expect(safeFileName('file:with/illegal*chars?.txt'),
          'file_with_illegal_chars_.txt');
      expect(safeFileName('normal_file.png'), 'normal_file.png');
    });

    test('isKnownArchiveExtension recognizes archive formats', () {
      expect(archiveExtensions.contains('zip'), true);
      expect(archiveExtensions.contains('rar'), true);
      expect(archiveExtensions.contains('7z'), true);
      expect(archiveExtensions.contains('tar'), true);
      expect(archiveExtensions.contains('iso'), true);
    });

    test('video and audio extension lists are exhaustive', () {
      expect(videoExtensions.contains('mp4'), true);
      expect(videoExtensions.contains('mkv'), true);
      expect(videoExtensions.contains('webm'), true);
      expect(audioExtensions.contains('flac'), true);
      expect(audioExtensions.contains('wav'), true);
    });

    group('Path Traversal & Malicious File Name Sanitization (S3)', () {
      test('sanitizeFileName removes traversal, null bytes, and NTFS ADS', () {
        expect(sanitizeFileName('../../etc/passwd'), '____etc_passwd');
        expect(sanitizeFileName(r'..\..\Windows\System32\cmd.exe'),
            '____Windows_System32_cmd.exe');
        expect(sanitizeFileName('file\x00name.txt'), 'filename.txt');
        expect(sanitizeFileName('file.txt:stream'), 'file.txt_stream');
        expect(sanitizeFileName('<illegal>:*?"|'), '_illegal______');
        expect(sanitizeFileName(''), startsWith('download_'));
        expect(sanitizeFileName('.'), startsWith('download_'));
        expect(sanitizeFileName('..'), startsWith('download_'));
      });

      test('isSafeSubpath correctly validates canonical directory boundaries',
          () {
        const root = '/downloads/dmx';
        expect(isSafeSubpath(root, '/downloads/dmx/sub/file.zip'), isTrue);
        expect(isSafeSubpath(root, '/downloads/dmx/file.zip'), isTrue);
        expect(isSafeSubpath(root, '/downloads/dmx/../etc/passwd'), isFalse);
        expect(isSafeSubpath(root, '/etc/passwd'), isFalse);
      });
    });

    group('Category resolution', () {
      test('categoryFromFileName honors content hints', () {
        expect(categoryFromFileName('x', contentHint: ContentHint.videoFile),
            'Video');
        expect(categoryFromFileName('x', contentHint: ContentHint.videoStream),
            'Video');
        expect(categoryFromFileName('x', contentHint: ContentHint.audioFile),
            'Audio');
        expect(categoryFromFileName('x', contentHint: ContentHint.audioStream),
            'Audio');
        expect(categoryFromFileName('x', contentHint: ContentHint.archiveFile),
            'Archive');
        expect(
            categoryFromFileName('x', contentHint: ContentHint.softwarePackage),
            'APK');
        expect(categoryFromFileName('x', contentHint: ContentHint.document),
            'Document');
        expect(
            categoryFromFileName('x', contentHint: ContentHint.image), 'Image');
        expect(categoryFromFileName('x', contentHint: ContentHint.unknown),
            'Other');
      });

      test('categoryFromFileName honors site type without a hint', () {
        expect(categoryFromFileName('x', siteType: SiteType.videoStreaming),
            'Video');
        expect(categoryFromFileName('x', siteType: SiteType.audioStreaming),
            'Audio');
        expect(
            categoryFromFileName('x', siteType: SiteType.fileHosting), 'Other');
      });

      test('categoryFromFileName classifies document and archive extensions',
          () {
        expect(categoryFromFileName('report.docx'), 'Document');
        expect(categoryFromFileName('data.csv'), 'Document');
        expect(categoryFromFileName('bundle.tar'), 'Archive');
        expect(categoryFromFileName('disk.iso'), 'Archive');
      });

      test('resolveCategorySmart delegates to site intelligence', () {
        expect(
          resolveCategorySmart(
              url: 'https://x/y', contentHint: ContentHint.videoFile),
          'Video',
        );
        expect(
          resolveCategorySmart(
              url: 'https://x/y', contentHint: ContentHint.softwarePackage),
          'Software',
        );
        expect(resolveCategorySmart(url: 'https://x/movie-1080p.mkv'), 'Video');
        expect(resolveCategorySmart(url: 'https://x/song.mp3'), 'Audio');
        expect(resolveCategorySmart(url: 'https://x/app.apk'), 'Software');
      });
    });

    group('Names and paths', () {
      test('safeFileName truncates long names and escapes reserved names', () {
        final longName = '${List.filled(200, 'a').join()}.txt';
        final safe = safeFileName(longName);
        expect(safe.length, lessThanOrEqualTo(120));
        expect(safe, endsWith('.txt'));

        expect(safeFileName('CON.txt'), '_CON.txt');
        expect(safeFileName('com1.log'), '_com1.log');
      });

      test('sanitizeFileName handles reserved names and long input', () {
        expect(sanitizeFileName('CON.txt'), '_CON.txt');
        final longName = '${List.filled(300, 'b').join()}.txt';
        final safe = sanitizeFileName(longName);
        expect(safe.length, lessThanOrEqualTo(255));
        expect(safe, endsWith('.txt'));
        expect(sanitizeFileName('___'), startsWith('download_'));
      });

      test('torrentSavePath sanitizes and joins the name', () {
        final expected = p.join('/downloads', 'a_b.txt');
        expect(torrentSavePath('/downloads', 'a/b.txt'), expected);
      });

      test('getUniqueFilePath appends a counter when the target exists',
          () async {
        final tmp = Directory.systemTemp.createTempSync('dmx_unique_');
        addTearDown(() {
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        });
        File(p.join(tmp.path, 'dup.txt')).writeAsStringSync('x');

        final unique = await getUniqueFilePath(tmp.path, 'dup.txt');
        expect(p.basename(unique), 'dup (1).txt');

        final fresh = await getUniqueFilePath(tmp.path, 'fresh.txt');
        expect(p.basename(fresh), 'fresh.txt');
      });
    });

    group('Disk scanning', () {
      test('scanFolderBytesSync sums files and tolerates missing folders', () {
        final tmp = Directory.systemTemp.createTempSync('dmx_scan_');
        addTearDown(() {
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        });
        File(p.join(tmp.path, 'a.bin')).writeAsBytesSync(List.filled(100, 1));
        final sub = Directory(p.join(tmp.path, 'sub'))..createSync();
        File(p.join(sub.path, 'b.bin')).writeAsBytesSync(List.filled(50, 1));

        expect(scanFolderBytesSync(tmp.path), 150);
        expect(scanFolderBytesSync(p.join(tmp.path, 'missing')), 0);
      });

      test('scanTorrentFilesOnDisk estimates progress from disk contents', () {
        final tmp = Directory.systemTemp.createTempSync('dmx_torrent_scan_');
        addTearDown(() {
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        });

        // Head-only data with a larger declared length.
        File(p.join(tmp.path, 'partial.bin'))
            .writeAsBytesSync(List.filled(10, 7));
        // Pre-allocated with zeros.
        File(p.join(tmp.path, 'zero.bin'))
            .writeAsBytesSync(List.filled(100, 0));
        // Complete content.
        File(p.join(tmp.path, 'full.bin'))
            .writeAsBytesSync(List.filled(100, 5));
        // Stored progress wins.
        File(p.join(tmp.path, 'stored.bin'))
            .writeAsBytesSync(List.filled(100, 5));

        final result = scanTorrentFilesOnDisk(tmp.path, [
          {'name': 'partial.bin', 'length': 100},
          {'name': 'zero.bin', 'length': 100},
          {'name': 'full.bin', 'length': 100},
          {'name': 'stored.bin', 'length': 100, 'downloadedBytes': 42},
          {'name': '../escape.bin', 'length': 100},
          {'name': 'absent.bin', 'length': 100},
          {'name': 'zero_length.bin', 'length': 0},
        ]);

        final files = result.files;
        expect(files[0]['downloadedBytes'], 10);
        expect(files[1]['downloadedBytes'], 0);
        expect(files[2]['downloadedBytes'], 100);
        expect(files[3]['downloadedBytes'], 42);
        expect(files[4]['downloadedBytes'], 0);
        expect(files[5]['downloadedBytes'], 0);
        expect(files[6]['downloadedBytes'], 0);
        for (final file in files) {
          expect(file['progressSource'], 'disk-scan');
        }
      });

      test('scanTorrentFilesOnDisk detects a partially written large file', () {
        final tmp = Directory.systemTemp.createTempSync('dmx_torrent_partial_');
        addTearDown(() {
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        });

        final bytes = List<int>.filled(10000, 0);
        for (var i = 0; i < 5000; i++) {
          bytes[i] = 9;
        }
        File(p.join(tmp.path, 'big.bin')).writeAsBytesSync(bytes);

        final result = scanTorrentFilesOnDisk(tmp.path, [
          {'name': 'big.bin', 'length': 100},
        ]);
        expect(result.files.first['downloadedBytes'], 5000);
      });

      test('scanTorrentFilesOnDiskAsync short-circuits an empty list',
          () async {
        final result = await scanTorrentFilesOnDiskAsync('/tmp', []);
        expect(result.total, 0);
        expect(result.files, isEmpty);
      });

      test('deleteDownloadParts removes only related artifacts', () async {
        final tmp = Directory.systemTemp.createTempSync('dmx_parts_');
        addTearDown(() {
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        });

        final main = File(p.join(tmp.path, 'file.dmxpart'))
          ..writeAsStringSync('m');
        final part = File(p.join(tmp.path, 'file.dmxpart.part1'))
          ..writeAsStringSync('p');
        final state = File(p.join(tmp.path, 'file.dmxpart.dmxstate'))
          ..writeAsStringSync('s');
        final journal = File(p.join(tmp.path, 'file.dmxpart.journal'))
          ..writeAsStringSync('j');
        final unrelated = File(p.join(tmp.path, 'unrelated.txt'))
          ..writeAsStringSync('o');

        await deleteDownloadParts(main.path);

        expect(main.existsSync(), isFalse);
        expect(part.existsSync(), isFalse);
        expect(state.existsSync(), isFalse);
        expect(journal.existsSync(), isFalse);
        expect(unrelated.existsSync(), isTrue);
      });
    });

    test('isTorrentFileSelected defaults to true unless explicitly false', () {
      expect(isTorrentFileSelected({'selected': true}), isTrue);
      expect(isTorrentFileSelected({'selected': false}), isFalse);
      expect(isTorrentFileSelected({'selected': 'yes'}), isTrue);
      expect(isTorrentFileSelected({}), isTrue);
    });

    test('isSafeSubpath accepts roots and children but rejects escapes', () {
      final tmp = Directory.systemTemp.createTempSync('dmx_safe_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final child = Directory(p.join(tmp.path, 'child'))..createSync();
      expect(isSafeSubpath(tmp.path, tmp.path), isTrue);
      expect(isSafeSubpath(tmp.path, child.path), isTrue);
      expect(
          isSafeSubpath(tmp.path, p.join(tmp.path, '..', 'escape')), isFalse);
    });

    test('isSafeSubpath handles existing files and malformed inputs', () {
      final tmp = Directory.systemTemp.createTempSync('dmx_safe_file_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final file = File(p.join(tmp.path, 'inside.bin'))..writeAsStringSync('x');
      expect(isSafeSubpath(tmp.path, file.path), isTrue);
    });

    test('scanTorrentFilesOnDiskAsync offloads a non-empty scan', () async {
      final tmp = Directory.systemTemp.createTempSync('dmx_async_scan_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      File(p.join(tmp.path, 'a.bin')).writeAsBytesSync(List.filled(10, 1));

      final result = await scanTorrentFilesOnDiskAsync(tmp.path, [
        {'name': 'a.bin', 'length': 100},
      ]);
      expect(result.files.length, 1);
      expect(result.total, 10);
    });
    test('scanTorrentFilesOnDisk tolerates malformed file entries', () {
      final tmp = Directory.systemTemp.createTempSync('dmx_bad_entry_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final result = scanTorrentFilesOnDisk(tmp.path, [
        {'name': '\u0000bad', 'length': 100},
        {'name': '', 'length': 100},
      ]);
      for (final file in result.files) {
        expect(file['downloadedBytes'], 0);
      }
    });

    test('deleteDownloadParts tolerates a missing parent directory', () async {
      await deleteDownloadParts('/no/such/dir/file.dmxpart');
    });
  });
}
