import 'package:flutter/services.dart';
import '../../features/settings/provider/settings_provider.dart';

mixin HapticHelper {
  void triggerHaptic(SettingsProvider settings) {
    if (settings.vibration) {
      HapticFeedback.lightImpact();
    }
  }
}
