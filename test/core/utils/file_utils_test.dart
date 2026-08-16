import 'package:dmx/core/utils/file_utils.dart';
import 'package:flutter_test/flutter_test.dart';

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
  });
}
