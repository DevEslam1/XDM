import 'dart:async';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';

/// Debounces and batches high-frequency SharedPreferences mutations into periodic writes.
class SharedPrefsBatcher {
  SharedPrefsBatcher._();
  static final SharedPrefsBatcher instance = SharedPrefsBatcher._();

  static final _log = Logger('SharedPrefsBatcher');
  final Lock _lock = Lock();
  final Map<String, dynamic> _pendingWrites = {};
  final Set<String> _pendingRemovals = {};
  Timer? _flushTimer;
  static const Duration _flushInterval = Duration(seconds: 30);

  void setString(String key, String value) => _stage(key, value);
  void setInt(String key, int value) => _stage(key, value);
  void setBool(String key, bool value) => _stage(key, value);
  void setDouble(String key, double value) => _stage(key, value);
  void setStringList(String key, List<String> value) =>
      _stage(key, List<String>.from(value));

  void remove(String key) {
    _lock.synchronized(() {
      _pendingWrites.remove(key);
      _pendingRemovals.add(key);
      _scheduleFlush();
    });
  }

  void _stage(String key, dynamic value) {
    _lock.synchronized(() {
      _pendingRemovals.remove(key);
      _pendingWrites[key] = value;
      _scheduleFlush();
    });
  }

  void _scheduleFlush() {
    _flushTimer ??= Timer(_flushInterval, () {
      flush();
    });
  }

  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;

    Map<String, dynamic> toWrite = {};
    Set<String> toRemove = {};

    await _lock.synchronized(() {
      if (_pendingWrites.isEmpty && _pendingRemovals.isEmpty) return;
      toWrite = Map<String, dynamic>.from(_pendingWrites);
      toRemove = Set<String>.from(_pendingRemovals);
      _pendingWrites.clear();
      _pendingRemovals.clear();
    });

    if (toWrite.isEmpty && toRemove.isEmpty) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in toRemove) {
        await prefs.remove(key);
      }
      for (final entry in toWrite.entries) {
        final key = entry.key;
        final val = entry.value;
        if (val is String) {
          await prefs.setString(key, val);
        } else if (val is int) {
          await prefs.setInt(key, val);
        } else if (val is bool) {
          await prefs.setBool(key, val);
        } else if (val is double) {
          await prefs.setDouble(key, val);
        } else if (val is List<String>) {
          await prefs.setStringList(key, val);
        }
      }
      _log.fine(
          '[SharedPrefsBatcher] Successfully flushed ${toWrite.length} writes and ${toRemove.length} removals');
    } catch (e, st) {
      _log.warning('[SharedPrefsBatcher] Flush failed: $e', e, st);
    }
  }

  void dispose() {
    flush();
  }
}
