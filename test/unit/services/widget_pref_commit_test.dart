import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Widget Preference Commit Sync Tests [W-6]', () {
    test(
        'WidgetDataRepository uses commit() synchronously before broadcasting update',
        () {
      final repoFile = File(
          'android/app/src/main/kotlin/com/xdm/downloadmanager/widget/WidgetDataRepository.kt');
      expect(repoFile.existsSync(), isTrue);
      final content = repoFile.readAsStringSync();

      // Check commit() is used instead of apply() in save()
      expect(content.contains('.commit()'), isTrue);
    });
  });
}
