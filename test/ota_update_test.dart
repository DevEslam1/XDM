import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/update_service.dart';

void main() {
  test('UpdateInfo JSON parsing test', () {
    final json = {
      'latestVersion': '3.1.0',
      'versionCode': 310,
      'apkUrl':
          'https://raw.githubusercontent.com/DevEslam1/XDM/main/app-release.apk',
      'changelog': 'Added OTA self-update feature',
      'mandatory': false,
      'minSupportedVersionCode': 200,
      'sha256': 'abcdef1234567890'
    };

    final update = UpdateInfo.fromJson(json);
    expect(update.latestVersion, equals('3.1.0'));
    expect(update.versionCode, equals(310));
    expect(update.apkUrl, contains('app-release.apk'));
    expect(update.mandatory, isFalse);
    expect(update.sha256, equals('abcdef1234567890'));
  });
}
