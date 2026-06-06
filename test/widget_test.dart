import 'package:flutter/services.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

DownloadProvider? downloadProvider;
SettingsProvider? settingsProvider;

Future<DmxApp> _buildTestApp() async {
  SharedPreferences.setMockInitialValues({});
  if (!Hive.isBoxOpen(DatabaseService.downloadsBoxName)) {
    await Hive.openBox<dynamic>(DatabaseService.downloadsBoxName);
  }
  final databaseService = DatabaseService();
  await databaseService.init();
  settingsProvider = SettingsProvider();
  await settingsProvider!.load();
  downloadProvider = DownloadProvider(
    databaseService: databaseService,
    settingsProvider: settingsProvider!,
  );
  await downloadProvider!.load();
  return DmxApp(
    settingsProvider: settingsProvider!,
    downloadProvider: downloadProvider!,
  );
}

void main() {
  setUpAll(() {
    Hive.init('build/test_hive_widget');

    // Register mock handlers for platform channels
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.example.dmx/widget'),
      (methodCall) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (methodCall) async {
        if (methodCall.method == 'check') {
          return ['wifi'];
        }
        return null;
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
      (methodCall) async {
        return null;
      },
    );
  });

  tearDown(() async {
    downloadProvider?.dispose();
    if (Hive.isBoxOpen(DatabaseService.downloadsBoxName)) {
      await Hive.box<dynamic>(DatabaseService.downloadsBoxName).clear();
    }
  });

  testWidgets('DmxApp smoke test - dashboard verification', (tester) async {
    await tester.pumpWidget(await _buildTestApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('XDM'), findsOneWidget);
  });
}
