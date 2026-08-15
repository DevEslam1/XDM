import 'package:dio/dio.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:dmx/core/services/mirror/mirror_registry.dart';
import 'package:dmx/core/services/mirror/mirror_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HttpTransferJob & Content-Range Validation Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await MirrorHealthStore.instance.init();
      await MirrorHealthStore.instance.clear();
    });

    test('validateContentRange validates correct standard range response', () {
      expect(
        () => HttpTransferJob.validateContentRange(
          'bytes 100-199/500',
          expectedStart: 100,
          expectedEnd: 199,
          expectedTotal: 500,
        ),
        returnsNormally,
      );
    });

    test('validateContentRange rejects missing content range header', () {
      expect(
        () => HttpTransferJob.validateContentRange(
          null,
          expectedStart: 100,
          expectedEnd: 199,
          expectedTotal: 500,
        ),
        throwsA(isA<DioException>().having(
          (e) => e.message,
          'message',
          contains('Missing Content-Range header during resume.'),
        )),
      );

      expect(
        () => HttpTransferJob.validateContentRange(
          '   ',
          expectedStart: 100,
          expectedEnd: 199,
          expectedTotal: 500,
        ),
        throwsA(isA<DioException>().having(
          (e) => e.message,
          'message',
          contains('Missing Content-Range header during resume.'),
        )),
      );
    });

    test('validateContentRange allows missing or malformed when allowUnknown is true', () {
      expect(
        () => HttpTransferJob.validateContentRange(
          null,
          expectedStart: 100,
          expectedEnd: 199,
          expectedTotal: 500,
          allowUnknown: true,
        ),
        returnsNormally,
      );

      expect(
        () => HttpTransferJob.validateContentRange(
          '',
          expectedStart: 100,
          expectedEnd: 199,
          expectedTotal: 500,
          allowUnknown: true,
        ),
        returnsNormally,
      );

      expect(
        () => HttpTransferJob.validateContentRange(
          'invalid content range format',
          expectedStart: 100,
          expectedEnd: 199,
          expectedTotal: 500,
          allowUnknown: true,
        ),
        returnsNormally,
      );
    });

    test('validateContentRange rejects malformed range when allowUnknown is false', () {
      expect(
        () => HttpTransferJob.validateContentRange(
          'invalid format string',
          expectedStart: 100,
          expectedEnd: 199,
          expectedTotal: 500,
        ),
        throwsA(isA<DioException>().having(
          (e) => e.message,
          'message',
          contains('Malformed Content-Range during resume'),
        )),
      );
    });

    test('validateContentRange rejects mismatching end or total', () {
      expect(
        () => HttpTransferJob.validateContentRange(
          'bytes 100-250/500',
          expectedStart: 100,
          expectedEnd: 199,
          expectedTotal: 500,
        ),
        throwsA(isA<DioException>().having(
          (e) => e.message,
          'message',
          contains('Invalid Content-Range response'),
        )),
      );

      expect(
        () => HttpTransferJob.validateContentRange(
          'bytes 100-199/600',
          expectedStart: 100,
          expectedEnd: 199,
          expectedTotal: 500,
        ),
        throwsA(isA<DioException>().having(
          (e) => e.message,
          'message',
          contains('Invalid Content-Range response'),
        )),
      );
    });

    test('validateContentRange accepts wildcard total', () {
      expect(
        () => HttpTransferJob.validateContentRange(
          'bytes 0-99/*',
          expectedStart: 0,
          expectedEnd: 99,
          expectedTotal: 0,
        ),
        returnsNormally,
      );
    });

    test('mirror failover advances on retry and falls back to alternates', () {
      final mirrors = [
        'https://mirror1.example.com/file.bin',
        'https://mirror2.example.com/file.bin',
        'https://mirror3.example.com/file.bin',
      ];
      final failover = MirrorFailover(mirrors);
      expect(failover.activeUrl, equals('https://mirror1.example.com/file.bin'));

      final next = failover.advance();
      expect(next, isNotNull);
      expect(next, isNot(equals('https://mirror1.example.com/file.bin')));
      expect(failover.mirrorSwitches, equals(1));
    });
  });
}
