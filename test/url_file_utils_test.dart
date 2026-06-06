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
}
