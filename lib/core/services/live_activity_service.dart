import 'dart:io';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

class LiveActivityService {
  static final _log = Logger('LiveActivityService');
  static const _channel = MethodChannel('com.dmx.app/live_activity');

  static bool _supported = false;
  static bool _initialized = false;
  static final Map<String, DateTime> _lastUpdateTimes = {};
  static const _minUpdateInterval = Duration(seconds: 15);

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    if (!Platform.isIOS) {
      _supported = false;
      return;
    }

    try {
      final result = await _channel.invokeMethod<Map>('isSupported');
      _supported = result?['areActivitiesEnabled'] == true;
      if (_supported) {
        _log.info('Live Activities supported');
      } else {
        _log.info('Live Activities not enabled by user');
      }
    } on MissingPluginException {
      _supported = false;
    } catch (e) {
      _log.warning('Live Activity init failed', e);
      _supported = false;
    }
  }

  static bool get isSupported => _supported;

  static Future<void> start({
    required String taskId,
    required String fileName,
  }) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('startActivity', {
        'taskId': taskId,
        'fileName': fileName,
      });
      _lastUpdateTimes[taskId] = DateTime.now();
    } catch (e) {
      _log.warning('Failed to start Live Activity for $taskId', e);
    }
  }

  static Future<void> update({
    required String taskId,
    required double progress,
    required int speedBytesPerSec,
    required int etaSeconds,
  }) async {
    if (!_supported) return;

    final lastUpdate = _lastUpdateTimes[taskId];
    if (lastUpdate != null &&
        DateTime.now().difference(lastUpdate) < _minUpdateInterval) {
      return;
    }
    _lastUpdateTimes[taskId] = DateTime.now();

    try {
      await _channel.invokeMethod('updateActivity', {
        'taskId': taskId,
        'progress': progress.clamp(0.0, 1.0),
        'speed': speedBytesPerSec,
        'eta': etaSeconds,
      });
    } catch (e) {
      // Fixed: Added logging for previously swallowed errors
      _log.fine('Failed to update Live Activity for $taskId: $e');
    }
  }

  static Future<void> end({required String taskId}) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('endActivity', {'taskId': taskId});
      _lastUpdateTimes.remove(taskId);
    } catch (e) {
      _log.warning('Failed to end Live Activity for $taskId', e);
    }
  }

  static Future<void> endAll() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('endAllActivities');
      _lastUpdateTimes.clear();
    } catch (e) {
      _log.warning('Failed to end all Live Activities', e);
    }
  }
}
