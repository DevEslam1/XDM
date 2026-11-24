import 'package:dmx/core/services/notification_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingNotificationsPlatform
    extends FlutterLocalNotificationsPlatform {
  final List<String> calls = [];

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    String? payload,
  }) async {
    calls.add('show:$id');
  }

  @override
  Future<void> cancel({required int id}) async {
    calls.add('cancel:$id');
  }

  @override
  Future<void> cancelAll() async {
    calls.add('cancelAll');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingNotificationsPlatform platform;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    platform = _RecordingNotificationsPlatform();
    FlutterLocalNotificationsPlatform.instance = platform;
    // Force the plugin into its generic fallback branch so every surface routes
    // to the recording platform instead of the unavailable Windows plugin.
    debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
    // The host test VM is not a mobile/desktop notification platform, so the
    // service's early `isSupported` guards are bypassed explicitly.
    NotificationService.setInitializedForTesting(true);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    NotificationService().showHookForTesting = null;
  });

  group('platform guards', () {
    test('isSupported is false in the test VM', () {
      expect(NotificationService.isSupported, isFalse);
    });

    test('requestNotificationPermission short-circuits when unsupported',
        () async {
      expect(
          await NotificationService().requestNotificationPermission(), isTrue);
    });

    test('resetInit clears the cached init future', () {
      expect(NotificationService().resetInit, returnsNormally);
    });

    test('showServiceNotification is a no-op off Android', () async {
      await NotificationService()
          .showServiceNotification(title: 't', content: 'c');
      expect(platform.calls, isEmpty);
    });
  });

  group('showDownloadProgress', () {
    test('routes the composed body through the test hook', () async {
      final svc = NotificationService();
      final captured = <String>[];
      svc.showHookForTesting = ({
        required int id,
        required String title,
        required String body,
      }) async {
        captured.add('$id|$title|$body');
      };

      await svc.showDownloadProgress(
        notificationId: 1,
        title: 'File',
        progressPercent: 150,
        speed: '5 MB/s',
        eta: '',
        languageCode: 'en',
        payload: 'task-1',
      );
      expect(captured.single, '1|File|5 MB/s');

      await svc.showDownloadProgress(
        notificationId: 1,
        title: 'File',
        progressPercent: 10,
        speed: '1 MB/s',
        eta: '2m 5s',
        languageCode: 'en',
        payload: 'task-1',
        isPaused: true,
        hasMultipleActive: true,
        groupKey: 'grp',
      );
      expect(captured, hasLength(2));
      expect(captured.last, startsWith('1|File|'));
    });

    test('posts directly to the plugin when no hook is installed', () async {
      final svc = NotificationService();
      await svc.showDownloadProgress(
        notificationId: 11,
        title: 'Live',
        progressPercent: 5,
        speed: 's',
        eta: '1s',
        languageCode: 'en',
        payload: 'p',
      );
      expect(platform.calls, contains('show:11'));
    });

    test('throttles rapid posts for the same id and can be cancelled',
        () async {
      final svc = NotificationService();
      final captured = <String>[];
      svc.showHookForTesting = ({
        required int id,
        required String title,
        required String body,
      }) async {
        captured.add('$id');
      };

      await svc.showDownloadProgress(
        notificationId: 2,
        title: 'T',
        progressPercent: 5,
        speed: 's',
        eta: '',
        languageCode: 'en',
        payload: 'p',
      );
      // Second immediate call is inside the throttle window and returns.
      await svc.showDownloadProgress(
        notificationId: 2,
        title: 'T',
        progressPercent: 6,
        speed: 's',
        eta: '',
        languageCode: 'en',
        payload: 'p',
      );
      expect(captured, ['2']);

      await svc.cancelNotification(2);
      expect(platform.calls, contains('cancel:2'));
    });
  });

  group('other notification surfaces', () {
    test('showGroupSummary no-ops without a group key but posts with one',
        () async {
      final svc = NotificationService();
      await svc.showGroupSummary(notificationId: 3, activeCount: 0);
      expect(platform.calls, isEmpty);

      await svc.showGroupSummary(
        notificationId: 3,
        activeCount: 2,
        groupKey: 'grp',
      );
      expect(platform.calls, contains('show:3'));
    });

    test('showDownloadComplete covers sound and silent channels', () async {
      final svc = NotificationService();
      await svc.showDownloadComplete(notificationId: 4, title: 'done');
      await svc.showDownloadComplete(
        notificationId: 5,
        title: 'done',
        playSound: false,
      );
      expect(platform.calls.where((c) => c.startsWith('show:')).length, 2);
    });

    test('showDownloadFailed covers error and fallback body', () async {
      final svc = NotificationService();
      await svc.showDownloadFailed(
        notificationId: 6,
        title: 'fail',
        error: 'boom',
      );
      await svc.showDownloadFailed(
        notificationId: 7,
        title: 'fail',
        playSound: false,
      );
      expect(platform.calls.where((c) => c.startsWith('show:')).length, 2);
    });

    test('showTimeoutNotice uses defaults and overrides', () async {
      final svc = NotificationService();
      await svc.showTimeoutNotice();
      await svc.showTimeoutNotice(
        notificationId: 8,
        title: 'custom',
        body: 'custom body',
        languageCode: 'es',
      );
      expect(platform.calls.where((c) => c.startsWith('show:')).length, 2);
    });

    test('showProgress delegates to showDownloadProgress', () async {
      final svc = NotificationService();
      final captured = <String>[];
      svc.showHookForTesting = ({
        required int id,
        required String title,
        required String body,
      }) async {
        captured.add('$id|$title');
      };
      await svc.showProgress(
        notificationId: 9,
        title: 'Delegated',
        progressPercent: 33,
      );
      expect(captured, ['9|Delegated']);
    });

    test('cancelAll clears trailing state and calls the plugin', () async {
      final svc = NotificationService();
      await svc.showDownloadProgress(
        notificationId: 10,
        title: 'T',
        progressPercent: 1,
        speed: 's',
        eta: '',
        languageCode: 'en',
        payload: 'p',
      );
      await svc.cancelAll();
      expect(platform.calls, contains('cancelAll'));
    });
  });

  group('action queue', () {
    test('deduplicates rapid identical taps', () async {
      final svc = NotificationService();
      final received = <Map<String, String>>[];
      final sub = svc.onActionTapped.listen(received.add);

      svc.handleNotificationActionForTest({'action': 'pause', 'taskId': 'dup'});
      svc.handleNotificationActionForTest({'action': 'pause', 'taskId': 'dup'});
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(received.where((e) => e['taskId'] == 'dup'), hasLength(1));
      await sub.cancel();
    });

    test('caps the buffered queue and prunes the debounce map', () async {
      final svc = NotificationService();
      for (var i = 0; i < 120; i++) {
        svc.handleNotificationActionForTest({
          'action': 'open',
          'taskId': 'queued_$i',
        });
      }

      final received = <Map<String, String>>[];
      final sub = svc.onActionTapped.listen(received.add);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(received, hasLength(50));
      expect(received.first['taskId'], 'queued_70');
      expect(received.last['taskId'], 'queued_119');
      await sub.cancel();
    });

    test('dispose clears queued state and closes the stream', () async {
      final svc = NotificationService();
      svc.handleNotificationActionForTest({'action': 'stop', 'taskId': 'z'});
      await svc.dispose();
      expect(platform.calls, contains('cancelAll'));
    });
  });
}
