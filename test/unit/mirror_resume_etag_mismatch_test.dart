import 'package:dmx/core/domain/resume_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ResumeIdentity & Mirror ETag Mismatch Validation', () {
    test('Resume identity validates matching ETag and size', () {
      const original = ResumeIdentity(
        normalizedUrl: 'https://example.com/file.zip',
        etag: '"abcdef12345"',
        lastModified: 'Wed, 21 Oct 2025 07:28:00 GMT',
        contentLength: 10485760,
        supportsRanges: true,
      );

      const mirrorMatch = ResumeIdentity(
        normalizedUrl: 'https://mirror1.example.com/file.zip',
        etag: '"abcdef12345"',
        lastModified: 'Wed, 21 Oct 2025 07:28:00 GMT',
        contentLength: 10485760,
        supportsRanges: true,
      );

      final result = original.validateAgainst(mirrorMatch);
      expect(result.isValid, isTrue);
    });

    test('Resume against mirror with mismatching strong ETag fails gracefully',
        () {
      const original = ResumeIdentity(
        normalizedUrl: 'https://example.com/file.zip',
        etag: '"abcdef12345"',
        lastModified: 'Wed, 21 Oct 2025 07:28:00 GMT',
        contentLength: 10485760,
        supportsRanges: true,
      );

      const mirrorChanged = ResumeIdentity(
        normalizedUrl: 'https://mirror1.example.com/file.zip',
        etag: '"different99999"',
        lastModified: 'Thu, 22 Oct 2025 08:00:00 GMT',
        contentLength: 10485760,
        supportsRanges: true,
      );

      final result = original.validateAgainst(mirrorChanged);
      expect(result.isValid, isFalse);
      expect(result.mismatchReason, isNotNull);
      expect(result.mismatchReason, contains('Remote ETag changed'));
    });

    test('Resume against mirror with different Content-Length fails validation',
        () {
      const original = ResumeIdentity(
        normalizedUrl: 'https://example.com/file.zip',
        etag: '"abcdef12345"',
        contentLength: 10485760,
        supportsRanges: true,
      );

      const mirrorChangedSize = ResumeIdentity(
        normalizedUrl: 'https://mirror2.example.com/file.zip',
        etag: '"abcdef12345"',
        contentLength: 20971520, // Different size
        supportsRanges: true,
      );

      final result = original.validateAgainst(mirrorChangedSize);
      expect(result.isValid, isFalse);
      expect(result.mismatchReason, contains('Remote content length changed'));
    });
  });
}
