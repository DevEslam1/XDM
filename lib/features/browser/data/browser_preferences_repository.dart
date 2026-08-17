import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Repository for persisting browser-specific user preferences and state.
class BrowserPreferencesRepository {
  static const String _snifferPrefKey = 'browser_media_sniffer_enabled';
  static const String _incognitoBannerKey =
      'browser_incognito_banner_dismissed';
  static const String _customShortcutsKey = 'browser_custom_shortcuts';

  final SharedPreferences? _prefs;

  BrowserPreferencesRepository([this._prefs]);

  Future<SharedPreferences> _getPrefs() async {
    return _prefs ?? await SharedPreferences.getInstance();
  }

  Future<bool> getSnifferEnabled({bool defaultValue = true}) async {
    try {
      final prefs = await _getPrefs();
      return prefs.getBool(_snifferPrefKey) ?? defaultValue;
    } catch (_) {
      return defaultValue;
    }
  }

  Future<void> setSnifferEnabled(bool value) async {
    try {
      final prefs = await _getPrefs();
      await prefs.setBool(_snifferPrefKey, value);
    } catch (_) {}
  }

  Future<bool> getIncognitoBannerDismissed({bool defaultValue = false}) async {
    try {
      final prefs = await _getPrefs();
      return prefs.getBool(_incognitoBannerKey) ?? defaultValue;
    } catch (_) {
      return defaultValue;
    }
  }

  Future<void> setIncognitoBannerDismissed(bool value) async {
    try {
      final prefs = await _getPrefs();
      await prefs.setBool(_incognitoBannerKey, value);
    } catch (_) {}
  }

  Future<List<Map<String, String>>> getCustomShortcuts() async {
    try {
      final prefs = await _getPrefs();
      final raw = prefs.getString(_customShortcutsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List;
        return decoded
            .map((e) => Map<String, String>.from(e as Map))
            .toList();
      }
    } catch (_) {}
    return [];
  }

  Future<void> saveCustomShortcuts(List<Map<String, String>> shortcuts) async {
    try {
      final prefs = await _getPrefs();
      await prefs.setString(_customShortcutsKey, jsonEncode(shortcuts));
    } catch (_) {}
  }
}
