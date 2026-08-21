import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('iOS Background Mode Audit (Task 1.8)', () {
    late String content;

    setUpAll(() {
      const infoPlistPath = 'ios/Runner/Info.plist';
      final file = File(infoPlistPath);
      if (!file.existsSync()) {
        content = '';
      } else {
        content = file.readAsStringSync();
      }
    });

    test('BGTaskSchedulerPermittedIdentifiers contains required task IDs', () {
      if (content.isEmpty) {
        markTestSkipped(
            'ios/Runner/Info.plist not found; skipping on non-iOS builds');
        return;
      }
      expect(content, contains('com.dmx.app.download'),
          reason:
              'BGTaskSchedulerPermittedIdentifiers must include com.dmx.app.download');
      expect(content, contains('com.dmx.app.torrent.refresh'),
          reason:
              'BGTaskSchedulerPermittedIdentifiers must include com.dmx.app.torrent.refresh');
    });

    test('NSAllowsArbitraryLoads is true (supports downloading from arbitrary HTTP/HTTPS URLs)', () {
      if (content.isEmpty) {
        markTestSkipped(
            'ios/Runner/Info.plist not found; skipping on non-iOS builds');
        return;
      }
      final pattern = RegExp(
        r'<key>NSAllowsArbitraryLoads</key>\s*<(true|false)/>',
        dotAll: true,
      );
      final match = pattern.firstMatch(content);
      expect(match, isNotNull,
          reason: 'NSAllowsArbitraryLoads must be declared');
      expect(
        match!.group(1),
        equals('true'),
        reason: 'NSAllowsArbitraryLoads must be true for download manager file transfers',
      );
    });

    test('UIBackgroundModes includes fetch and processing', () {
      if (content.isEmpty) {
        markTestSkipped(
            'ios/Runner/Info.plist not found; skipping on non-iOS builds');
        return;
      }
      expect(content, contains('<string>fetch</string>'),
          reason: 'UIBackgroundModes must include fetch');
      expect(content, contains('<string>processing</string>'),
          reason: 'UIBackgroundModes must include processing');
    });

    test('NSExceptionDomains covers the XDM backend domain', () {
      if (content.isEmpty) {
        markTestSkipped(
            'ios/Runner/Info.plist not found; skipping on non-iOS builds');
        return;
      }
      expect(
        content,
        contains('xdm-backend-10763667121.europe-west1.run.app'),
        reason: 'NSExceptionDomains must pin the XDM backend host',
      );
    });
  });
}
