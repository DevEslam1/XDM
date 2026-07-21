import 'package:dmx/core/utils/file_utils.dart';
import 'package:dmx/core/utils/url_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fileNameFromUrl extracts and sanitizes names', () {
    expect(
      fileNameFromUrl('https://example.com/files/My%20Video.mp4?token=1'),
      'My Video.mp4',
    );
    expect(fileNameFromUrl('https://example.com/'), startsWith('download_'));
  });

  test('categoryFromFileName maps common extensions', () {
    expect(categoryFromFileName('movie.mkv'), 'Video');
    expect(categoryFromFileName('song.flac'), 'Audio');
    expect(categoryFromFileName('report.pdf'), 'Document');
    expect(categoryFromFileName('bundle.7z'), 'Archive');
    expect(categoryFromFileName('app.apk'), 'APK');
    expect(categoryFromFileName('unknown.bin'), 'Other');
  });

  test('isHttpUrl accepts only complete HTTP URLs', () {
    expect(isHttpUrl('https://example.com/file.zip'), isTrue);
    expect(isHttpUrl('http://example.com/file.zip'), isTrue);
    expect(isHttpUrl('ftp://example.com/file.zip'), isFalse);
    expect(isHttpUrl('https:///file.zip'), isFalse);
  });

  group('Magnet URL Tests', () {
    const validHex40 = 'magnet:?xt=urn:btih:5dee65101db75097c523f19f074d0a64087dbcd3&dn=Ubuntu';
    const validBase32 = 'magnet:?xt=urn:btih:MR6EKEINW5KJPRFD6GPQPTHKMQEH3P5T';
    const validHex64 = 'magnet:?xt=urn:btih:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
    
    const invalidNoXt = 'magnet:?dn=Ubuntu';
    const invalidShortHash = 'magnet:?xt=urn:btih:5dee65101db75097';
    const invalidCharHash = 'magnet:?xt=urn:btih:5dee65101db75097c523f19f074d0a64087dbcg3'; // 'g' is not hex

    test('isMagnetUrl validates correct formats', () {
      expect(isMagnetUrl(validHex40), isTrue);
      expect(isMagnetUrl(validBase32), isTrue);
      expect(isMagnetUrl(validHex64), isTrue);

      expect(isMagnetUrl(invalidNoXt), isFalse);
      expect(isMagnetUrl(invalidShortHash), isFalse);
      expect(isMagnetUrl(invalidCharHash), isFalse);
      expect(isMagnetUrl('https://example.com'), isFalse);
    });

    test('parseMagnetUrl extracts dn and infoHash', () {
      final parsed1 = parseMagnetUrl(validHex40);
      expect(parsed1['infoHash'], '5DEE65101DB75097C523F19F074D0A64087DBCD3');
      expect(parsed1['name'], 'Ubuntu');

      final parsed2 = parseMagnetUrl(validBase32);
      expect(parsed2['infoHash'], isNotNull);
      expect(parsed2['infoHash']!.length, 40); // Converted 32-char Base32 to 40-char Hex
    });

    test('isValidTransmissionUrl accepts valid magnet URLs', () {
      expect(isValidTransmissionUrl(validHex40), isTrue);
      expect(isValidTransmissionUrl(invalidNoXt), isFalse);
    });
  });

  group('Punycode & Content Disposition Tests', () {
    test('convertIdnToPunycode handles non-Latin domains safely', () {
      expect(convertIdnToPunycode('https://example.com'), 'https://example.com');
      final puny = convertIdnToPunycode('https://موقع.الجزيرة.net/test');
      expect(puny, contains('xn--'));
    });
  });
}
