import 'package:dmx/core/services/background_service.dart';
import 'package:dmx/core/services/notification_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    BackgroundService.testMode = true;
    BackgroundService.resetActiveDownloadCountForTesting();
    BackgroundService.iosBgCallInFlightForTesting = false;
    BackgroundService.iosBgCooldownUntilForTesting = null;
  });

  tearDown(() async {
    BackgroundService.resetActiveDownloadCountForTesting();
    BackgroundService.iosBgCallInFlightForTesting = false;
    BackgroundService.iosBgCooldownUntilForTesting = null;
  });

  group('BackgroundService Hardening (Sprint 1)', () {
    test('Cooldown prevents iOS background invocation while active', () async {
      BackgroundService.iosBgCooldownUntilForTesting =
          DateTime.now().add(const Duration(seconds: 30));

      final success = await BackgroundService.onIosBackgroundForTesting();
      expect(success, isFalse);
    });

    test(
        'Exponential backoff increments delays on repeated failures and clears on success',
        () async {
      expect(await BackgroundService.shouldThrottleForBackoff(), isFalse);

      // Failure 1: 30s
      await BackgroundService.recordBackgroundFailure();
      expect(await BackgroundService.shouldThrottleForBackoff(), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('bg_consecutive_failures'), equals(1));

      // Failure 2: 2m
      await BackgroundService.recordBackgroundFailure();
      expect(prefs.getInt('bg_consecutive_failures'), equals(2));

      // Success clears
      await BackgroundService.recordBackgroundSuccess();
      expect(await BackgroundService.shouldThrottleForBackoff(), isFalse);
      expect(prefs.getInt('bg_consecutive_failures'), isNull);
    });
  });

  group('BackgroundService lifecycle (host-runnable branches)', () {
    test('isSupported is true in test mode', () {
      expect(BackgroundService.isSupported, isTrue);
    });

    test('start then force-stop is safe in test mode', () async {
      await BackgroundService.start();
      expect(BackgroundService.dataSyncSessionStartTimeForTesting, isNotNull);

      await BackgroundService.stop(force: true);
      expect(BackgroundService.dataSyncSessionStartTimeForTesting, isNull);
    });

    test('stop is refused while downloads are active unless forced', () async {
      await BackgroundService.setDownloadActive(true, 'active-1');

      // Non-forced stop must be a no-op (active downloads protect the service).
      await BackgroundService.stop();
      expect(BackgroundService.activeDownloadCountForTesting, equals(1));

      await BackgroundService.stop(force: true);
      expect(BackgroundService.activeDownloadCountForTesting, equals(1));
    });

    test('injected active-download query gates stop()', () async {
      BackgroundService.setActiveDownloadCountQuery(() => 3);
      // Internal set is empty, but the query reports active work.
      await BackgroundService.stop();
      BackgroundService.setActiveDownloadCountQuery(null);
      await BackgroundService.stop(force: true);
    });

    test('wake lock acquire/release are safe in test mode', () async {
      await BackgroundService.acquireWakeLock();
      await BackgroundService.releaseWakeLock();
      await BackgroundService.resetWakeLockState();
    });

    test('onAllDownloadsComplete tears down without throwing', () {
      expect(BackgroundService.onAllDownloadsComplete, returnsNormally);
    });

    test('handleFgsTimeout runs the graceful shutdown path', () async {
      var paused = false;
      await BackgroundService.handleFgsTimeout(
        onPauseActiveTasks: () async => paused = true,
        notificationService: NotificationService(),
      );
      expect(paused, isTrue);
    });

    test('dataSync timeout pauses tracked tasks', () async {
      await BackgroundService.setDownloadActive(true, 'task-timeout');
      await BackgroundService.triggerDataSyncTimeoutForTesting();
      expect(BackgroundService.activeDownloadCountForTesting, equals(1));
      await BackgroundService.setDownloadActive(false, 'task-timeout');
    });

    test('handleFgsTimeout swallows callback errors', () async {
      await BackgroundService.handleFgsTimeout(
        onPauseActiveTasks: () async => throw Exception('boom'),
        notificationService: NotificationService(),
      );
    });

    test('expired iOS cooldown clears and proceeds', () async {
      const channel = MethodChannel('com.dmx.app/background_download');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => true);

      final prefs = await SharedPreferences.getInstance();
      final past = DateTime.now().subtract(const Duration(minutes: 5));
      await prefs.setInt(
          'ios_bg_cooldown_until_ms', past.millisecondsSinceEpoch);
      BackgroundService.iosBgCooldownUntilForTesting = past;

      final result = await BackgroundService.onIosBackgroundForTesting();
      expect(result, isTrue);
      expect(BackgroundService.iosBgCooldownUntilForTesting, isNull);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      BackgroundService.resetIosCooldownForTesting();
    });

    test('iOS native failure records a cooldown', () async {
      const channel = MethodChannel('com.dmx.app/background_download');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'native_failure');
      });

      final result = await BackgroundService.onIosBackgroundForTesting();
      expect(result, isFalse);
      expect(BackgroundService.iosBgCooldownUntilForTesting, isNotNull);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      BackgroundService.resetIosCooldownForTesting();
    });
  });
}
