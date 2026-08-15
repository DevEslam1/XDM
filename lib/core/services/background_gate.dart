import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/power_monitor.dart';

/// Central gate controlling ALL background resource usage.
/// Every timer, animation, and I/O operation must check this gate.
abstract class BackgroundGate {
  /// Returns true if heavy operations are allowed right now.
  static bool get allowHeavyOps =>
      !PowerMonitor.screenOff &&
      DownloadEngine.appInForeground &&
      PowerMonitor.batterySaverMode != BatterySaverMode.aggressive;

  /// Returns true if lightweight operations are allowed.
  static bool get allowLightOps =>
      !PowerMonitor.screenOff && DownloadEngine.appInForeground;

  /// Scales a duration based on current power context.
  /// Call this to get the effective interval for any periodic operation.
  static Duration scaleInterval(Duration base) {
    if (PowerMonitor.screenOff) return base * 20;
    if (DownloadEngine.isInBackground) return base * 5;
    if (PowerMonitor.batterySaverMode == BatterySaverMode.aggressive) {
      return base * 8;
    }
    if (PowerMonitor.batterySaverMode == BatterySaverMode.moderate) {
      return base * 3;
    }
    return base;
  }

  static bool? _manualShouldAnimate;

  /// Backward-compatible alias for shouldAnimate.
  static bool get shouldAnimate => _manualShouldAnimate ?? allowHeavyOps;
  static set shouldAnimate(bool val) => _manualShouldAnimate = val;

  /// Backward-compatible alias for adaptInterval.
  static Duration adaptInterval(Duration base) => scaleInterval(base);

  /// Backward-compatible alias for shouldWriteState.
  static bool get shouldWriteState => allowLightOps;
}
