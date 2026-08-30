import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/desktop_update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DesktopUpdateInfo Unit Tests', () {
    test('DesktopUpdateInfo parses valid JSON accurately', () {
      final json = {
        'version': '3.2.0',
        'build': 45,
        'url': 'https://example.com/dmx-setup.exe',
        'sha256': 'a1b2c3d4e5f6',
        'notes': 'Performance improvements',
        'mandatory': true,
      };

      final info = DesktopUpdateInfo.fromJson(json);
      expect(info.version, equals('3.2.0'));
      expect(info.build, equals(45));
      expect(info.downloadUrl, equals('https://example.com/dmx-setup.exe'));
      expect(info.sha256, equals('a1b2c3d4e5f6'));
      expect(info.releaseNotes, equals('Performance improvements'));
      expect(info.mandatory, isTrue);
    });

    test('DesktopUpdateInfo handles missing optional fields gracefully', () {
      final info = DesktopUpdateInfo.fromJson({});
      expect(info.version, equals('1.0.0'));
      expect(info.build, equals(1));
      expect(info.downloadUrl, isEmpty);
      expect(info.sha256, isEmpty);
      expect(info.mandatory, isFalse);
    });
  });
}
