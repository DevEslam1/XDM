import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Widget Empty Tab State Tests [W-4]', () {
    test(
        'DMXRemoteViewsFactory shows tab-appropriate empty state when selected tab has zero items',
        () {
      final factoryFile = File(
          'android/app/src/main/kotlin/com/xdm/downloadmanager/widget/DMXRemoteViewsFactory.kt');
      expect(factoryFile.existsSync(), isTrue);
      final content = factoryFile.readAsStringSync();

      // Check applyDashboard handles empty tab tasks
      expect(content.contains('No completed downloads yet'), isTrue);
      expect(content.contains('All clear — nothing downloading'), isTrue);
      expect(
          content.contains(
              'views.setViewVisibility(R.id.widget_dash_clear, View.VISIBLE)'),
          isTrue);
      expect(
          content.contains(
              'views.setViewVisibility(R.id.widget_list_clear, View.VISIBLE)'),
          isTrue);
    });
  });
}
