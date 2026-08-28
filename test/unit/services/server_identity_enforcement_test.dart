import 'package:dmx/core/domain/resume_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Task 2: ServerIdentity Resume Enforcement Suite', () {
    test('Validates identical resume headers as valid', () {
      final initial = ResumeIdentity.fromHeaders(
        url: 'https://cdn.example.com/build.zip',
        headers: const {
          'etag': '"v1.0.0-final"',
          'last-modified': 'Mon, 10 Jan 2026 12:00:00 GMT',
          'accept-ranges': 'bytes',
          'content-length': '104857600',
        },
      );

      final candidate = ResumeIdentity.fromHeaders(
        url: 'https://cdn.example.com/build.zip',
        headers: const {
          'etag': '"v1.0.0-final"',
          'last-modified': 'Mon, 10 Jan 2026 12:00:00 GMT',
          'accept-ranges': 'bytes',
          'content-length': '104857600',
        },
      );

      final result = initial.validateAgainst(candidate);
      expect(result.isValid, isTrue);
      expect(result.mismatchReason, isNull);
    });

    test('Detects changed remote content size and rejects resume', () {
      final initial = ResumeIdentity.fromHeaders(
        url: 'https://cdn.example.com/build.zip',
        headers: const {
          'content-length': '104857600',
          'etag': '"fixed-etag"',
        },
      );

      final candidate = ResumeIdentity.fromHeaders(
        url: 'https://cdn.example.com/build.zip',
        headers: const {
          'content-length': '104858000', // Remote file was updated/changed
          'etag': '"fixed-etag"',
        },
      );

      final result = initial.validateAgainst(candidate);
      expect(result.isValid, isFalse);
      expect(result.mismatchReason, contains('Remote content length changed'));
    });

    test('Detects changed ETag and rejects resume (handles weak ETag prefix)',
        () {
      final initial = ResumeIdentity.fromHeaders(
        url: 'https://cdn.example.com/patch.bin',
        headers: const {
          'etag': '"etag-v1"',
        },
      );

      final candidate = ResumeIdentity.fromHeaders(
        url: 'https://cdn.example.com/patch.bin',
        headers: const {
          'etag': 'W/"etag-v2"', // New build on origin
        },
      );

      final result = initial.validateAgainst(candidate);
      expect(result.isValid, isFalse);
      expect(result.mismatchReason, contains('Remote ETag changed'));
    });

    test('Detects changed Last-Modified when ETag is not provided', () {
      final initial = ResumeIdentity.fromHeaders(
        url: 'https://cdn.example.com/doc.pdf',
        headers: const {
          'last-modified': 'Sun, 01 Jan 2026 00:00:00 GMT',
        },
      );

      final candidate = ResumeIdentity.fromHeaders(
        url: 'https://cdn.example.com/doc.pdf',
        headers: const {
          'last-modified': 'Sun, 15 Jan 2026 00:00:00 GMT',
        },
      );

      final result = initial.validateAgainst(candidate);
      expect(result.isValid, isFalse);
      expect(result.mismatchReason, contains('Remote Last-Modified changed'));
    });

    test('Detects mirror group mismatch across failover candidates', () {
      const initial = ResumeIdentity(
        normalizedUrl: 'https://mirror1.example.com/file.iso',
        mirrorGroupId: 'group-ubuntu-24',
      );

      const candidate = ResumeIdentity(
        normalizedUrl: 'https://mirror2.example.com/file.iso',
        mirrorGroupId: 'group-debian-12', // Wrong mirror cluster
      );

      final result = initial.validateAgainst(candidate);
      expect(result.isValid, isFalse);
      expect(result.mismatchReason, contains('Mirror group mismatch'));
    });

    test('Handles weak vs strong matching correctly', () {
      final initial = ResumeIdentity.fromHeaders(
        url: 'https://example.com/archive.tar',
        headers: const {'etag': 'W/"static-etag"'},
      );
      final candidate = ResumeIdentity.fromHeaders(
        url: 'https://example.com/archive.tar',
        headers: const {'etag': '"static-etag"'},
      );

      final result = initial.validateAgainst(candidate);
      expect(result.isValid, isTrue);
    });
  });
}
