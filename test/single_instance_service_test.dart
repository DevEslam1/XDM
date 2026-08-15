import 'package:dmx/core/services/single_instance_service.dart';
import 'package:dmx/core/utils/url_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SingleInstanceService Launch URL Extraction Tests', () {
    test('Extracts magnet link from args', () {
      final args = [
        '--enable-dart-profiling',
        'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Ubuntu'
      ];
      final extracted = SingleInstanceService.extractLaunchUrl(args);
      expect(
          extracted,
          equals(
              'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Ubuntu'));
    });

    test('Extracts .torrent file path from args', () {
      final args = ['-d', 'C:\\Downloads\\ubuntu.torrent'];
      final extracted = SingleInstanceService.extractLaunchUrl(args);
      expect(extracted, equals('C:\\Downloads\\ubuntu.torrent'));
    });

    test('Returns null if no valid link in args', () {
      final args = ['--enable-dart-profiling', '-d'];
      final extracted = SingleInstanceService.extractLaunchUrl(args);
      expect(extracted, isNull);
    });
  });

  group('Transmission URL Validation Tests', () {
    test('Recognizes magnet URLs as valid transmission URLs', () {
      const magnet =
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Test';
      expect(isMagnetUrl(magnet), isTrue);
      expect(isValidTransmissionUrl(magnet), isTrue);
    });

    test('Recognizes file:// and .torrent paths as valid torrent file URLs',
        () {
      const torrentPath = 'C:\\Users\\User\\Downloads\\sample.torrent';
      const fileUri = 'file:///C:/Users/User/Downloads/sample.torrent';
      expect(isTorrentFileUrl(torrentPath), isTrue);
      expect(isTorrentFileUrl(fileUri), isTrue);
      expect(isValidTransmissionUrl(torrentPath), isTrue);
      expect(isValidTransmissionUrl(fileUri), isTrue);
    });
  });
}
