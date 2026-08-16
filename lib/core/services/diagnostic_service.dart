import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'error_taxonomy.dart';

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

  // ═══════════════════════════════════════════════════════════════════════════
  // Telemetry Metrics (FIX-23)
  // ═══════════════════════════════════════════════════════════════════════════

  int _isolateBytesTransferred = 0;
  int _isolateMessageCount = 0;
  final List<double> _progressLatenciesMs = [];
  static const int _maxLatencySamples = 1000;
  int _currentDbWriteQueueDepth = 0;
  int _maxDbWriteQueueDepth = 0;
  int _mirrorHealthHits = 0;
  int _mirrorHealthMisses = 0;

  int get isolateBytesTransferred => _isolateBytesTransferred;
  int get isolateMessageCount => _isolateMessageCount;
  int get currentDbWriteQueueDepth => _currentDbWriteQueueDepth;
  int get maxDbWriteQueueDepth => _maxDbWriteQueueDepth;
  int get mirrorHealthHits => _mirrorHealthHits;
  int get mirrorHealthMisses => _mirrorHealthMisses;

  double get mirrorHealthCacheHitRate {
    final total = _mirrorHealthHits + _mirrorHealthMisses;
    if (total == 0) return 0.0;
    return _mirrorHealthHits / total;
  }

  void recordIsolatePayloadSize(int bytes) {
    _isolateBytesTransferred += bytes;
    _isolateMessageCount++;
  }

  void recordProgressLatency(Duration latency) {
    _progressLatenciesMs.add(latency.inMicroseconds / 1000.0);
    if (_progressLatenciesMs.length > _maxLatencySamples) {
      _progressLatenciesMs.removeAt(0);
    }
  }

  double get p95ProgressLatencyMs {
    if (_progressLatenciesMs.isEmpty) return 0.0;
    final sorted = List<double>.from(_progressLatenciesMs)..sort();
    final index = (sorted.length * 0.95).floor();
    final clamped = index.clamp(0, sorted.length - 1);
    return sorted[clamped];
  }

  void recordDbWriteQueueDepth(int depth) {
    _currentDbWriteQueueDepth = depth;
    if (depth > _maxDbWriteQueueDepth) {
      _maxDbWriteQueueDepth = depth;
    }
  }

  void recordMirrorHealthAccess({required bool isHit}) {
    if (isHit) {
      _mirrorHealthHits++;
    } else {
      _mirrorHealthMisses++;
    }
  }

  void resetTelemetryMetrics() {
    _isolateBytesTransferred = 0;
    _isolateMessageCount = 0;
    _progressLatenciesMs.clear();
    _currentDbWriteQueueDepth = 0;
    _maxDbWriteQueueDepth = 0;
    _mirrorHealthHits = 0;
    _mirrorHealthMisses = 0;
  }

  Map<String, dynamic> telemetryMetricsSnapshot() {
    return {
      'isolateMessageBytes': _isolateBytesTransferred,
      'isolateMessageCount': _isolateMessageCount,
      'p95ProgressLatencyMs': p95ProgressLatencyMs,
      'currentDbWriteQueueDepth': _currentDbWriteQueueDepth,
      'maxDbWriteQueueDepth': _maxDbWriteQueueDepth,
      'mirrorHealthHits': _mirrorHealthHits,
      'mirrorHealthMisses': _mirrorHealthMisses,
      'mirrorHealthCacheHitRate': mirrorHealthCacheHitRate,
    };
  }
}
