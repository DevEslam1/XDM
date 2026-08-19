import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/services.dart';

import '../../features/settings/provider/settings_provider.dart';

mixin HapticHelper {
  /// Standardized haptic trigger across all browser widgets (static).
  static void triggerHaptic(SettingsProvider settings) {
    if (settings.vibration) {
      HapticFeedback.lightImpact();
    }
  }

  /// Instance method proxying the standardized trigger.
  void triggerHapticFeedback(SettingsProvider settings) {
    triggerHaptic(settings);
  }

  void mediumPulse(SettingsProvider settings) {
    if (settings.vibration) {
      HapticFeedback.mediumImpact();
    }
  }

  void heavyPulse(SettingsProvider settings) {
    if (settings.vibration) {
      HapticFeedback.heavyImpact();
    }
  }

  void errorPulse(SettingsProvider settings) {
    if (settings.vibration) {
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
