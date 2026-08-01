import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
  static const MethodChannel _channel = MethodChannel('com.dmx.app/background_download');
  static const EventChannel _eventChannel = EventChannel('com.dmx.app/background_download_events');

  /// Stream of native iOS background transfer progress and completion events.
  static Stream<IosBackgroundTransferEvent> get backgroundEvents {
    if (!Platform.isIOS) return const Stream.empty();
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
    if (!Platform.isIOS) return false;
    try {
      final bool success = await _channel.invokeMethod<bool>('startNativeDownload', {
        'taskId': taskId,
        'url': url,
        'destinationPath': destinationPath,
      }) ?? false;
      return success;
    } catch (e) {
      debugPrint('Failed to start native iOS background download: $e');
      return false;
    }
  }

  /// Pauses a native iOS background download.
  static Future<bool> pauseNativeDownload(String taskId) async {
    if (!Platform.isIOS) return false;
    try {
      final bool success = await _channel.invokeMethod<bool>('pauseNativeDownload', {
        'taskId': taskId,
      }) ?? false;
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
    if (!Platform.isIOS) return false;
    try {
      final bool success = await _channel.invokeMethod<bool>('resumeNativeDownload', {
        'taskId': taskId,
        'url': url,
        'destinationPath': destinationPath,
      }) ?? false;
      return success;
    } catch (e) {
      debugPrint('Failed to resume native iOS background download: $e');
      return false;
    }
  }

  /// Cancels a native iOS background download.
  static Future<bool> cancelNativeDownload(String taskId) async {
    if (!Platform.isIOS) return false;
    try {
      final bool success = await _channel.invokeMethod<bool>('cancelNativeDownload', {
        'taskId': taskId,
      }) ?? false;
      return success;
    } catch (e) {
      debugPrint('Failed to cancel native iOS background download: $e');
      return false;
    }
  }

  /// Schedules a native iOS background refresh task via BGTaskScheduler.
  static Future<bool> scheduleBackgroundDownload() async {
    if (!Platform.isIOS) return false;
    try {
      final bool success = await _channel.invokeMethod<bool>('scheduleDownload') ?? false;
      return success;
    } catch (e) {
      debugPrint('Failed to schedule iOS background download: $e');
      return false;
    }
  }

  /// Cancels any scheduled native iOS background download task.
  static Future<bool> cancelBackgroundDownload() async {
    if (!Platform.isIOS) return false;
    try {
      final bool success = await _channel.invokeMethod<bool>('cancelDownload') ?? false;
      return success;
    } catch (e) {
      debugPrint('Failed to cancel iOS background download: $e');
      return false;
    }
  }
}
