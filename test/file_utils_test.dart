import 'dart:io';

import 'package:dmx/core/utils/file_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('file_utils tests', () {
    test('safeFileName sanitizes invalid characters and reserved names', () {
      expect(safeFileName('video/test:name?.mp4'), 'video_test_name_.mp4');
      expect(safeFileName('CON.txt'), '_CON.txt');
      expect(safeFileName(''), 'download.bin');
    });

    // ── Path traversal regression tests (TASK 1) ──────────────────────────
    group('safeFileName — path traversal protection', () {
      const savePath = '/downloads/videos';

      /// Asserts that a file constructed from [savePath] + safeFileName([input])
      /// always stays inside [savePath].
      void assertNoTraversal(String input) {
        final safe = safeFileName(input);

        // 1. The result must not contain raw path separators.
        expect(
          safe.contains('/') || safe.contains('\\'),
          isFalse,
          reason: 'safeFileName("$input") → "$safe" still contains a slash',
        );

        // 2. The canonical joined path must be inside savePath.
        final joined = p.canonicalize(p.join(savePath, safe));
        expect(
          p.isWithin(savePath, joined) || joined == p.canonicalize(savePath),
          isTrue,
          reason: 'safeFileName("$input") → "$safe" escapes savePath.\n'
              '  joined canonical: $joined\n'
              '  savePath        : $savePath',
        );
      }

      test('forward slash is replaced', () {
        assertNoTraversal('../../etc/passwd');
        assertNoTraversal('foo/bar/baz.mp4');
        assertNoTraversal('/absolute/path.mp4');
      });

      test('backslash is replaced', () {
        assertNoTraversal(r'..\..\ windows\system32\evil');
        assertNoTraversal(r'folder\file.mp4');
      });

      test('mixed slash and dot-dot is replaced', () {
        assertNoTraversal('../../evil [1080p].mp4');
        assertNoTraversal('../sibling/file.mp4');
        assertNoTraversal('a/b/../../secret.mp4');
      });

      test('null bytes are stripped', () {
        final result = safeFileName('evil\x00name.mp4');
        expect(result.contains('\x00'), isFalse);
      });

      test('consecutive dots are collapsed to single dot', () {
        // '../../..' should not survive as path traversal
        final result = safeFileName('../../..');
        expect(result.contains('..'), isFalse,
            reason: 'Expected no ".." in "$result"');
      });

      test('playlist-style video title with traversal is safe', () {
        // Simulates TASK 1: '$videoTitle [$displayQuality].$ext'
        const maliciousTitle = '../../secret/video';
        const qualityExt = '[1080p].mp4';
        final fileName = safeFileName('$maliciousTitle $qualityExt');
        assertNoTraversal(maliciousTitle);
        // fileName itself must not escape
        final joined = p.canonicalize(p.join(savePath, fileName));
        expect(
          p.isWithin(savePath, joined) || joined == p.canonicalize(savePath),
          isTrue,
          reason: 'Playlist fileName "$fileName" escapes savePath',
        );
      });
    });

    test('getUniqueFilePath creates non-colliding filename when file exists',
        () async {
      final tempDir =
          await Directory.systemTemp.createTemp('dmx_file_utils_test_');
      try {
        final initialPath = p.join(tempDir.path, 'sample.mp4');
        await File(initialPath).writeAsString('test');

        final unique1 = await getUniqueFilePath(tempDir.path, 'sample.mp4');
        expect(p.basename(unique1), 'sample (1).mp4');

        await File(unique1).writeAsString('test 2');
        final unique2 = await getUniqueFilePath(tempDir.path, 'sample.mp4');
        expect(p.basename(unique2), 'sample (2).mp4');
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}
