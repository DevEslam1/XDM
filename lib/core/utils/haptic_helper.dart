import 'dart:io';

import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../features/settings/provider/settings_provider.dart';

mixin HapticHelper {
  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Standardized haptic trigger across all browser widgets (static).
  static void triggerHaptic(SettingsProvider settings) {
    if (isSupported && settings.vibration) {
      HapticFeedback.lightImpact();
    }
  }

  /// Instance method proxying the standardized trigger.
  void triggerHapticFeedback(SettingsProvider settings) {
    triggerHaptic(settings);
  }

  void mediumPulse(SettingsProvider settings) {
    if (isSupported && settings.vibration) {
      HapticFeedback.mediumImpact();
    }
  }

  void heavyPulse(SettingsProvider settings) {
    if (isSupported && settings.vibration) {
      HapticFeedback.heavyImpact();
    }
  }

  void errorPulse(SettingsProvider settings) {
    if (isSupported && settings.vibration) {
      _runErrorPulse().catchError((e) {
        LoggingService.logger('HapticHelper').info(
          '[HapticHelper] error pulse skipped: $e',
        );
      });
    }
  }

  Future<void> _runErrorPulse() async {
    await HapticFeedback.mediumImpact();
    await Future.delayed(const Duration(milliseconds: 100));
    if (this is State && !(this as State).mounted) {
      return;
    }
    await HapticFeedback.mediumImpact();
  }
}

/// Global helper functions for backward compatibility across all screens.
void triggerHaptic(SettingsProvider settings) =>
    HapticHelper.triggerHaptic(settings);
void runHaptic(SettingsProvider settings) =>
    HapticHelper.triggerHaptic(settings);
void lightPulse(SettingsProvider settings) =>
    HapticHelper.triggerHaptic(settings);
