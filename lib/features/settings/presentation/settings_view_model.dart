import 'package:flutter/foundation.dart';
import '../provider/settings_provider.dart';

/// ViewModel exposing granular view models and settings state for UI screens.
class SettingsViewModel extends ChangeNotifier {
  final SettingsProvider settingsProvider;

  SettingsViewModel({required this.settingsProvider});

  bool get isDarkMode => settingsProvider.isDarkMode;
  bool get isAmoledMode => settingsProvider.isAmoledMode;
  bool get wifiOnly => settingsProvider.wifiOnly;
  int get defaultThreadCount => settingsProvider.defaultThreadCount;
  String? get customDownloadPath => settingsProvider.customDownloadPath;
  bool get enableGlow => settingsProvider.enableGlow;
  double get gridOpacity => settingsProvider.gridOpacity;
  bool get classicUi => settingsProvider.classicUi;
  bool get reduceVisuals => settingsProvider.reduceVisuals;
}
