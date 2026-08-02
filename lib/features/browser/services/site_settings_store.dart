import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logging/logging.dart';

class SiteSettings {
  final bool? desktopMode;
  final bool? adBlockEnabled;
  final double? zoomLevel;
  final List<String>? customCss;
  final List<String>? customJs;

  const SiteSettings({
    this.desktopMode,
    this.adBlockEnabled,
    this.zoomLevel,
    this.customCss,
    this.customJs,
  });

  SiteSettings copyWith({
    bool? desktopMode,
    bool? adBlockEnabled,
    double? zoomLevel,
    List<String>? customCss,
    List<String>? customJs,
  }) =>
      SiteSettings(
        desktopMode: desktopMode ?? this.desktopMode,
        adBlockEnabled: adBlockEnabled ?? this.adBlockEnabled,
        zoomLevel: zoomLevel ?? this.zoomLevel,
        customCss: customCss ?? this.customCss,
        customJs: customJs ?? this.customJs,
      );

  Map<String, dynamic> toJson() => {
        if (desktopMode != null) 'desktopMode': desktopMode,
        if (adBlockEnabled != null) 'adBlockEnabled': adBlockEnabled,
        if (zoomLevel != null) 'zoomLevel': zoomLevel,
        if (customCss != null) 'customCss': customCss,
        if (customJs != null) 'customJs': customJs,
      };

  factory SiteSettings.fromJson(Map<String, dynamic> json) => SiteSettings(
        desktopMode: json['desktopMode'] as bool?,
        adBlockEnabled: json['adBlockEnabled'] as bool?,
        zoomLevel: (json['zoomLevel'] as num?)?.toDouble(),
        customCss: (json['customCss'] as List?)?.cast<String>(),
        customJs: (json['customJs'] as List?)?.cast<String>(),
      );
}

class SiteSettingsStore {
  static const _storeKey = 'browser_site_settings';
  static Map<String, SiteSettings>? _cache;

  static Future<Map<String, SiteSettings>> _load() async {
    if (_cache != null) return _cache!;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storeKey);
    if (raw == null) {
      _cache = {};
      return _cache!;
    }
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      _cache = map.map((k, v) => MapEntry(k, SiteSettings.fromJson(v)));
    } catch (e, st) {
      Logger('site_settings_store').warning('[site_settings_store] operation failed', e, st);
      _cache = {};
    }
    return _cache!;
  }

  static Future<SiteSettings> getForHost(String host) async {
    final all = await _load();
    return all[host] ?? const SiteSettings();
  }

  static Future<void> updateForHost(String host, SiteSettings settings) async {
    final all = await _load();
    all[host] = settings;
    await _persist(all);
  }

  static Future<void> _persist(Map<String, SiteSettings> all) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(all.map((k, v) => MapEntry(k, v.toJson())));
    await prefs.setString(_storeKey, raw);
  }

  static void clearCache() {
    _cache = null;
  }
}