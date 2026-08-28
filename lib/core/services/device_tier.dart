import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'logging_service.dart';

/// Coarse device capability tier, computed once at startup from total RAM and
/// CPU core count. Drives image-cache sizing, isolate caps, and default visual
/// fidelity so a 2 GB phone and a 16 GB desktop are provisioned differently
/// (Plan 07 §7.2, findings R2/R6).
enum DeviceTier { low, balanced, high }

/// Immutable snapshot of the device's detected capabilities plus the derived
/// resource budgets that scale continuously with RAM.
class DeviceCapabilities {
  final DeviceTier tier;
  final double totalRamGb;
  final int cores;

  const DeviceCapabilities({
    required this.tier,
    required this.totalRamGb,
    required this.cores,
  });

  bool get isLowEnd => tier == DeviceTier.low;
  bool get isHighEnd => tier == DeviceTier.high;

  /// Image cache byte budget: ~8 MB per GB of RAM, clamped to a sane 30–256 MB.
  /// Replaces the old crude 30/50 MB binary.
  int get recommendedImageCacheMb =>
      (totalRamGb * 8).clamp(30.0, 256.0).round();

  /// Max decoded-image entry count, scaled with RAM (60–400).
  int get recommendedImageCacheEntries =>
      (totalRamGb * 22).clamp(60.0, 400.0).round();

  /// Suggested ceiling for the download isolate pool by tier. The pool still
  /// applies its own power/thermal scaling on top of this.
  int get recommendedIsolateCap {
    switch (tier) {
      case DeviceTier.low:
        return 2;
      case DeviceTier.balanced:
        return 4;
      case DeviceTier.high:
        return 6;
    }
  }

  @override
  String toString() =>
      'DeviceCapabilities(tier: ${tier.name}, ram: ${totalRamGb.toStringAsFixed(1)}GB, cores: $cores)';
}

/// Detects and caches [DeviceCapabilities] once. Total-RAM detection tries a
/// native MethodChannel first (so a future platform bridge just works), then
/// falls back to `device_info_plus` / a core-count heuristic — never blocking
/// or crashing startup on failure.
class DeviceTierService {
  DeviceTierService._();

  static final _log = LoggingService.logger('DeviceTier');

  /// Optional native bridge: implement `getTotalMemoryBytes` on this channel to
  /// return `ActivityManager.MemoryInfo.totalMem` / `ProcessInfo.physicalMemory`.
  /// Absent today — calls throw MissingPluginException and we fall back.
  static const MethodChannel _channel = MethodChannel('com.dmx.app/device');

  static DeviceCapabilities? _cached;

  /// Balanced default used before [detect] completes or if it fails entirely.
  static const DeviceCapabilities _fallback = DeviceCapabilities(
    tier: DeviceTier.balanced,
    totalRamGb: 4.0,
    cores: 4,
  );

  /// The last detected capabilities, or a balanced default if [detect] has not
  /// run yet. Safe to read synchronously from anywhere.
  static DeviceCapabilities get current => _cached ?? _fallback;

  /// Detects capabilities once and caches the result. Idempotent.
  static Future<DeviceCapabilities> detect() async {
    if (_cached != null) return _cached!;
    final cores = _cpuCores();
    final ramGb = await _totalRamGb(cores);
    final tier = _classify(ramGb, cores);
    _cached = DeviceCapabilities(tier: tier, totalRamGb: ramGb, cores: cores);
    _log.info('Detected $_cached');
    return _cached!;
  }

  static int _cpuCores() {
    try {
      final n = Platform.numberOfProcessors;
      return n > 0 ? n : 4;
    } catch (_) {
      return 4;
    }
  }

  static Future<double> _totalRamGb(int cores) async {
    // 1) Prefer a real native total-RAM reading if a bridge is present.
    try {
      final bytes = await _channel.invokeMethod<int>('getTotalMemoryBytes');
      if (bytes != null && bytes > 0) {
        return bytes / (1024 * 1024 * 1024);
      }
    } catch (_) {
      // No native implementation yet — fall through to heuristics.
    }

    // 2) Platform-specific hints without native code.
    try {
      if (kIsWeb) return 4.0;
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        if (info.isLowRamDevice) return 2.0;
        // Non-low-RAM Android: estimate from cores (most mid/high phones 4–8GB).
        return _coreHeuristicRamGb(cores);
      }
      if (Platform.isIOS) {
        // iOS devices are memory-constrained relative to cores; be conservative.
        return cores >= 6 ? 6.0 : 4.0;
      }
      // Desktop (Windows/macOS/Linux): typically far more RAM than mobile.
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        if (cores >= 8) return 16.0;
        if (cores >= 4) return 8.0;
        return 4.0;
      }
    } catch (e, st) {
      _log.fine('RAM detection fell back to heuristic', e, st);
    }

    return _coreHeuristicRamGb(cores);
  }

  static double _coreHeuristicRamGb(int cores) {
    if (cores <= 2) return 2.0;
    if (cores <= 4) return 4.0;
    if (cores <= 6) return 6.0;
    return 8.0;
  }

  static DeviceTier _classify(double ramGb, int cores) {
    if (ramGb <= 3.0 || cores <= 2) return DeviceTier.low;
    if (ramGb >= 8.0 && cores >= 6) return DeviceTier.high;
    return DeviceTier.balanced;
  }

  /// Test hook: force a specific capability set.
  @visibleForTesting
  static void setForTesting(DeviceCapabilities caps) => _cached = caps;

  /// Test hook: clear the cache so [detect] re-runs.
  @visibleForTesting
  static void resetForTesting() => _cached = null;
}
