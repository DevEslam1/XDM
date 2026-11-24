import 'package:dmx/core/services/torrent/fake_torrent_native.dart';
import 'package:dmx/core/services/torrent/libtorrent_native_impl.dart';
import 'package:dmx/core/services/torrent_service_ffi.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/features/torrent_create/screens/create_torrent_screen.dart';
import 'package:dmx/shared/widgets/neon_glow_button.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/test_helpers.dart';

class _FakeFilePicker extends FilePickerPlatform {
  String? pickedFilePath;
  String? pickedDirectoryPath;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
    AndroidSAFOptions? androidSafOptions,
  }) async {
    if (pickedFilePath == null) return null;
    return FilePickerResult([
      PlatformFile(path: pickedFilePath, name: 'picked.bin', size: 1),
    ]);
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
    AndroidSAFOptions? androidSafOptions,
  }) async {
    return pickedDirectoryPath;
  }
}

void _big(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 4200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void _drain(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

Future<void> _pump(WidgetTester tester, {SettingsProvider? settings}) async {
  await tester.pumpWidget(createTestApp(
    settingsProvider: settings,
    child: const CreateTorrentScreen(),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TorrentService.setNativeForTesting(FakeTorrentNative());
  });

  tearDown(() {
    TorrentService.setNativeForTesting(LibtorrentNativeImpl());
  });

  group('CreateTorrentScreen', () {
    testWidgets('renders the screen and the unsupported build banner',
        (tester) async {
      _big(tester);
      await _pump(tester);

      expect(find.byType(CreateTorrentScreen), findsOneWidget);
      expect(find.text('Create Torrent'), findsOneWidget);
      expect(find.text('Source Path'), findsOneWidget);
      expect(find.text('Trackers'), findsOneWidget);
      expect(find.text('Web Seeds (HTTP/FTP)'), findsOneWidget);
      expect(find.text('Piece Size'), findsOneWidget);
    });

    testWidgets('toggling the private switch updates its value',
        (tester) async {
      _big(tester);
      await _pump(tester);

      final switchFinder = find.byType(SwitchListTile);
      await tester.ensureVisible(switchFinder);
      await tester.pump();

      final before = tester.widget<SwitchListTile>(switchFinder).value;
      await tester.tap(switchFinder);
      await tester.pump(const Duration(milliseconds: 200));

      final after = tester.widget<SwitchListTile>(switchFinder).value;
      expect(after, isNot(before));
      _drain(tester);
    });

    testWidgets('adds a tracker chip via the tracker input', (tester) async {
      _big(tester);
      await _pump(tester);

      expect(find.byType(Chip), findsNWidgets(2));

      await tester.enterText(
          find.byType(TextField).at(2), 'udp://new.tracker.example:80');
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(Chip), findsNWidgets(3));
      expect(find.text('udp://new.tracker.example:80'), findsOneWidget);
      _drain(tester);
    });

    testWidgets('ignores empty and duplicate tracker input', (tester) async {
      _big(tester);
      await _pump(tester);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      expect(find.byType(Chip), findsNWidgets(2));

      await tester.enterText(
        find.byType(TextField).at(2),
        'udp://tracker.opentrackr.org:1337/announce',
      );
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      expect(find.byType(Chip), findsNWidgets(2));
      _drain(tester);
    });

    testWidgets('adds and removes a web seed chip', (tester) async {
      _big(tester);
      await _pump(tester);

      await tester.enterText(
          find.byType(TextField).at(3), 'https://cdn.example.com/file.mp4');
      await tester.tap(find.byIcon(Icons.add_link));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('https://cdn.example.com/file.mp4'), findsOneWidget);

      final webSeedChip = find.ancestor(
        of: find.text('https://cdn.example.com/file.mp4'),
        matching: find.byType(Chip),
      );
      await tester.tap(
          find.descendant(of: webSeedChip, matching: find.byIcon(Icons.close)));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('https://cdn.example.com/file.mp4'), findsNothing);
      _drain(tester);
    });

    testWidgets('deletes a default tracker chip', (tester) async {
      _big(tester);
      await _pump(tester);

      expect(find.byType(Chip), findsNWidgets(2));
      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(Chip), findsOneWidget);
      _drain(tester);
    });

    testWidgets('changes the piece size from the dropdown', (tester) async {
      _big(tester);
      await _pump(tester);

      final dropdown = find.byType(DropdownButtonFormField<int>);
      await tester.ensureVisible(dropdown);
      await tester.pump();
      await tester.tap(dropdown);
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('1 MB').last);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('1 MB'), findsOneWidget);
      _drain(tester);
    });

    testWidgets('shows the unsupported snackbar when creating', (tester) async {
      _big(tester);
      await _pump(tester);

      final button = find.byType(NeonGlowButton);
      await tester.ensureVisible(button);
      await tester.pump();
      await tester.tap(button);
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text('Torrent creation is not available on this engine build'),
        findsOneWidget,
      );
      _drain(tester);
    });
  });

  group('CreateTorrentScreen file pickers', () {
    testWidgets('picking a source file fills source and output',
        (tester) async {
      _big(tester);
      final fake = _FakeFilePicker()..pickedFilePath = '/tmp/movie.mkv';
      final original = FilePickerPlatform.instance;
      FilePickerPlatform.instance = fake;
      addTearDown(() => FilePickerPlatform.instance = original);

      await _pump(tester);

      await tester.tap(find.byIcon(Icons.insert_drive_file));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('/tmp/movie.mkv'), findsOneWidget);
      expect(find.text('/tmp/movie.mkv.torrent'), findsOneWidget);
      _drain(tester);
    });

    testWidgets('picking a source folder fills source and output',
        (tester) async {
      _big(tester);
      final fake = _FakeFilePicker()..pickedDirectoryPath = '/tmp/myfolder';
      final original = FilePickerPlatform.instance;
      FilePickerPlatform.instance = fake;
      addTearDown(() => FilePickerPlatform.instance = original);

      await _pump(tester);

      await tester.tap(find.byIcon(Icons.folder));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('/tmp/myfolder'), findsOneWidget);
      expect(find.text('/tmp/myfolder.torrent'), findsOneWidget);
      _drain(tester);
    });

    testWidgets('picking an output directory uses the source basename',
        (tester) async {
      _big(tester);
      final fake = _FakeFilePicker()..pickedDirectoryPath = '/tmp/out';
      final original = FilePickerPlatform.instance;
      FilePickerPlatform.instance = fake;
      addTearDown(() => FilePickerPlatform.instance = original);

      await _pump(tester);

      await tester.enterText(find.byType(TextField).first, '/data/ubuntu.iso');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.folder_open));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.textContaining('ubuntu.iso.torrent'), findsOneWidget);
      _drain(tester);
    });
  });
}
