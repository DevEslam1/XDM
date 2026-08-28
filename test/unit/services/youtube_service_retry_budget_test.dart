import 'package:dmx/core/services/youtube_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('YouTube Retry Budget Tests (Y-03 / Y-05)', () {
    setUp(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (methodCall) async => null,
      );
      SharedPreferences.setMockInitialValues({
        'use_remote_backend': true,
        'backend_url': 'http://127.0.0.1:59999',
      });
      YoutubeService.resetClientCooldowns();
    });

    test('getStreams honors 45s total retry budget cap', () async {
      final sw = Stopwatch()..start();

      try {
        await YoutubeService.getStreams(
            'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
      } catch (e) {
        // Expected to fail on unreachable backend
      }

      sw.stop();
      // Total elapsed time must not exceed 45 seconds + small overhead
      expect(sw.elapsed.inSeconds, lessThanOrEqualTo(46));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
