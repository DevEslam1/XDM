import 'package:dmx/core/services/background_gate.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/shared/mixins/pausable_loop_animation.dart';
import 'package:dmx/shared/widgets/dmx_backdrop_filter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Audit Remediation: GPU & Visuals Hardening', () {
    setUp(() {
      DmxBackdropFilter.resetActiveCount();
      DownloadEngine.appInForeground = true;
    });

    tearDown(() {
      DmxBackdropFilter.resetActiveCount();
      DownloadEngine.appInForeground = true;
    });

    testWidgets(
        'DmxBackdropFilter renders solid Container when appInForeground is false',
        (tester) async {
      DownloadEngine.appInForeground = false;
      expect(BackgroundGate.allowHeavyOps, isFalse);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: SettingsProvider.instance,
          child: const MaterialApp(
            home: Scaffold(
              body: DmxBackdropFilter(
                sigmaX: 15,
                sigmaY: 15,
                child: Text('Background Test'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Background Test'), findsOneWidget);
      // BackdropFilter should NOT have incremented active count when allowHeavyOps is false
      expect(DmxBackdropFilter.activeCount, equals(0));
    });

    testWidgets(
        'modernAnimationsAllowed returns false when allowHeavyOps is false',
        (tester) async {
      DownloadEngine.appInForeground = false;
      expect(BackgroundGate.allowHeavyOps, isFalse);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: SettingsProvider.instance,
          child: Builder(
            builder: (context) {
              final allowed = modernAnimationsAllowed(context);
              expect(allowed, isFalse);
              return const SizedBox();
            },
          ),
        ),
      );
    });
  });

  group('Audit Remediation: StateStore & Chunks Normalization', () {
    test(
        'TransferState.tryParseV3 normalizes threadCount to chunk array length safely',
        () {
      final json = {
        'version': 3,
        'v': 3,
        'totalSize': 1000,
        'threadCount': 8, // Mismatch with actual chunks length (2)
        'chunks': [
          {'start': 0, 'end': 499, 'downloaded': 100},
          {'start': 500, 'end': 999, 'downloaded': 200},
        ],
        'status': 'active',
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      };

      final state = TransferState.tryParseV3(json);
      expect(state, isNotNull);
      expect(state!.chunks.length, equals(2));
      expect(state.downloadedBytes, equals(300));
    });
  });
}
