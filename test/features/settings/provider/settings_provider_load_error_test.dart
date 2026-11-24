// ignore_for_file: avoid_dynamic_calls
import 'dart:async';

import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _secureStorageChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('load() rethrows and clears the in-flight completer on failure',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      _secureStorageChannel,
      (call) async {
        if (call.method == 'read' &&
            call.arguments['key'] == 'backend_token') {
          throw PlatformException(code: 'storage_failure');
        }
        return null;
      },
    );
    SharedPreferences.setMockInitialValues({});

    final settings = SettingsProvider.instance;

    final loadFuture = settings.load();
    // Swallow the completer error so it is not reported as unhandled.
    unawaited(settings.ensureLoaded().catchError((_) {}));

    await expectLater(loadFuture, throwsA(isA<PlatformException>()));
  });
}
