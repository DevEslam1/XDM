import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/browser/services/long_press_parser.dart';
import 'package:dmx/features/browser/widgets/browser_download_sheet.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_services.dart';
import '../helpers/test_helpers.dart';

/// A DownloadProvider whose task list is provided directly, avoiding the heavy
/// async `load()` pipeline.
class _StaticTasksProvider extends DownloadProvider {
  _StaticTasksProvider({
    required DatabaseService database,
    required SettingsProvider settings,
    required List<DownloadTask> staticTasks,
  })  : _staticTasks = staticTasks,
        super(
          databaseService: database,
          settingsProvider: settings,
          downloadEngine: FakeDownloadEngine(),
          permissionService: FakePermissionService(),
          enableBackgroundTimers: false,
        );

  final List<DownloadTask> _staticTasks;

  @override
  List<DownloadTask> get tasks => List<DownloadTask>.unmodifiable(_staticTasks);
}

void main() {
  setUp(() {
    setupTestPluginMocks();
  });

  Future<void> pumpSheet(
    WidgetTester tester, {
    String url = 'https://example.com/video.mp4',
    String? type,
    String? text,
    String? suggestedName,
    VoidCallback? onQuality,
    VoidCallback? onOpen,
    VoidCallback? onOpenInBackground,
    VoidCallback? onOpenInNewTab,
    VoidCallback? onOpenInIncognito,
    List<MediaSourceItem> sources = const [],
    DownloadProvider? provider,
  }) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(createTestApp(
      child: BrowserDownloadSheet(
        url: url,
        type: type,
        text: text,
        suggestedName: suggestedName,
        onQuality: onQuality,
        onOpen: onOpen,
        onOpenInBackground: onOpenInBackground,
        onOpenInNewTab: onOpenInNewTab,
        onOpenInIncognito: onOpenInIncognito,
        sources: sources,
      ),
      downloadProvider: provider,
    ));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('renders signal lock header with suggested name', (tester) async {
    await pumpSheet(
      tester,
      suggestedName: 'My Clip',
      text: 'A nice video',
    );

    expect(find.byType(BrowserDownloadSheet), findsOneWidget);
    expect(find.text('SIGNAL LOCKED'), findsOneWidget);
    expect(find.text('My Clip'), findsOneWidget);
    expect(find.text('A nice video'), findsOneWidget);
    expect(find.text('DOWNLOAD'), findsOneWidget);
    expect(find.text('DISMISS'), findsOneWidget);
  });

  testWidgets('detects media kinds for type variants', (tester) async {
    for (final type in ['video', 'audio', 'image']) {
      await pumpSheet(tester, type: type, suggestedName: 'file.bin');
      expect(
          find.byIcon(
            type == 'video'
                ? Icons.movie_outlined
                : type == 'audio'
                    ? Icons.audiotrack_outlined
                    : Icons.image_outlined,
          ),
          findsWidgets);
    }
  });

  testWidgets('open callback fires', (tester) async {
    var open = 0;
    await pumpSheet(
      tester,
      suggestedName: 'clip.mp4',
      onOpen: () => open++,
    );

    await tester.tap(find.text('OPEN'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(open, 1);
  });

  testWidgets('open in background callback fires', (tester) async {
    var bg = 0;
    await pumpSheet(
      tester,
      suggestedName: 'clip.mp4',
      onOpenInBackground: () => bg++,
    );

    await tester.tap(find.text('OPEN IN BG'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(bg, 1);
  });

  testWidgets('open in new tab callback fires', (tester) async {
    var tab = 0;
    await pumpSheet(
      tester,
      suggestedName: 'clip.mp4',
      onOpenInNewTab: () => tab++,
    );

    await tester.tap(find.text('OPEN IN NEW TAB'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(tab, 1);
  });

  testWidgets('open in incognito callback fires', (tester) async {
    var incog = 0;
    await pumpSheet(
      tester,
      suggestedName: 'clip.mp4',
      onOpenInIncognito: () => incog++,
    );

    await tester.tap(find.text('OPEN IN INCOGNITO'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(incog, 1);
  });

  testWidgets('quality callback fires', (tester) async {
    var quality = 0;
    await pumpSheet(
      tester,
      suggestedName: 'clip.mp4',
      onQuality: () => quality++,
    );

    await tester.tap(find.text('QUALITY'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(quality, 1);
  });

  testWidgets('sources render and are tappable', (tester) async {
    await pumpSheet(
      tester,
      suggestedName: 'clip.mp4',
      sources: const [
        MediaSourceItem(label: '720p', url: 'https://x/720.mp4', type: 'video'),
        MediaSourceItem(
            label: '1080p', url: 'https://x/1080.mp4', type: 'video'),
      ],
    );

    expect(find.text('SOURCES'), findsOneWidget);
    expect(find.text('720p'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);
  });

  testWidgets('download deduplicates an existing completed task',
      (tester) async {
    final db = FakeDatabaseService();
    final provider = _StaticTasksProvider(
      database: db,
      settings: createMockSettingsProvider(),
      staticTasks: [
        createTestTask(
          url: 'https://example.com/video.mp4',
          fileName: 'video.mp4',
          status: DownloadStatus.completed,
        ),
      ],
    );

    await pumpSheet(tester, suggestedName: 'video.mp4', provider: provider);

    await tester.tap(find.text('DOWNLOAD'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(provider.tasks, hasLength(1));
  });

  testWidgets('dismiss closes the sheet', (tester) async {
    await pumpSheet(tester, suggestedName: 'clip.mp4');

    await tester.tap(find.text('DISMISS'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
  });
}
