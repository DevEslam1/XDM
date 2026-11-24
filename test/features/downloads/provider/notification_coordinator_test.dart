import 'dart:async';

import 'package:dmx/core/services/notification_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/notification_coordinator.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockNotificationService extends Mock implements NotificationService {}

DownloadTask _task(
  String id, {
  DownloadStatus status = DownloadStatus.downloading,
  bool isAppUpdate = false,
  String fileName = 'file.zip',
  String localFilePath = '/d/file.zip',
}) {
  final now = DateTime(2026, 1, 1);
  return DownloadTask(
    id: id,
    fileName: fileName,
    url: 'https://example.com/$id',
    fileSize: 100,
    downloadedBytes: 0,
    category: 'Other',
    status: status,
    savePath: '/d',
    localFilePath: localFilePath,
    tempFilePath: '/d/$id.dmxpart',
    threadCount: 1,
    chunks: const [0.0],
    createdAt: now,
    updatedAt: now,
    isAppUpdate: isAppUpdate,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (methodCall) async => null,
    );
  });

  late _MockNotificationService service;
  late SettingsProvider settings;
  late NotificationCoordinator coordinator;
  late StreamController<Map<String, String>> actions;
  late List<DownloadTask> foundTasks;
  late List<String> paused;
  late List<String> resumed;
  late List<String> cancelled;
  late int pauseAllCount;
  late int resumeAllCount;
  late int stopAllCount;
  late int startAllCount;
  late int exitCount;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    service = _MockNotificationService();
    actions = StreamController<Map<String, String>>.broadcast();
    when(() => service.onActionTapped).thenAnswer((_) => actions.stream);
    when(() => service.cancelNotification(any())).thenAnswer((_) async {});
    when(() => service.cancelAll()).thenAnswer((_) async {});
    when(() => service.showDownloadComplete(
          notificationId: any(named: 'notificationId'),
          title: any(named: 'title'),
          body: any(named: 'body'),
          playSound: any(named: 'playSound'),
          payload: any(named: 'payload'),
          actions: any(named: 'actions'),
        )).thenAnswer((_) async {});
    when(() => service.showDownloadProgress(
          notificationId: any(named: 'notificationId'),
          title: any(named: 'title'),
          progressPercent: any(named: 'progressPercent'),
          speed: any(named: 'speed'),
          eta: any(named: 'eta'),
          languageCode: any(named: 'languageCode'),
          payload: any(named: 'payload'),
          isPaused: any(named: 'isPaused'),
          hasMultipleActive: any(named: 'hasMultipleActive'),
          groupKey: any(named: 'groupKey'),
        )).thenAnswer((_) async {});
    when(() => service.showDownloadFailed(
          notificationId: any(named: 'notificationId'),
          title: any(named: 'title'),
          error: any(named: 'error'),
          playSound: any(named: 'playSound'),
        )).thenAnswer((_) async {});
    when(() => service.showGroupSummary(
          notificationId: any(named: 'notificationId'),
          activeCount: any(named: 'activeCount'),
          groupKey: any(named: 'groupKey'),
        )).thenAnswer((_) async {});
    when(() => service.showServiceNotification(
          title: any(named: 'title'),
          content: any(named: 'content'),
        )).thenAnswer((_) async {});
    when(() => service.stopPollingPendingActions()).thenReturn(null);

    settings = SettingsProvider();
    await settings.load();
    settings.notificationsEnabled = true;
    settings.soundNotification = true;

    foundTasks = [];
    paused = [];
    resumed = [];
    cancelled = [];
    pauseAllCount = 0;
    resumeAllCount = 0;
    stopAllCount = 0;
    startAllCount = 0;
    exitCount = 0;

    coordinator = NotificationCoordinator(
      notificationService: service,
      settingsProvider: settings,
      downloadingTasksCount: () => 1,
      currentDownloadSpeed: () => 1024,
      findTask: (id) {
        for (final t in foundTasks) {
          if (t.id == id) return t;
        }
        return null;
      },
      onPauseTask: (id) async => paused.add(id),
      onResumeTask: (id) async => resumed.add(id),
      onCancelTask: (id) async => cancelled.add(id),
      onPauseAll: () async => pauseAllCount++,
      onResumeAll: () async => resumeAllCount++,
      onStopAll: () async => stopAllCount++,
      onStartAll: () async => startAllCount++,
      onExitApp: () async => exitCount++,
    );
  });

  tearDown(() async {
    coordinator.dispose();
    await actions.close();
  });

  group('init and id allocation', () {
    test('init subscribes to action stream idempotently', () {
      coordinator.init();
      coordinator.init();
      verify(() => service.onActionTapped).called(greaterThanOrEqualTo(1));
    });

    test('idFor allocates stable incrementing ids', () {
      final a = coordinator.idFor('a');
      final b = coordinator.idFor('b');
      expect(coordinator.idFor('a'), a);
      expect(b, isNot(a));
    });

    test('opaqueHandleFor is stable and persisted', () async {
      final h1 = coordinator.opaqueHandleFor('task1');
      final h2 = coordinator.opaqueHandleFor('task1');
      expect(h1, h2);
      expect(h1, isNotEmpty);
      await Future<void>.delayed(Duration.zero);
    });
  });

  group('notification lifecycle', () {
    test('cancelForTask cancels a known notification', () async {
      final id = coordinator.idFor('a');
      coordinator.cancelForTask('a');
      await Future<void>.delayed(Duration.zero);
      verify(() => service.cancelNotification(id)).called(1);
    });

    test('cancelForTask is a no-op for unknown task', () {
      coordinator.cancelForTask('missing');
      verifyNever(() => service.cancelNotification(any()));
    });

    test('removeId returns the removed notification id', () {
      final id = coordinator.idFor('a');
      expect(coordinator.removeId('a'), id);
      expect(coordinator.removeId('a'), isNull);
    });

    test('cancelNotification and cancelGroupSummary delegate', () {
      coordinator.cancelNotification(7);
      coordinator.cancelGroupSummary();
      verify(() => service.cancelNotification(7)).called(1);
      verify(() => service.cancelNotification(9001)).called(1);
    });

    test('cancelAll delegates', () async {
      await coordinator.cancelAll();
      verify(() => service.cancelAll()).called(1);
    });

    test('cleanupTask removes mapping and cancels', () async {
      final id = coordinator.idFor('a');
      coordinator.cleanupTask('a');
      await Future<void>.delayed(Duration.zero);
      verify(() => service.cancelNotification(id)).called(1);
    });
  });

  group('showComplete', () {
    test('disabled notifications is a no-op', () {
      settings.notificationsEnabled = false;
      coordinator.showComplete(_task('a'), 1);
      verifyNever(() => service.showDownloadComplete(
            notificationId: any(named: 'notificationId'),
            title: any(named: 'title'),
            body: any(named: 'body'),
            playSound: any(named: 'playSound'),
            payload: any(named: 'payload'),
            actions: any(named: 'actions'),
          ));
    });

    test('regular completion posts a complete notification', () {
      coordinator.showComplete(_task('a'), 5);
      verify(() => service.showDownloadComplete(
            notificationId: 5,
            title: any(named: 'title'),
            body: any(named: 'body'),
            playSound: any(named: 'playSound'),
            payload: any(named: 'payload'),
            actions: any(named: 'actions'),
          )).called(1);
    });

    test('app update includes an install action', () {
      coordinator.showComplete(_task('a', isAppUpdate: true), 6);
      final captured = verify(() => service.showDownloadComplete(
            notificationId: 6,
            title: any(named: 'title'),
            body: any(named: 'body'),
            playSound: any(named: 'playSound'),
            payload: any(named: 'payload'),
            actions: captureAny(named: 'actions'),
          )).captured.single as List?;
      expect(captured, isNotNull);
      expect(captured, isNotEmpty);
    });
  });

  group('showScheduledStarted', () {
    test('disabled is a no-op', () {
      settings.notificationsEnabled = false;
      coordinator.showScheduledStarted('show', DateTime(2026, 1, 1, 9, 5));
      verifyNever(() => service.showDownloadComplete(
            notificationId: any(named: 'notificationId'),
            title: any(named: 'title'),
            body: any(named: 'body'),
            playSound: any(named: 'playSound'),
            payload: any(named: 'payload'),
            actions: any(named: 'actions'),
          ));
    });

    test('enabled posts scheduled notification', () {
      coordinator.showScheduledStarted('show', DateTime(2026, 1, 1, 9, 5));
      verify(() => service.showDownloadComplete(
            notificationId: any(named: 'notificationId'),
            title: 'Scheduled download started',
            body: any(named: 'body'),
            playSound: any(named: 'playSound'),
          )).called(1);
    });
  });

  group('showProgress', () {
    test('disabled is a no-op', () {
      settings.notificationsEnabled = false;
      coordinator.showProgress(
        notificationId: 1,
        title: 't',
        progressPercent: 10,
        speed: '1 KB/s',
        eta: '1s',
        payload: 'h',
      );
      verifyNever(() => service.showDownloadProgress(
            notificationId: any(named: 'notificationId'),
            title: any(named: 'title'),
            progressPercent: any(named: 'progressPercent'),
            speed: any(named: 'speed'),
            eta: any(named: 'eta'),
            languageCode: any(named: 'languageCode'),
            payload: any(named: 'payload'),
            isPaused: any(named: 'isPaused'),
            hasMultipleActive: any(named: 'hasMultipleActive'),
            groupKey: any(named: 'groupKey'),
          ));
    });

    test('single active task posts progress and cancels summary', () {
      coordinator.showProgress(
        notificationId: 1,
        title: 't',
        progressPercent: 10,
        speed: '1 KB/s',
        eta: '1s',
        payload: 'h',
      );
      verify(() => service.showDownloadProgress(
            notificationId: 1,
            title: 't',
            progressPercent: 10,
            speed: '1 KB/s',
            eta: '1s',
            languageCode: any(named: 'languageCode'),
            payload: 'h',
            isPaused: false,
            hasMultipleActive: false,
            groupKey: any(named: 'groupKey'),
          )).called(1);
      verifyNever(() => service.showGroupSummary(
            notificationId: any(named: 'notificationId'),
            activeCount: any(named: 'activeCount'),
            groupKey: any(named: 'groupKey'),
          ));
    });

    test('multiple active posts group summary', () async {
      final multi = NotificationCoordinator(
        notificationService: service,
        settingsProvider: settings,
        downloadingTasksCount: () => 2,
        currentDownloadSpeed: () => 0,
        findTask: (_) => null,
        onPauseTask: (_) async {},
        onResumeTask: (_) async {},
        onCancelTask: (_) async {},
        onPauseAll: () async {},
        onResumeAll: () async {},
        onStopAll: () async {},
        onStartAll: () async {},
        onExitApp: () async {},
      );
      multi.showProgress(
        notificationId: 2,
        title: 't',
        progressPercent: 10,
        speed: '',
        eta: '',
        payload: 'h',
      );
      await Future<void>.delayed(Duration.zero);
      verify(() => service.showGroupSummary(
            notificationId: 9001,
            activeCount: 2,
            groupKey: any(named: 'groupKey'),
          )).called(1);
      multi.dispose();
    });

    test('progressPercent 100 bypasses throttling', () {
      coordinator.showProgress(
        notificationId: 1,
        title: 't',
        progressPercent: 10,
        speed: '',
        eta: '',
        payload: 'h',
      );
      coordinator.showProgress(
        notificationId: 1,
        title: 't',
        progressPercent: 100,
        speed: '',
        eta: '',
        payload: 'h',
      );
      verify(() => service.showDownloadProgress(
            notificationId: 1,
            title: any(named: 'title'),
            progressPercent: any(named: 'progressPercent'),
            speed: any(named: 'speed'),
            eta: any(named: 'eta'),
            languageCode: any(named: 'languageCode'),
            payload: any(named: 'payload'),
            isPaused: any(named: 'isPaused'),
            hasMultipleActive: any(named: 'hasMultipleActive'),
            groupKey: any(named: 'groupKey'),
          )).called(2);
    });

    test('second rapid progress call is throttled', () {
      coordinator.showProgress(
        notificationId: 9,
        title: 't',
        progressPercent: 10,
        speed: '',
        eta: '',
        payload: 'h',
      );
      coordinator.showProgress(
        notificationId: 9,
        title: 't',
        progressPercent: 20,
        speed: '',
        eta: '',
        payload: 'h',
      );
      verify(() => service.showDownloadProgress(
            notificationId: 9,
            title: any(named: 'title'),
            progressPercent: any(named: 'progressPercent'),
            speed: any(named: 'speed'),
            eta: any(named: 'eta'),
            languageCode: any(named: 'languageCode'),
            payload: any(named: 'payload'),
            isPaused: any(named: 'isPaused'),
            hasMultipleActive: any(named: 'hasMultipleActive'),
            groupKey: any(named: 'groupKey'),
          )).called(1);
    });
  });

  group('showFailed', () {
    test('disabled is a no-op', () {
      settings.notificationsEnabled = false;
      coordinator.showFailed(notificationId: 1, title: 't', error: 'e');
      verifyNever(() => service.showDownloadFailed(
            notificationId: any(named: 'notificationId'),
            title: any(named: 'title'),
            error: any(named: 'error'),
            playSound: any(named: 'playSound'),
          ));
    });

    test('enabled posts failure', () {
      coordinator.showFailed(notificationId: 1, title: 't', error: 'e');
      verify(() => service.showDownloadFailed(
            notificationId: 1,
            title: 't',
            error: 'e',
            playSound: any(named: 'playSound'),
          )).called(1);
    });
  });

  group('updateBackgroundNotification', () {
    test('disabled cancels service notification', () {
      settings.notificationsEnabled = false;
      coordinator.updateBackgroundNotification();
      verify(() => service.cancelNotification(888)).called(1);
    });

    test('enabled posts service notification', () async {
      coordinator.updateBackgroundNotification();
      await Future<void>.delayed(Duration.zero);
      verify(() => service.showServiceNotification(
            title: any(named: 'title'),
            content: any(named: 'content'),
          )).called(1);
    });
  });

  group('action handling', () {
    Future<void> emit(Map<String, String> event) async {
      actions.add(event);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    test('pause/resume/cancel route to callbacks', () async {
      coordinator.init();
      foundTasks.add(_task('t1'));
      foundTasks.add(_task('t2'));
      foundTasks.add(_task('t3'));
      await emit({'action': 'pause', 'taskId': 't1'});
      await emit({'action': 'resume', 'taskId': 't2'});
      await emit({'action': 'cancel', 'taskId': 't3'});
      expect(paused, ['t1']);
      expect(resumed, ['t2']);
      expect(cancelled, ['t3']);
    });

    test('group actions route to callbacks', () async {
      coordinator.init();
      actions.add({'action': 'pause_all'});
      actions.add({'action': 'resume_all'});
      actions.add({'action': 'stop_all'});
      actions.add({'action': 'start_all'});
      actions.add({'action': 'exit_app'});
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(pauseAllCount, 1);
      expect(resumeAllCount, 1);
      expect(stopAllCount, 1);
      expect(startAllCount, 1);
      expect(exitCount, 1);
    });

    test('null action is ignored', () async {
      coordinator.init();
      await emit({'taskId': 't1'});
      expect(paused, isEmpty);
    });

    test('missing task for pause is ignored', () async {
      coordinator.init();
      await emit({'action': 'pause', 'taskId': 'nope'});
      expect(paused, isEmpty);
    });

    test('duplicate action within window is suppressed', () async {
      coordinator.init();
      foundTasks.add(_task('dup'));
      await emit({'action': 'pause', 'taskId': 'dup'});
      await emit({'action': 'pause', 'taskId': 'dup'});
      expect(paused, ['dup']);
    });

    test('install_apk action resolves task without error', () async {
      coordinator.init();
      foundTasks
          .add(_task('inst', status: DownloadStatus.completed, fileName: 'x'));
      await emit({'action': 'install_apk', 'taskId': 'inst'});
    });
  });

  group('dispose', () {
    test('clears state and stops polling', () {
      coordinator.dispose();
      verify(() => service.stopPollingPendingActions()).called(1);
    });
  });
}
