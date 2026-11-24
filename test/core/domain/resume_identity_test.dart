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

    test('normalizeUrl trims and strips fragment', () {
      expect(ResumeIdentity.normalizeUrl('  https://a/b#x  '), 'https://a/b');
      expect(ResumeIdentity.normalizeUrl('https://a/b'), 'https://a/b');
    });

    test('fromHeaders handles list values, empty and explicit length', () {
      final identity = ResumeIdentity.fromHeaders(
        url: 'https://example.com/f',
        headers: const {
          'ETag': ['  "list-tag"  '],
          'Last-Modified': '',
          'Accept-Ranges': 'none',
          'Content-Length': '999',
        },
        contentLength: 500,
      );
      expect(identity.etag, '"list-tag"');
      expect(identity.lastModified, isNull);
      expect(identity.supportsRanges, isFalse);
      expect(identity.contentLength, 500);

      final emptyHeader = ResumeIdentity.fromHeaders(
        url: 'u',
        headers: const {'etag': null},
      );
      expect(emptyHeader.etag, isNull);
      expect(emptyHeader.contentLength, isNull);
    });

    test('toJson and fromJson roundtrip', () {
      const identity = ResumeIdentity(
        normalizedUrl: 'https://a',
        etag: 'e',
        lastModified: 'l',
        contentLength: 5,
        supportsRanges: true,
        expectedSha256: 'sha',
        mirrorGroupId: 'g',
      );
      final json = identity.toJson();
      final restored = ResumeIdentity.fromJson(json);
      expect(restored, equals(identity));
      expect(restored.hashCode, identity.hashCode);
      expect(restored.toString(), isNotNull);
    });

    test('fromJson defaults', () {
      final restored = ResumeIdentity.fromJson(const {});
      expect(restored.normalizedUrl, '');
      expect(restored.etag, isNull);
      expect(restored.contentLength, isNull);
      expect(restored.supportsRanges, isFalse);
      expect(restored.expectedSha256, isNull);
      expect(restored.mirrorGroupId, isNull);
    });

    test('weak etags match and last-modified used when etags absent', () {
      const a = ResumeIdentity(
        normalizedUrl: 'u',
        etag: 'W/"tag"',
      );
      const b = ResumeIdentity(
        normalizedUrl: 'u',
        etag: '"tag"',
      );
      expect(a.validateAgainst(b).isValid, isTrue);

      const noEtagA = ResumeIdentity(
        normalizedUrl: 'u',
        lastModified: 'Mon',
      );
      const noEtagB = ResumeIdentity(
        normalizedUrl: 'u',
        lastModified: 'Tue',
      );
      final result = noEtagA.validateAgainst(noEtagB);
      expect(result.isValid, isFalse);
      expect(result.mismatchReason, contains('Last-Modified'));
    });

    test('non-positive lengths are not compared and valid result toString', () {
      const a = ResumeIdentity(normalizedUrl: 'u', contentLength: 0);
      const b = ResumeIdentity(normalizedUrl: 'u', contentLength: 10);
      final result = a.validateAgainst(b);
      expect(result.isValid, isTrue);
      expect(result.mismatchReason, isNull);
      expect(result.toString(), 'ResumeValidationResult.valid()');

      const mismatch = ResumeValidationResult.mismatch('why');
      expect(mismatch.toString(), 'ResumeValidationResult.mismatch(why)');
    });

    test('equality and hashCode', () {
      const a = ResumeIdentity(normalizedUrl: 'u', etag: 'e');
      const b = ResumeIdentity(normalizedUrl: 'u', etag: 'e');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a == Object(), isFalse);
      expect(a == const ResumeIdentity(normalizedUrl: 'x'), isFalse);
    });
  });
}
