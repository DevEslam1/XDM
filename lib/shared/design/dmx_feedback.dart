import 'package:flutter/services.dart';
import '../../features/settings/provider/settings_provider.dart';

/// Unified Feedback System — Consistent haptic feedback across all user interactions
abstract final class DmxFeedback {
  static void tap(SettingsProvider settings) {
    if (settings.vibration) HapticFeedback.lightImpact();
  }

  static void confirm(SettingsProvider settings) {
    if (settings.vibration) HapticFeedback.mediumImpact();
  }

  static void success(SettingsProvider settings) {
    if (settings.vibration) {
      HapticFeedback.mediumImpact();
      Future.delayed(const Duration(milliseconds: 100), () {
        HapticFeedback.lightImpact();
      });
    }
  }

  static void error(SettingsProvider settings) {
    if (settings.vibration) {
      HapticFeedback.heavyImpact();
      Future.delayed(const Duration(milliseconds: 150), () {
        HapticFeedback.mediumImpact();
      });
    }
  }

  static void selection(SettingsProvider settings) {
    if (settings.vibration) HapticFeedback.selectionClick();
  }
}
