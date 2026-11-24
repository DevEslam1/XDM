import 'package:dmx/core/interfaces/i_torrent_native.dart';
import 'package:dmx/core/services/torrent/fake_torrent_native.dart';
import 'package:dmx/core/services/torrent_service_ffi.dart';
import 'package:dmx/features/torrent_create/screens/create_torrent_screen.dart';
import 'package:dmx/shared/widgets/neon_glow_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/test_helpers.dart';

void _big(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 4200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void _drain(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(createTestApp(child: const CreateTorrentScreen()));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _tapCreate(WidgetTester tester) async {
  final button = find.byType(NeonGlowButton);
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await tester.pump(const Duration(milliseconds: 400));
}

class _NullCreateNative extends FakeTorrentNative {
  @override
  Future<String?> createTorrent({
    required String sourcePath,
    required String outputPath,
    required List<String> trackers,
    String comment = '',
    int pieceSize = 0,
    bool isPrivate = false,
  }) async {
    return null;
  }
}

class _ThrowingCreateNative extends FakeTorrentNative {
  @override
  Future<String?> createTorrent({
    required String sourcePath,
    required String outputPath,
    required List<String> trackers,
    String comment = '',
    int pieceSize = 0,
    bool isPrivate = false,
  }) async {
    throw Exception('boom');
  }
}

FakeTorrentNative _supportedNative() {
  final native = FakeTorrentNative();
  native.capabilities = const TorrentNativeCapabilities(createTorrent: true);
  return native;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    // Keep the global native from leaking between files that assume 1.9.2.
    TorrentService.setNativeForTesting(FakeTorrentNative());
  });

  group('CreateTorrentScreen with a supporting engine', () {
    testWidgets('hides the unsupported banner and creates a torrent',
        (tester) async {
      _big(tester);
      TorrentService.setNativeForTesting(_supportedNative());

      await _pump(tester);

      expect(
        find.textContaining('not supported on this engine build'),
        findsNothing,
      );

      await tester.enterText(find.byType(TextField).at(0), '/tmp/source.mkv');
      await tester.pump();
      await _tapCreate(tester);

      expect(
        find.text('Torrent file created successfully!'),
        findsOneWidget,
      );
      _drain(tester);
    });

    testWidgets('validates that a source path is required', (tester) async {
      _big(tester);
      TorrentService.setNativeForTesting(_supportedNative());

      await _pump(tester);
      await _tapCreate(tester);

      expect(
        find.text('Please select a source file or folder'),
        findsOneWidget,
      );
      _drain(tester);
    });

    testWidgets('reports an empty result from the engine', (tester) async {
      _big(tester);
      TorrentService.setNativeForTesting(_NullCreateNative()
        ..capabilities = const TorrentNativeCapabilities(createTorrent: true));

      await _pump(tester);
      await tester.enterText(find.byType(TextField).at(0), '/tmp/source.mkv');
      await tester.pump();
      await _tapCreate(tester);

      expect(
        find.text('Torrent creation returned empty result'),
        findsOneWidget,
      );
      _drain(tester);
    });

    testWidgets('reports a failure when the engine throws', (tester) async {
      _big(tester);
      TorrentService.setNativeForTesting(_ThrowingCreateNative()
        ..capabilities = const TorrentNativeCapabilities(createTorrent: true));

      await _pump(tester);
      await tester.enterText(find.byType(TextField).at(0), '/tmp/source.mkv');
      await tester.pump();
      await _tapCreate(tester);

      expect(find.textContaining('Creation failed:'), findsOneWidget);
      _drain(tester);
    });
  });
}
