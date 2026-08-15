import 'dart:async';
import 'dart:io';
import 'package:battery_plus/battery_plus.dart';
import 'package:dmx/core/services/background_gate.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

/// Thermal status categories.
enum ThermalStatus { none, fair, moderate, severe, critical }

/// Battery saver operating modes.
enum BatterySaverMode { off, moderate, aggressive }

/// Central power intelligence. Every subsystem reads from here.
class PowerMonitor {
  static final _log = Logger('PowerMonitor');
  static final Battery _battery = Battery();
  static const _channel = MethodChannel('com.dmx.app/thermal');

  static const int kBatterySaverAggressiveThreshold = 20;
  static const int kBatterySaverModerateThreshold = 40;
  static const int kBatterySaverRestoreThreshold = 30;
  static const int kThermalLimitedMaxThreads = 2;

  static BatteryState _state = BatteryState.unknown;
  static int _level = 100;
  static ThermalStatus _thermal = ThermalStatus.none;
  static StreamSubscription? _sub;
  static Timer? _thermalTimer;
  static bool _screenOn = true;
  static bool isAppForegrounded = true;

  /// Notifies subscribers immediately whenever [throttleFactor] changes.
  static final ValueNotifier<double> throttleFactorNotifier =
      ValueNotifier<double>(1.0);

  static bool thermalThreadLimitingEnabled = true;
  static bool powerBandwidthThrottlingEnabled = true;

  static final StreamController<bool> _screenStateController =
      StreamController<bool>.broadcast();
  static Stream<bool> get screenStateStream => _screenStateController.stream;

  static BatteryState get batteryState => _state;
  static int get batteryLevel => _level;
  static ThermalStatus get thermal => _thermal;
  static bool get isCharging =>
      _state == BatteryState.charging || _state == BatteryState.full;
  static bool get screenOff => !_screenOn;

  static BatterySaverMode? _lastSaverMode;

  static BatterySaverMode get batterySaverMode {
    if (_thermal == ThermalStatus.severe || _thermal == ThermalStatus.critical) {
      _lastSaverMode = BatterySaverMode.aggressive;
      return BatterySaverMode.aggressive;
    }
    if (isCharging) {
      _lastSaverMode = BatterySaverMode.off;
      return BatterySaverMode.off;
    }
    if (_level < kBatterySaverAggressiveThreshold) {
      _lastSaverMode = BatterySaverMode.aggressive;
    } else if (_level < kBatterySaverModerateThreshold) {
      // Moderate band [20, 40). Once in aggressive mode, hold it until the
      // battery climbs back above the restore threshold to avoid flapping.
      if (_lastSaverMode == BatterySaverMode.aggressive &&
          _level < kBatterySaverRestoreThreshold) {
        _lastSaverMode = BatterySaverMode.aggressive;
      } else {
        _lastSaverMode = BatterySaverMode.moderate;
      }
    } else {
      _lastSaverMode = BatterySaverMode.off;
    }
    return _lastSaverMode!;
  }

  static bool get isLowPowerMode => batterySaverMode != BatterySaverMode.off;

  /// Thermal and battery-aware thread limiter.
  static int get maxAllowedThreads {
    if (batterySaverMode == BatterySaverMode.aggressive) {
      return 1;
    }
    if (thermalThreadLimitingEnabled &&
        (_thermal == ThermalStatus.severe ||
            _thermal == ThermalStatus.critical)) {
      return kThermalLimitedMaxThreads;
    }
    return 16;
  }

  static bool _hasActiveDownloads = false;

  static void setDownloadActive(bool active) {
    if (_hasActiveDownloads != active) {
      _hasActiveDownloads = active;
      _startThermalTimer();
    }
  }

  static void setScreenOn(bool on) {
    if (_screenOn != on) {
      _screenOn = on;
      _screenStateController.add(on);
      _notifyThrottleFactor();
      _startThermalTimer();
    }
  }

  @visibleForTesting
  static void setBatteryLevelForTesting(int level) {
    _level = level;
    _lastSaverMode = null;
    _notifyThrottleFactor();
  }

  @visibleForTesting
  static void setBatteryStateForTesting(BatteryState state) {
    _state = state;
    _lastSaverMode = null;
    _notifyThrottleFactor();
  }

