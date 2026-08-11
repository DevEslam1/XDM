import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../features/downloads/models/download_task.dart';
import 'logging_service.dart';

final _log = LoggingService.logger('IosBackgroundCapability');

abstract class BackgroundDownloadService {
  Future<bool> isSupported();
  Future<void> start(DownloadTask task);
  Future<void> pause(String taskId);
  Future<void> resume(String taskId);
  Future<void> cancel(String taskId);
  Stream<Map<String, dynamic>> progressStream();
}

/// // P0-5: Implementation of iOS background download capability contract.
class IosBackgroundCapability implements BackgroundDownloadService {
  static const MethodChannel _channel =
      MethodChannel('com.dmx.app/background_download');
  static const EventChannel _eventChannel =
      EventChannel('com.dmx.app/background_download_events');

  static final IosBackgroundCapability instance =
      IosBackgroundCapability._internal();
  IosBackgroundCapability._internal();

  bool? _isSupportedCache;

  @override
  Future<bool> isSupported() async {
    if (kIsWeb || !Platform.isIOS) return false;
    if (_isSupportedCache != null) return _isSupportedCache!;

    try {
      final bool supported =
          await _channel.invokeMethod<bool>('isBackgroundSupported') ?? false;
      _isSupportedCache = supported;
      return supported;
    } on MissingPluginException {
      _log.info(
          'P0-5: Native iOS background download plugin missing; feature disabled');
      _isSupportedCache = false;
      return false;
    } catch (e) {
      _log.warning('P0-5: Error checking iOS background support: $e');
      _isSupportedCache = false;
      return false;
    }
  }

  @override
  Future<void> start(DownloadTask task) async {
    if (!await isSupported()) {
      _log.warning(
          'P0-5: iOS background download not supported on this device/configuration');
      return;
    }
    await _channel.invokeMethod('start', task.toMap());
  }

  @override
  Future<void> pause(String taskId) async {
    if (!await isSupported()) return;
    await _channel.invokeMethod('pause', {'taskId': taskId});
  }

  @override
  Future<void> resume(String taskId) async {
    if (!await isSupported()) return;
    await _channel.invokeMethod('resume', {'taskId': taskId});
  }

  @override
  Future<void> cancel(String taskId) async {
    if (!await isSupported()) return;
    await _channel.invokeMethod('cancel', {'taskId': taskId});
  }

  @override
  Stream<Map<String, dynamic>> progressStream() {
    if (kIsWeb || !Platform.isIOS) return const Stream.empty();
    try {
      return _eventChannel
          .receiveBroadcastStream()
          .map((event) => Map<String, dynamic>.from(event as Map));
    } catch (e) {
      _log.warning(
          'P0-5: Error subscribing to iOS background progress stream: $e');
      return const Stream.empty();
    }
  }
}
