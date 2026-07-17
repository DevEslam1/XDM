import 'dart:io';
import 'package:flutter/services.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';

class MockConnectivityPlatform extends ConnectivityPlatform {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async {
    return [ConnectivityResult.wifi];
  }

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged {
    return Stream.value([ConnectivityResult.wifi]);
  }
}

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
    databaseService: databaseService,
    settingsProvider: settingsProvider!,
    downloadProvider: downloadProvider!,
  );
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    try {
      final dir = Directory('build/test_hive_widget');
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    } catch (_) {}
    Hive.init('build/test_hive_widget');
    ConnectivityPlatform.instance = MockConnectivityPlatform();

    // Register mock handlers for platform channels
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.example.dmx/widget'),
      (methodCall) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (methodCall) async {
        switch (methodCall.method) {
          case 'read':
            return null;
          case 'write':
          case 'delete':
          case 'containsKey':
          case 'readAll':
          default:
            return null;
        }
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
    final app = (await tester.runAsync(() => _buildTestApp()))!;
    await tester.pumpWidget(app);
    // Pump a frame to trigger postFrameCallback in SplashScreen
    await tester.pump();
    // Pump another frame to allow navigation
    await tester.pump(const Duration(milliseconds: 100));

    // The splash screen should show 'XDM' in its title
    expect(find.textContaining('XDM'), findsWidgets);
  });
}
