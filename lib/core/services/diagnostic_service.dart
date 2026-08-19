import 'dart:collection';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../domain/repositories/diagnostic_repository.dart';
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
class DiagnosticService implements DiagnosticRepository {
  DiagnosticService();

  static final DiagnosticService instance = DiagnosticService();

  static const int _maxEntries = 200;

  final List<DiagnosticEntry> _entries = [];

  @override
  List<DiagnosticEntry> get entries => List.unmodifiable(_entries);

  @override
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

  @override
  void clear() => _entries.clear();

  /// Formatted, timestamped dump of the recorded entries (newest last).
  @override
  String snapshot() => _entries.map((e) => e.formatted).join('\n');

  /// Basic non-sensitive system information for support triage.
  @override
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
  // Telemetry Metrics (Optimized: Queue O(1) + Overflow Safe + Cached Snapshot)
  // ═══════════════════════════════════════════════════════════════════════════

  static const int _maxSafeInt = 0x7FFFFFFFFFFFFFFF;
  int _isolateBytesTransferred = 0;
  int _isolateMessageCount = 0;
  final DoubleLinkedQueue<double> _progressLatenciesMs =
      DoubleLinkedQueue<double>();
  static const int _maxLatencySamples = 1000;
  int _currentDbWriteQueueDepth = 0;
  int _maxDbWriteQueueDepth = 0;
  int _mirrorHealthHits = 0;
  int _mirrorHealthMisses = 0;

  Map<String, dynamic>? _cachedSnapshot;
  bool _snapshotDirty = true;

  @override
  int get isolateBytesTransferred => _isolateBytesTransferred;
  @override
  int get isolateMessageCount => _isolateMessageCount;
  @override
  int get currentDbWriteQueueDepth => _currentDbWriteQueueDepth;
  @override
  int get maxDbWriteQueueDepth => _maxDbWriteQueueDepth;
  @override
  int get mirrorHealthHits => _mirrorHealthHits;
  @override
  int get mirrorHealthMisses => _mirrorHealthMisses;

  @override
  double get mirrorHealthCacheHitRate {
    final total = _mirrorHealthHits + _mirrorHealthMisses;
    if (total == 0) return 0.0;
    return _mirrorHealthHits / total;
  }

  @override
  void recordIsolatePayloadSize(int bytes) {
    if (bytes <= 0) return;
    if (_maxSafeInt - bytes >= _isolateBytesTransferred) {
      _isolateBytesTransferred += bytes;
    } else {
      _isolateBytesTransferred = _maxSafeInt;
    }
    if (_isolateMessageCount < _maxSafeInt) {
      _isolateMessageCount++;
    }
    _snapshotDirty = true;
  }

  @override
  void recordProgressLatency(Duration latency) {
    _progressLatenciesMs.add(latency.inMicroseconds / 1000.0);
    if (_progressLatenciesMs.length > _maxLatencySamples) {
      _progressLatenciesMs.removeFirst(); // O(1) queue removal
    }
    _snapshotDirty = true;
  }

  @override
  double get p95ProgressLatencyMs {
    if (_progressLatenciesMs.isEmpty) return 0.0;
    final sorted = _progressLatenciesMs.toList()..sort();
    final index = (sorted.length * 0.95).floor();
    final clamped = index.clamp(0, sorted.length - 1);
    return sorted[clamped];
  }

  @override
  void recordDbWriteQueueDepth(int depth) {
    _currentDbWriteQueueDepth = depth;
    if (depth > _maxDbWriteQueueDepth) {
      _maxDbWriteQueueDepth = depth;
    }
    _snapshotDirty = true;
  }

  @override
  void recordMirrorHealthAccess({required bool isHit}) {
    if (isHit) {
      _mirrorHealthHits++;
    } else {
      _mirrorHealthMisses++;
    }
    _snapshotDirty = true;
  }

  @override
  void resetTelemetryMetrics() {
    _isolateBytesTransferred = 0;
    _isolateMessageCount = 0;
    _progressLatenciesMs.clear();
    _currentDbWriteQueueDepth = 0;
    _maxDbWriteQueueDepth = 0;
    _mirrorHealthHits = 0;
    _mirrorHealthMisses = 0;
    _snapshotDirty = true;
  }

  @override
  Map<String, dynamic> telemetryMetricsSnapshot() {
    if (!_snapshotDirty && _cachedSnapshot != null) {
      return _cachedSnapshot!;
    }
    _cachedSnapshot = {
      'isolateMessageBytes': _isolateBytesTransferred,
      'isolateMessageCount': _isolateMessageCount,
      'p95ProgressLatencyMs': p95ProgressLatencyMs,
      'currentDbWriteQueueDepth': _currentDbWriteQueueDepth,
      'maxDbWriteQueueDepth': _maxDbWriteQueueDepth,
      'mirrorHealthHits': _mirrorHealthHits,
      'mirrorHealthMisses': _mirrorHealthMisses,
      'mirrorHealthCacheHitRate': mirrorHealthCacheHitRate,
    };
    _snapshotDirty = false;
    return _cachedSnapshot!;
  }
}