  @visibleForTesting
  static void setThermalStatusForTesting(ThermalStatus status) {
    _thermal = status;
    _notifyThrottleFactor();
  }

  static void _notifyThrottleFactor() {
    throttleFactorNotifier.value = throttleFactor;
  }

  /// Master "aggression" scalar: 1.0 = full power, 0.3 = conserve hard.
  static double get throttleFactor {
    if (!powerBandwidthThrottlingEnabled) return 1.0;
    var f = 1.0;
    if (!isCharging) {
      if (_level < kBatterySaverAggressiveThreshold) {
        f *= 0.5;
      } else if (_level < kBatterySaverModerateThreshold) {
        f *= 0.75;
      }
    }
    // When screen is off + thermal is moderate or worse, be more conservative
    final effectiveThermal = (screenOff && _thermal == ThermalStatus.moderate)
        ? ThermalStatus.severe
        : _thermal;

    switch (effectiveThermal) {
      case ThermalStatus.critical:
        f *= 0.3;
        break;
      case ThermalStatus.severe:
        f *= 0.5;
        break;
      case ThermalStatus.moderate:
        f *= 0.7;
        break;
      default:
        break;
    }
    double floor = 0.3;
    if (batterySaverMode == BatterySaverMode.moderate) {
      floor = 0.6;
    } else if (batterySaverMode == BatterySaverMode.aggressive) {
      floor = 0.3;
    }
    return f.clamp(floor, 1.0);
  }

  static Future<void> init() async {
    try {
      _sub = _battery.onBatteryStateChanged.listen((s) {
        _state = s;
        _notifyThrottleFactor();
        _log.info('[Power] State: $s');
      });
      _level = await _battery.batteryLevel;
      _notifyThrottleFactor();
    } catch (e) {
      _log.warning('[Power] Battery listener init failed: $e');
    }
    await _pollThermalOnce();
    _startThermalTimer();
  }

  static Future<void> _pollThermalOnce() async {
    try {
      if (Platform.isAndroid) {
        final status = await _channel.invokeMethod<String>('getThermalStatus');
        if (status != null) {
          _thermal = ThermalStatus.values.firstWhere(
            (t) => t.name == status,
            orElse: () => ThermalStatus.none,
          );
        }
      } else if (Platform.isIOS) {
        final raw = await _channel.invokeMethod<int>('getThermalStatus');
        if (raw != null) {
          _thermal = switch (raw) {
            0 => ThermalStatus.none,
            1 => ThermalStatus.fair,
            2 => ThermalStatus.severe,
            3 => ThermalStatus.critical,
            _ => ThermalStatus.none,
          };
        }
      }
      _level = await _battery.batteryLevel;
      _notifyThrottleFactor();
    } catch (e) {
      _log.info('[PowerMonitor] thermal poll skipped: $e');
    }
  }

  /// Poll thermal status periodically (native bridge on Android/iOS).
  /// Adaptive intervals:
  /// - Active download + thermal stress (throttleFactor < 0.8): 15s
  /// - Active download normal: 60s
  /// - No active downloads: 120s
  static void _startThermalTimer() {
    _thermalTimer?.cancel();

    // Stop if no active downloads
    if (!_hasActiveDownloads) return;

    final int intervalSeconds = (PowerMonitor.screenOff || !isAppForegrounded)
        ? 120
        : BackgroundGate.adaptInterval(
            const Duration(seconds: 60),
          ).inSeconds;

    _thermalTimer = Timer.periodic(Duration(seconds: intervalSeconds), (_) {
      if (PowerMonitor.screenOff && !_hasActiveDownloads) return;
      _pollThermalOnce();
    });
  }

  @visibleForTesting
  static void setBatteryForTesting({
    required int level,
    required BatteryState state,
  }) {
    _level = level;
    _state = state;
    _lastSaverMode = null;
    _notifyThrottleFactor();
  }

  @visibleForTesting
  static void setThermalForTesting(ThermalStatus thermal) {
    _thermal = thermal;
    _notifyThrottleFactor();
  }

  // FIX-1.3: Close StreamControllers and cancel timers on dispose
  static void dispose() {
    _sub?.cancel();
    _sub = null;
    _thermalTimer?.cancel();
    _thermalTimer = null;
    if (!_screenStateController.isClosed) {
      _screenStateController.close();
    }
  }
}
