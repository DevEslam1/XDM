import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/semantics.dart';

/// Screen-reader announcement helper.
///
/// Wraps `SemanticsService.sendAnnouncement` with throttling so rapid-fire
/// status updates (e.g. download progress) collapse into one announcement
/// instead of spamming the screen reader. Announcements are a no-op when no
/// screen reader is active, so calls are safe everywhere.
class XdmAnnouncer {
  XdmAnnouncer._();

  static final XdmAnnouncer _instance = XdmAnnouncer._();
  static XdmAnnouncer get instance => _instance;

  static const Duration _throttleWindow = Duration(milliseconds: 800);

  Timer? _timer;
  String _pending = '';
  TextDirection _direction = TextDirection.ltr;
  DateTime _lastAnnounced = DateTime.fromMillisecondsSinceEpoch(0);

  /// Announces [message] to the active screen reader, coalescing messages
  /// that arrive within the throttle window.
  static void announce(
    String message, {
    TextDirection direction = TextDirection.ltr,
  }) {
    if (message.isEmpty) return;
    _instance._enqueue(message, direction);
  }

  /// Immediately announces [message], bypassing the throttle window.
  static void announceNow(
    String message, {
    TextDirection direction = TextDirection.ltr,
  }) {
    if (message.isEmpty) return;
    _instance._timer?.cancel();
    _instance._pending = '';
    _deliver(message, direction);
  }

  /// Cancels any queued announcement (e.g. on screen teardown). Also resets
  /// the throttle clock so the next announcement is delivered immediately.
  static void flush() {
    _instance._timer?.cancel();
    _instance._timer = null;
    _instance._pending = '';
    _instance._lastAnnounced = DateTime.fromMillisecondsSinceEpoch(0);
  }

  void _enqueue(String message, TextDirection direction) {
    _pending = message;
    _direction = direction;

    final elapsed = DateTime.now().difference(_lastAnnounced);
    if (elapsed >= _throttleWindow) {
      _deliverPending();
      return;
    }

    _timer?.cancel();
    _timer = Timer(_throttleWindow, _deliverPending);
  }

  void _deliverPending() {
    _timer = null;
    if (_pending.isEmpty) return;
    final message = _pending;
    _pending = '';
    _deliver(message, _direction);
  }

  static void _deliver(String message, TextDirection direction) {
    final view = PlatformDispatcher.instance.implicitView;
    if (view == null) return;
    _instance._lastAnnounced = DateTime.now();
    SemanticsService.sendAnnouncement(view, message, direction);
  }
}
