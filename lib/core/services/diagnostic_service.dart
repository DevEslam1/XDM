import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'error_taxonomy.dart';
import 'package:dmx/core/services/logging_service.dart';

/// One recorded diagnostic entry.
class DiagnosticEntry {
  final DateTime timestamp;
  final String area;
  final String message;
  final ErrorFamily? family;
  final String? details;

  const DiagnosticEntry({
    required this.timestamp,
    required this.area,
    required this.message,
    this.family,
    this.details,
  });

  String get formatted {
    final time = '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}';
    final family = this.family == null ? '' : '[${this.family!.name}] ';
    final details = this.details == null || this.details!.isEmpty
        ? ''
        : ' — ${this.details}';
    return '$time $area: $family$message$details';
  }
}

/// Bounded in-memory diagnostic log plus a system-info snapshot, used for
/// support/debugging screens without leaking sensitive data.
class DiagnosticService {
  DiagnosticService();

  static final DiagnosticService instance = DiagnosticService();

  static const int _maxEntries = 200;

  final List<DiagnosticEntry> _entries = [];

  List<DiagnosticEntry> get entries => List.unmodifiable(_entries);

  void record(
    String area,
    String message, {
    Object? error,
    String? details,
  }) {
    _entries.add(
      DiagnosticEntry(
        timestamp: DateTime.now(),
        area: area,
        message: message,
        family: error == null ? null : ErrorTaxonomy.classify(error).family,
        details: details,
      ),
    );
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
  }

  void clear() => _entries.clear();

  /// Formatted, timestamped dump of the recorded entries (newest last).
  String snapshot() => _entries.map((e) => e.formatted).join('\n');

  /// Basic non-sensitive system information for support triage.
  Future<Map<String, String>> systemInfo() async {
    final info = <String, String>{};
    try {
      final package = await PackageInfo.fromPlatform();
      info['app'] =
          '${package.appName} ${package.version}+${package.buildNumber}';
    } catch (e) {
      LoggingService.logger('DiagnosticService').info(
        '[DiagnosticService] package info unavailable, skipping app field: $e',
      );
    }

    try {
      if (!kIsWeb) {
        if (Platform.isAndroid) {
          final android = await DeviceInfoPlugin().androidInfo;
          info['device'] =
              '${android.manufacturer} ${android.model} (Android ${android.version.release})';
        } else if (Platform.isIOS) {
          final ios = await DeviceInfoPlugin().iosInfo;
          info['device'] = '${ios.utsname.machine} (iOS ${ios.systemVersion})';
        } else {
          info['device'] = Platform.operatingSystem;
        }
      } else {
        info['device'] = 'web';
      }
    } catch (e) {
      LoggingService.logger('DiagnosticService').info(
        '[DiagnosticService] device info unavailable, skipping device field: $e',
      );
    }

    if (!kIsWeb) {
      info['dart'] = Platform.version.split(' ').first;
      info['osVersion'] = Platform.operatingSystemVersion;
    } else {
      info['dart'] = 'web';
    }
    return info;
  }
}
