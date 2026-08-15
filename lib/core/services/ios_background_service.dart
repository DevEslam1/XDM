import 'dart:io';

import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Event model for native iOS background transfers.
class IosBackgroundTransferEvent {
  final String event; // 'progress', 'completed', 'failed'
  final String taskId;
  final int downloadedBytes;
  final int totalBytes;
  final String? path;
  final String? error;

  const IosBackgroundTransferEvent({
    required this.event,
    required this.taskId,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.path,
    this.error,
  });

  factory IosBackgroundTransferEvent.fromMap(Map<dynamic, dynamic> map) {
    return IosBackgroundTransferEvent(
      event: map['event'] as String? ?? 'unknown',
      taskId: map['taskId'] as String? ?? '',
      downloadedBytes: (map['downloadedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
      path: map['path'] as String?,
      error: map['error'] as String?,
    );
  }
}

/// Service for managing native iOS out-of-process URLSession background transfers via [MethodChannel] & [EventChannel].
class IosBackgroundService {
  static const MethodChannel _channel =
      MethodChannel('com.dmx.app/background_download');
  static const EventChannel _eventChannel =
      EventChannel('com.dmx.app/background_download_events');

  /// Stream of native iOS background transfer progress and completion events.
  static Stream<IosBackgroundTransferEvent> get backgroundEvents {
    if (kIsWeb || !Platform.isIOS) return const Stream.empty();
    return _eventChannel.receiveBroadcastStream().map((dynamic event) {
      if (event is Map) {
        return IosBackgroundTransferEvent.fromMap(event);
      }
      return const IosBackgroundTransferEvent(event: 'unknown', taskId: '');
    });
  }

  /// Starts a native iOS URLSession background download.
  static Future<bool> startNativeDownload({
    required String taskId,
    required String url,
    required String destinationPath,
  }) async {
    if (kIsWeb || !Platform.isIOS) return false;
    try {
      final bool success =
          await _channel.invokeMethod<bool>('startNativeDownload', {
                'taskId': taskId,
                'url': url,
                'destinationPath': destinationPath,
              }) ??
              false;
      return success;
    } catch (e) {
      debugPrint('Failed to start native iOS background download: $e');
      return false;
    }
  }

  /// Pauses a native iOS background download.
  static Future<bool> pauseNativeDownload(String taskId) async {
    if (kIsWeb || !Platform.isIOS) return false;
    try {
      final bool success =
          await _channel.invokeMethod<bool>('pauseNativeDownload', {
                'taskId': taskId,
              }) ??
              false;
      return success;
    } catch (e) {
      debugPrint('Failed to pause native iOS background download: $e');
      return false;
    }
  }

  /// Resumes a paused native iOS background download.
  static Future<bool> resumeNativeDownload({
    required String taskId,
    required String url,
    required String destinationPath,
  }) async {
    if (kIsWeb || !Platform.isIOS) return false;
    try {
      final bool success =
          await _channel.invokeMethod<bool>('resumeNativeDownload', {
                'taskId': taskId,
                'url': url,
                'destinationPath': destinationPath,
              }) ??
              false;
      return success;
    } catch (e) {
      debugPrint('Failed to resume native iOS background download: $e');
      return false;
    }
  }

  /// Cancels a native iOS background download.
  static Future<bool> cancelNativeDownload(String taskId) async {
    if (kIsWeb || !Platform.isIOS) return false;
    try {
      final bool success =
          await _channel.invokeMethod<bool>('cancelNativeDownload', {
                'taskId': taskId,
              }) ??
              false;
      return success;
    } catch (e) {
      debugPrint('Failed to cancel native iOS background download: $e');
      return false;
    }
  }

  static bool _isRegistered = false;
  static const String _prefKeyIsRegistered = 'ios_bg_task_registered';

  static Future<bool> _loadIsRegistered() async {
    if (_isRegistered) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _isRegistered = prefs.getBool(_prefKeyIsRegistered) ?? false;
    } catch (e, st) {
      LoggingService.logger('IosBackgroundService').warning('Operation failed', e, st);
    }
    return _isRegistered;
  }

  /// Schedules a native iOS background refresh task via BGTaskScheduler.
  static Future<bool> scheduleBackgroundDownload() async {
    if (kIsWeb || !Platform.isIOS) return false;
    if (await _loadIsRegistered()) {
      debugPrint(
          '[IosBackgroundService] BGTaskScheduler already registered. Skipping duplicate registration.');
      return true;
    }
    try {
      final bool success =
          await _channel.invokeMethod<bool>('scheduleDownload') ?? false;
      if (success) {
        _isRegistered = true;
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(_prefKeyIsRegistered, true);
        } catch (e, st) {
      LoggingService.logger('IosBackgroundService').warning('Operation failed', e, st);
    }
      }
      return success;
    } catch (e) {
      debugPrint('Failed to schedule iOS background download: $e');
      return false;
    }
  }

  /// Cancels any scheduled native iOS background download task.
  static Future<bool> cancelBackgroundDownload() async {
    if (kIsWeb || !Platform.isIOS) return false;
    try {
      final bool success =
          await _channel.invokeMethod<bool>('cancelDownload') ?? false;
      _isRegistered = false;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_prefKeyIsRegistered, false);
      } catch (e, st) {
      LoggingService.logger('IosBackgroundService').warning('Operation failed', e, st);
    }
      return success;
    } catch (e) {
      debugPrint('Failed to cancel iOS background download: $e');
      return false;
    }
  }
}
