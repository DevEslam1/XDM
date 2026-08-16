import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/app_lifecycle_coordinator.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/engine/download_progress_handler.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall methodCall) async {
        return null;
      },
    );
  });

  group('Download Cycle 7 Fixes Unit Tests', () {
    test(
        '1. YouTube Counterpart Race Condition — cycle forced to downloading until counterpart done',
        () async {
      final List<DownloadProgress> emissions = [];
      final cancelToken = CancelToken();

      final handler = DownloadProgressHandler(
        taskId: 'video-task-1',
        cancelToken: cancelToken,
        onProgress: (p) => emissions.add(p),
        isTorrent: false,
        getEffectiveIntervalMs: () => 0, // emit immediately
        lastDownloadedBytes: 1000,
        lastFileSize: 1000,
        resolvedFileName: 'video.mp4',
        resolvedSupportsResume: true,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: null,
        ytCounterpartDownloadedBytes: null,
        getTorrentFiles: null,
        torrentId: null,
      );

      final cpIds = TimestampedLruMap<String, String>()
        ..['video-task-1'] = 'audio-task-1';

      // Scenario A: Counterpart size is null (unresolved)
      final liveBytesA = TimestampedLruMap<String, int>()
        ..['video-task-1'] = 1000
        ..['audio-task-1'] = 0;

      await handler.handleProgress(
        {
          'downloadedBytes': 1000,
          'fileSize': 1000,
          'statusMessage': 'Completed',
          'ytStreamKind': 'video',
          'ytCounterpartSize': null,
          'ytCounterpartDownloadedBytes': null,
        },
        ytCounterpartTaskIds: cpIds,
        ytLiveBytes: liveBytesA,
      );

      expect(emissions.last.cycleState, equals(CycleState.downloading));

      // Scenario B: Counterpart size is known (500), but counterpart downloaded is 250 (< 500)
      final liveBytesB = TimestampedLruMap<String, int>()
        ..['video-task-1'] = 1000
        ..['audio-task-1'] = 250;

      await handler.handleProgress(
        {
          'downloadedBytes': 1000,
          'fileSize': 1000,
          'statusMessage': 'Completed',
          'ytStreamKind': 'video',
          'ytCounterpartSize': 500,
          'ytCounterpartDownloadedBytes': 250,
        },
        ytCounterpartTaskIds: cpIds,
        ytLiveBytes: liveBytesB,
      );

      expect(emissions.last.cycleState, equals(CycleState.downloading));

      // Scenario C: Both streams 100% complete
      final liveBytesC = TimestampedLruMap<String, int>()
        ..['video-task-1'] = 1000
        ..['audio-task-1'] = 500;

      await handler.handleProgress(
        {
          'downloadedBytes': 1000,
          'fileSize': 1000,
          'statusMessage': 'Completed',
          'ytStreamKind': 'video',
          'ytCounterpartSize': 500,
          'ytCounterpartDownloadedBytes': 500,
        },
        ytCounterpartTaskIds: cpIds,
        ytLiveBytes: liveBytesC,
      );

      expect(emissions.last.cycleState, equals(CycleState.completed));
    });

    test('2. Configurable Torrent Metadata Timeout in SettingsProvider',
        () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await settings.load();

      expect(settings.torrentMetadataTimeoutSeconds, equals(300));

      await settings.setTorrentMetadataTimeoutSeconds(600);
      expect(settings.torrentMetadataTimeoutSeconds, equals(600));

      // Clamping: min 30, max 1800
      await settings.setTorrentMetadataTimeoutSeconds(10);
      expect(settings.torrentMetadataTimeoutSeconds, equals(30));

      await settings.setTorrentMetadataTimeoutSeconds(5000);
      expect(settings.torrentMetadataTimeoutSeconds, equals(1800));
    });

    test('3. AppLifecycleCoordinator triggers onResumed callbacks', () {
      AppLifecycleCoordinator.dispose();
      bool callbackFired = false;

      void callback() {
        callbackFired = true;
      }

      AppLifecycleCoordinator.addOnResumedCallback(callback);
      AppLifecycleCoordinator.instance
          .didChangeAppLifecycleState(AppLifecycleState.resumed);

      expect(callbackFired, isTrue);

      // Test removal
      callbackFired = false;
      AppLifecycleCoordinator.removeOnResumedCallback(callback);
      AppLifecycleCoordinator.instance
          .didChangeAppLifecycleState(AppLifecycleState.resumed);

      expect(callbackFired, isFalse);
    });

    test('4. Estimated Torrent Progress Text formatting with ≈', () {
      String formatProgress(bool isEstimated, double progress) => isEstimated
          ? '≈${(progress * 100).toStringAsFixed(0)}%'
          : '${(progress * 100).toStringAsFixed(1)}%';

      expect(formatProgress(true, 0.456), equals('≈46%'));
      expect(formatProgress(false, 0.456), equals('45.6%'));
    });
  });
}
