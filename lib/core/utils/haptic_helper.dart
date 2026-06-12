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
      HapticFeedback.mediumImpact().then((_) {
        Future.delayed(const Duration(milliseconds: 100), () {
          HapticFeedback.mediumImpact();
        });
      });
    }
  }
}

void runHaptic(SettingsProvider settings) {
  if (settings.vibration) {
    HapticFeedback.lightImpact();
  }
}

