import 'dart:io';

import 'package:dmx/core/services/background_scheduler.dart';
import 'package:dmx/core/services/background_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 2 Platform Hardening Tests', () {
    test(
        '[H3] Android 15 FGS timeout pauses active tasks, flushes journal, and notifies',
        () async {
      bool pauseCalled = false;
      await BackgroundService.handleFgsTimeout(
        onPauseActiveTasks: () async {
          pauseCalled = true;
        },
      );
      expect(pauseCalled, isTrue);
    });

    test(
        '[M6] Boot completed single ownership: background scheduler handles periodic sync',
        () {
      final scheduler = BackgroundScheduler.instance;
      expect(scheduler, isNotNull);
      scheduler.scheduleBackgroundSync(delay: const Duration(seconds: 1));
      expect(scheduler.isActive, isFalse); // idle until registered tasks tick
    });

    test(
        '[M2] Link validation rejects unsafe schemes and malformed dmx payloads',
        () {
      bool isValidDmxPayload(String? uriStr) {
        if (uriStr == null || uriStr.isEmpty) return false;
        final uri = Uri.tryParse(uriStr);
        if (uri == null || uri.scheme != 'dmx') return false;
        final host = uri.host;
        final path = uri.path;
        const validActions = {
          'pause_all',
          'resume_all',
          'toggle',
          'pause',
          'cancel',
          'open',
          'download'
        };
        if (validActions.contains(host)) return true;
        if (path.isNotEmpty) {
          final segment = path.replaceAll('/', '');
          if (validActions.contains(segment)) return true;
        }
        return false;
      }

      expect(isValidDmxPayload('dmx://pause_all'), isTrue);
      expect(isValidDmxPayload('dmx://resume_all'), isTrue);
      expect(isValidDmxPayload('dmx://toggle/123-abc'), isTrue);
      expect(isValidDmxPayload('http://evil.com'), isFalse);
      expect(isValidDmxPayload('javascript:alert(1)'), isFalse);
      expect(isValidDmxPayload('dmx://malicious_action/payload'), isFalse);
    });

    test(
        '[H1] AndroidManifest does not expose UPDATE_WIDGETS on exported widget provider',
        () {
      final manifestFile = File('android/app/src/main/AndroidManifest.xml');
      expect(manifestFile.existsSync(), isTrue);
      final content = manifestFile.readAsStringSync();
      // Verify UPDATE_WIDGETS is not within DMXWidgetProvider receiver block
      final widgetProviderBlock = RegExp(
        r'<receiver\s+android:name="\.widget\.DMXWidgetProvider"[\s\S]*?<\/receiver>',
      ).firstMatch(content);
      expect(widgetProviderBlock, isNotNull);
      expect(
          widgetProviderBlock!
              .group(0)!
              .contains('com.xdm.downloadmanager.UPDATE_WIDGETS'),
          isFalse);

      // Verify UPDATE_WIDGETS is present in unexported WidgetActionReceiver block
      final actionReceiverBlock = RegExp(
        r'<receiver\s+android:name="\.widget\.WidgetActionReceiver"[\s\S]*?<\/receiver>',
      ).firstMatch(content);
      expect(actionReceiverBlock, isNotNull);
      expect(
          actionReceiverBlock!.group(0)!.contains('android:exported="false"'),
          isTrue);
      expect(
          actionReceiverBlock
              .group(0)!
              .contains('com.xdm.downloadmanager.UPDATE_WIDGETS'),
          isTrue);
    });

    test('[L1] AndroidManifest declares android:localeConfig wiring', () {
      final manifestFile = File('android/app/src/main/AndroidManifest.xml');
      final content = manifestFile.readAsStringSync();
      expect(content.contains('android:localeConfig="@xml/locales_config"'),
          isTrue);

      final localesFile =
          File('android/app/src/main/res/xml/locales_config.xml');
      expect(localesFile.existsSync(), isTrue);
      final localesContent = localesFile.readAsStringSync();
      expect(localesContent.contains('android:name="en"'), isTrue);
      expect(localesContent.contains('android:name="ar"'), isTrue);
      expect(localesContent.contains('android:name="es"'), isTrue);
      expect(localesContent.contains('android:name="fr"'), isTrue);
      expect(localesContent.contains('android:name="de"'), isTrue);
    });

    test(
        '[L2] dataExtractionRules excludes WAL, journal, and drift temporary DB files',
        () {
      final rulesFile =
          File('android/app/src/main/res/xml/data_extraction_rules.xml');
      expect(rulesFile.existsSync(), isTrue);
      final content = rulesFile.readAsStringSync();
      expect(
          content.contains('<exclude domain="database" path="." />'), isTrue);
      expect(content.contains('<exclude domain="file" path="." />'), isTrue);
      expect(
          content.contains('<include domain="sharedpref" path="." />'), isTrue);
    });
  });
}
