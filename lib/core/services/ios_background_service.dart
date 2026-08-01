import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Service for managing iOS native background download tasks via [MethodChannel].
class IosBackgroundService {
  static const MethodChannel _channel = MethodChannel('com.dmx.app/background_download');

  /// Schedules a native iOS background download task.
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
