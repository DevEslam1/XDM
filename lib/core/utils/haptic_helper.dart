import 'package:flutter/services.dart';
import '../../features/settings/provider/settings_provider.dart';

mixin HapticHelper {
  void triggerHaptic(SettingsProvider settings) {
    lightPulse(settings);
  }

  void lightPulse(SettingsProvider settings) {
    if (settings.vibration) {
      HapticFeedback.lightImpact();
    }
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
      _runErrorPulse();
    }
  }

  Future<void> _runErrorPulse() async {
    await HapticFeedback.mediumImpact();
    await Future.delayed(const Duration(milliseconds: 100));
    await HapticFeedback.mediumImpact();
  }
}

void runHaptic(SettingsProvider settings) {
  if (settings.vibration) {
    HapticFeedback.lightImpact();
  }
}

