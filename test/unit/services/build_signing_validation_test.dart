import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Build Signing Validation Gate Tests [W-7]', () {
    test(
        'build.gradle.kts requires ALLOW_DEBUG_SIGNED_RELEASE=true for debug-signed release builds',
        () {
      final gradleFile = File('android/app/build.gradle.kts');
      expect(gradleFile.existsSync(), isTrue);
      final content = gradleFile.readAsStringSync();

      expect(content.contains('ALLOW_DEBUG_SIGNED_RELEASE'), isTrue);
      expect(content.contains('throw org.gradle.api.GradleException'), isTrue);
    });
  });
}
