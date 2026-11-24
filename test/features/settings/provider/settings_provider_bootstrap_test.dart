import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _secureStorageChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loadedInstance throws before load then resolves the singleton',
      () async {
    // The singleton has not been created/loaded yet in this fresh isolate.
    expect(() => SettingsProvider.loadedInstance, throwsStateError);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      _secureStorageChannel,
      (call) async => null,
    );
    // Legacy plaintext proxy password must be migrated to secure storage during
    // load().
    SharedPreferences.setMockInitialValues({
      'torrent_proxy_password': 'legacy-secret',
    });

    final settings = SettingsProvider.instance;
    await settings.load();

    expect(settings.proxyPassword, 'legacy-secret');
    // factory constructor returns the loaded singleton.
    expect(SettingsProvider(), same(settings));
    expect(SettingsProvider.loadedInstance, same(settings));

    // dispose() removes the observer and marks the provider disposed.
    settings.dispose();
    expect(settings.autoStart, isTrue);
  });
}
