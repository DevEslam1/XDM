import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Widget Manifest & Build Configuration Audit Tests [W-9 & W-10]', () {
    test(
        '[W-9] AndroidManifest WidgetActionReceiver is unexported and has no redundant intent-filters',
        () {
      final manifestFile = File('android/app/src/main/AndroidManifest.xml');
      expect(manifestFile.existsSync(), isTrue);
      final content = manifestFile.readAsStringSync();

      // Check WidgetActionReceiver exists and is unexported
      expect(content.contains('android:name=".widget.WidgetActionReceiver"'),
          isTrue);
      expect(content.contains('android:exported="false"'), isTrue);

      // Check that redundant inner actions were stripped from unexported receiver
      final receiverSection = content.substring(
        content.indexOf('android:name=".widget.WidgetActionReceiver"'),
      );
      final receiverEnd = receiverSection.indexOf('/>');
      expect(receiverEnd, isNot(equals(-1)));
      final receiverTag = receiverSection.substring(0, receiverEnd + 2);
      expect(receiverTag.contains('<intent-filter>'), isFalse);
    });

    test('[W-10] build.gradle.kts pins targetSdk 36 and valid compileSdk', () {
      final gradleFile = File('android/app/build.gradle.kts');
      expect(gradleFile.existsSync(), isTrue);
      final content = gradleFile.readAsStringSync();

      expect(content.contains('targetSdk = 36'), isTrue);
      expect(content.contains('compileSdk = 37'), isTrue);
    });
  });
}
