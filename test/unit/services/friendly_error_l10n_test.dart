import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/error_taxonomy.dart';
import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Task 5: Friendly Localized Errors Suite', () {
    test('Formats integrity failure as friendly localized message without raw exception dump', () {
      const exc = DownloadIntegrityException('CRC32 mismatch on chunk #4 at byte 0x40000');
      final result = ErrorTaxonomy.classify(exc);

      expect(result.family, equals(ErrorFamily.integrity));
      expect(result.message, equals('File integrity verification failed'));
      expect(result.message, isNot(contains('0x40000')),
          reason: 'Technical details must not be exposed in user-facing message');
      expect(result.recoveryAction, equals(RecoveryAction.restartDownload));
    });

    test('Formats disk write failure without raw errno or paths', () {
      const exc = PositionalFileWriterException('EACCES: permission denied, open /private/var/...');
      final result = ErrorTaxonomy.classify(exc);

      expect(result.family, equals(ErrorFamily.disk));
      expect(result.message, equals('Disk write error. Check storage permissions and free space.'));
      expect(result.message, isNot(contains('/private/var/')),
          reason: 'Raw filesystem paths must not be leaked to user UI');
      expect(result.recoveryAction, equals(RecoveryAction.showSettings));
    });

    test('Formats disk out-of-space error clearly', () {
      const exc = PositionalFileWriterException('ENOSPC: no space left on device');
      final result = ErrorTaxonomy.classify(exc);

      expect(result.family, equals(ErrorFamily.disk));
      expect(result.message, equals('Not enough storage space'));
      expect(result.severe, isTrue);
    });

    test('Formats URL expiration as friendly renewal prompt', () {
      const exc = UrlExpiredException('Signature expired at timestamp 1700000000');
      final result = ErrorTaxonomy.classify(exc);

      expect(result.family, equals(ErrorFamily.auth));
      expect(result.message, equals('Download URL has expired'));
      expect(result.recoveryAction, equals(RecoveryAction.refreshUrl));
    });
  });
}
