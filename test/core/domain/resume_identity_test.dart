import 'package:dmx/core/domain/resume_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('P0-4: ResumeIdentity validation suite', () {
    test('parses identity from standard HTTP headers', () {
      final identity = ResumeIdentity.fromHeaders(
        url: 'https://example.com/file.bin#fragment',
        headers: const {
          'etag': '"abc123xyz"',
          'last-modified': 'Wed, 21 Oct 2025 07:28:00 GMT',
          'accept-ranges': 'bytes',
          'content-length': '10485760',
        },
      );

      expect(identity.normalizedUrl, 'https://example.com/file.bin');
      expect(identity.etag, '"abc123xyz"');
      expect(identity.lastModified, 'Wed, 21 Oct 2025 07:28:00 GMT');
      expect(identity.supportsRanges, isTrue);
      expect(identity.contentLength, 10485760);
    });

    test('validates matching candidate identity as valid', () {
      const initial = ResumeIdentity(
        normalizedUrl: 'https://example.com/file.bin',
        etag: '"tag-v1"',
        lastModified: 'Wed, 21 Oct 2025 07:28:00 GMT',
        contentLength: 5000,
        supportsRanges: true,
      );

      const candidate = ResumeIdentity(
        normalizedUrl: 'https://example.com/file.bin',
        etag: '"tag-v1"',
        lastModified: 'Wed, 21 Oct 2025 07:28:00 GMT',
        contentLength: 5000,
        supportsRanges: true,
      );

      final result = initial.validateAgainst(candidate);
      expect(result.isValid, isTrue);
      expect(result.mismatchReason, isNull);
    });

    test('detects content-length mismatch', () {
      const initial = ResumeIdentity(
        normalizedUrl: 'https://example.com/file.bin',
        contentLength: 5000,
      );

      const candidate = ResumeIdentity(
        normalizedUrl: 'https://example.com/file.bin',
        contentLength: 6000,
      );

      final result = initial.validateAgainst(candidate);
      expect(result.isValid, isFalse);
      expect(result.mismatchReason, contains('Remote content length changed'));
    });

    test('detects ETag mismatch', () {
      const initial = ResumeIdentity(
        normalizedUrl: 'https://example.com/file.bin',
        etag: '"tag-v1"',
      );

      const candidate = ResumeIdentity(
        normalizedUrl: 'https://example.com/file.bin',
        etag: '"tag-v2"',
      );

      final result = initial.validateAgainst(candidate);
      expect(result.isValid, isFalse);
      expect(result.mismatchReason, contains('Remote ETag changed'));
    });

    test('detects mirror group mismatch', () {
      const initial = ResumeIdentity(
        normalizedUrl: 'https://mirror1.com/file.bin',
        mirrorGroupId: 'group-A',
      );

      const candidate = ResumeIdentity(
        normalizedUrl: 'https://mirror2.com/file.bin',
        mirrorGroupId: 'group-B',
      );

      final result = initial.validateAgainst(candidate);
      expect(result.isValid, isFalse);
      expect(result.mismatchReason, contains('Mirror group mismatch'));
    });
  });
}
