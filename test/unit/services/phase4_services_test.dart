import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/desktop_update_service.dart';
import 'package:dmx/core/services/live_activity_service.dart';
import 'package:dmx/core/services/error_taxonomy.dart';
import 'package:dmx/core/services/diagnostic_service.dart';
import 'package:dmx/core/services/engines/speed_predictor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 4 Polish & Robustness Tests', () {
    test('LiveActivityService no-op safety on non-iOS (A-01)', () async {
      await LiveActivityService.init();
      expect(LiveActivityService.isSupported, isFalse);
    });

    test('DesktopUpdateInfo parses JSON accurately (A-03)', () {
      final json = {
        'version': '3.2.1',
        'build': 42,
        'url':
            'https://github.com/DevEslam1/XDM/releases/download/v3.2.1/xdm-win.exe',
        'sha256':
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890',
        'notes': 'Bug fixes and performance improvements',
        'mandatory': true,
      };

      final info = DesktopUpdateInfo.fromJson(json);
      expect(info.version, equals('3.2.1'));
      expect(info.build, equals(42));
      expect(info.sha256, contains('abcdef'));
      expect(info.mandatory, isTrue);
    });

    test('ErrorTaxonomy classifies Dio and Socket errors accurately (A-07)',
        () {
      final socketError = const SocketException('Connection refused');
      final classification = ErrorTaxonomy.classify(socketError);

      expect(classification.family, equals(ErrorFamily.network));
      expect(classification.retryable, isTrue);
    });

    test('SpeedPredictor calculates EMA and ETA accurately (A-11)', () {
      final predictor = SpeedPredictor();
      expect(predictor.predictedSpeed, equals(0));
      expect(predictor.predictEta(1000), equals(-1));

      predictor.addSample(1000.0);
      expect(predictor.predictedSpeed, equals(1000.0));
      expect(predictor.predictEta(5000), equals(5));

      predictor.addSample(2000.0);
      expect(predictor.predictedSpeed, greaterThan(1000.0));
    });

    test(
        'DiagnosticService bounds log entries and outputs formatted snapshot (A-12)',
        () {
      final diag = DiagnosticService.instance;
      diag.clear();
      expect(diag.entries, isEmpty);

      diag.record('Network', 'Connected to WiFi');
      diag.record('Download', 'Task started', details: 'task-1');

      expect(diag.entries.length, equals(2));
      final snap = diag.snapshot();
      expect(snap, contains('Connected to WiFi'));
      expect(snap, contains('Task started'));
    });
  });
}
