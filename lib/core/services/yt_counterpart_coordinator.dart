import 'dart:async';
import 'package:dmx/core/services/engine/engine_utils.dart';

/// Coordinates YouTube audio/video stream pairs for synchronization.
/// Task 1.2: Specialized Service for YT sync logic.
class YtCounterpartCoordinator {
  final _ytCounterpartTaskIds = TimestampedLruMap<String, String>(maxCapacity: 50);
  final _ytLiveBytes = TimestampedLruMap<String, int>(maxCapacity: 50);
  final _ytFinishedStreams = TimestampedLruMap<String, bool>(maxCapacity: 50);
  final Set<Timer> _cleanupTimers = {};
  Timer? _periodicTimer;

  YtCounterpartCoordinator({bool enablePeriodicTimer = true}) {
    if (enablePeriodicTimer) {
      _startPeriodicTimer();
    }
  }

  void _startPeriodicTimer() {
    _periodicTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _ytCounterpartTaskIds.removeStale(const Duration(minutes: 10));
      _ytLiveBytes.removeStale(const Duration(minutes: 10));
      _ytFinishedStreams.removeStale(const Duration(minutes: 10));
    });
  }

  void registerCounterpart(String taskId, String counterpartTaskId) {
    _ytCounterpartTaskIds.put(taskId, counterpartTaskId);
    _ytCounterpartTaskIds.put(counterpartTaskId, taskId);
  }

  String? getCounterpartId(String taskId) => _ytCounterpartTaskIds.get(taskId);

  void updateLiveBytes(String taskId, int bytes) {
    _ytLiveBytes.put(taskId, bytes);
  }

  int? getLiveBytes(String taskId) => _ytLiveBytes.get(taskId);

  void unregister(String taskId) {
    _ytFinishedStreams.put(taskId, true);
    final counterpartId = _ytCounterpartTaskIds.get(taskId);

    if (counterpartId != null && _ytFinishedStreams.containsKey(counterpartId)) {
      _ytCounterpartTaskIds.remove(taskId);
      _ytCounterpartTaskIds.remove(counterpartId);
      _ytLiveBytes.remove(taskId);
      _ytLiveBytes.remove(counterpartId);
      _ytFinishedStreams.remove(taskId);
      _ytFinishedStreams.remove(counterpartId);
    } else if (counterpartId == null) {
      _ytLiveBytes.remove(taskId);
      _ytFinishedStreams.remove(taskId);
    } else {
      // Wait for the other leg to finish or timeout
      Timer? timer;
      timer = Timer(const Duration(minutes: 10), () {
        _cleanupTimers.remove(timer);
        if (_ytFinishedStreams.containsKey(taskId) &&
            _ytCounterpartTaskIds.containsKey(taskId)) {
          final cId = _ytCounterpartTaskIds.get(taskId);
          _ytCounterpartTaskIds.remove(taskId);
          if (cId != null) _ytCounterpartTaskIds.remove(cId);
          _ytLiveBytes.remove(taskId);
          if (cId != null) _ytLiveBytes.remove(cId);
          _ytFinishedStreams.remove(taskId);
          if (cId != null) _ytFinishedStreams.remove(cId);
        }
      });
      _cleanupTimers.add(timer);
    }
  }

  void dispose() {
    _periodicTimer?.cancel();
    for (final timer in _cleanupTimers) {
      timer.cancel();
    }
    _cleanupTimers.clear();
  }
}
