import 'dart:io';

import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

/// Pushes download metrics to iOS Widget via App Group shared container.
class WidgetDataService {
  static final _log = Logger('WidgetDataService');
  static const _channel = MethodChannel('com.dmx.app/widget_data');

  static DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  static const _minPushInterval = Duration(seconds: 5);

  /// Push current download stats to widget (throttled).
  static Future<void> pushStats({
    required int activeCount,
    required int speedBytesPerSec,
    required int completedCount,
  }) async {
    if (!Platform.isIOS) return;

    final now = DateTime.now();
    if (now.difference(_lastPush) < _minPushInterval) return;
    _lastPush = now;

    try {
      await _channel.invokeMethod('updateWidgetData', {
        'activeCount': activeCount,
        'speedBytesPerSec': speedBytesPerSec,
        'completedCount': completedCount,
      });
    } catch (e, st) {
      LoggingService.logger('WidgetDataService').warning('Operation failed', e, st);
    }
  }

  /// Force widget timeline reload (e.g., on download complete).
  static Future<void> forceReload() async {
    if (!Platform.isIOS) return;

    try {
      await _channel.invokeMethod('reloadWidget');
    } catch (e) {
      _log.fine('Widget reload failed (non-critical)', e);
    }
  }
}
