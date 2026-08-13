import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/url_utils.dart';
import 'package:dmx/core/services/logging_service.dart';

class ClipboardService {
  static final ClipboardService _instance = ClipboardService._internal();
  factory ClipboardService() => _instance;
  ClipboardService._internal();

  static const _secureStorage = FlutterSecureStorage();
  String? _lastCheckedUrl;
  DateTime? _lastCheckedTime;
  bool _initialized = false;
  Future<void>? _initFuture;

  int _initAttempts = 0;

  Future<void> _initIfNeeded() async {
    if (_initialized) return;

    if (_initFuture != null) {
      try {
        await _initFuture!.timeout(const Duration(seconds: 2));
        return;
      } catch (e) {
        LoggingService.logger('ClipboardService').info(
          '[ClipboardService] previous init future failed or timed out: $e',
        );
        _initFuture = null;
      }
    }

    if (_initAttempts >= 3) {
      LoggingService.logger('ClipboardService').warning(
        '[ClipboardService] Max initialization retries (3) reached. Halting init retries.',
      );
      _initialized = true;
      return;
    }

    _initAttempts++;
    _initFuture = _doInit();
    try {
      await _initFuture!.timeout(const Duration(seconds: 2));
    } catch (e) {
      _initFuture = null;
      LoggingService.logger('ClipboardService').warning(
        '[ClipboardService] initialization attempt $_initAttempts failed or timed out: $e',
      );
    }
  }

  Future<void> _doInit() async {
    if (_initialized) return;
    try {
      _lastCheckedUrl = await _secureStorage.read(key: 'clipboard_last_url');
      final timeMsStr = await _secureStorage.read(key: 'clipboard_last_time');
      final timeMs = int.tryParse(timeMsStr ?? '');
      if (timeMs != null) {
        _lastCheckedTime = DateTime.fromMillisecondsSinceEpoch(timeMs);
      }
    } catch (e) {
      debugPrint('ClipboardService error reading secure storage: $e');
    }
    _initialized = true;
  }

  Future<String?> checkClipboardForUrl() async {
    try {
      await _initIfNeeded();
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool('clipboard_monitoring_enabled') ?? false;
      if (!enabled) return null;

      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();

      if (text != null &&
          (isHttpUrl(text) || isMagnetUrl(text) || isTorrentFileUrl(text))) {
        final lower = text.toLowerCase();
        if (lower.startsWith('javascript:') ||
            lower.startsWith('data:') ||
            lower.startsWith('vbscript:')) {
          return null;
        }

        final now = DateTime.now();
        if (text == _lastCheckedUrl && _lastCheckedTime != null) {
          final elapsed = now.difference(_lastCheckedTime!);
          if (elapsed < const Duration(seconds: 30)) {
            return null;
          }
          _lastCheckedTime = now;
          try {
            await _secureStorage.write(
              key: 'clipboard_last_time',
              value: '${now.millisecondsSinceEpoch}',
            );
          } catch (e) {
            LoggingService.logger('ClipboardService').info(
              '[ClipboardService] rate-limit timestamp persist skipped: $e',
            );
          }
          return text;
        }

        _lastCheckedUrl = text;
        _lastCheckedTime = now;
        try {
          await _secureStorage.write(key: 'clipboard_last_url', value: text);
          await _secureStorage.write(
            key: 'clipboard_last_time',
            value: '${now.millisecondsSinceEpoch}',
          );
        } catch (e) {
          LoggingService.logger('ClipboardService').info(
            '[ClipboardService] last-checked URL persist skipped: $e',
          );
        }
        return text;
      }
    } catch (e) {
      debugPrint('ClipboardService error checking URL: $e');
    }
    return null;
  }

  Future<void> markAsChecked(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty ||
        (!isHttpUrl(trimmed) &&
            !isMagnetUrl(trimmed) &&
            !isTorrentFileUrl(trimmed))) {
      return;
    }

    _lastCheckedUrl = trimmed;
    _lastCheckedTime = DateTime.now();

    try {
      await _secureStorage.write(key: 'clipboard_last_url', value: trimmed);
      await _secureStorage.write(
        key: 'clipboard_last_time',
        value: '${_lastCheckedTime!.millisecondsSinceEpoch}',
      );
    } catch (e) {
      debugPrint('ClipboardService error saving last URL: $e');
    }
  }
}
