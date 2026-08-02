import 'dart:async';
import 'dart:io';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

/// Thermal status categories.
enum ThermalStatus { none, fair, moderate, severe, critical }

/// Central power intelligence. Every subsystem reads from here.
class PowerMonitor {
  static final _log = Logger('PowerMonitor');
  static final Battery _battery = Battery();
  static const _channel = MethodChannel('com.dmx.app/thermal');

  static BatteryState _state = BatteryState.unknown;
  static int _level = 100;
  static ThermalStatus _thermal = ThermalStatus.none;
  static StreamSubscription? _sub;
  static Timer? _thermalTimer;
  static bool _screenOn = true;

  static BatteryState get batteryState => _state;
  static int get batteryLevel => _level;
  static ThermalStatus get thermal => _thermal;
  static bool get isCharging =>
      _state == BatteryState.charging || _state == BatteryState.full;
  static bool get screenOff => !_screenOn;

  static void setScreenOn(bool on) {
    _screenOn = on;
  }

  /// Master "aggression" scalar: 1.0 = full power, 0.3 = conserve hard.
  static double get throttleFactor {
    var f = 1.0;
    if (!isCharging) {
      if (_level < 20) {
        f *= 0.5;
      } else if (_level < 40) {
        f *= 0.75;
      }
    }
    switch (_thermal) {
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
    return f.clamp(0.3, 1.0);
  }

  static Future<void> init() async {
    try {
      _sub = _battery.onBatteryStateChanged.listen((s) {
        _state = s;
        _log.info('[Power] State: $s');
      });
      _level = await _battery.batteryLevel;
    } catch (e) {
      _log.warning('[Power] Battery listener init failed: $e');
    }
    _pollThermal();
  }

  /// Poll thermal status periodically (native bridge on Android/iOS).
  static void _pollThermal() {
    _thermalTimer?.cancel();
    _thermalTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
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
          if (raw != null && raw >= 0 && raw < ThermalStatus.values.length) {
            _thermal = ThermalStatus.values[raw];
          }
        }
        _level = await _battery.batteryLevel;
      } catch (_) {}
    });
  }

  static void dispose() {
    _sub?.cancel();
    _thermalTimer?.cancel();
  }
}
