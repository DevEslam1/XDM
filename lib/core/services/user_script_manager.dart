import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dmx/core/services/logging_service.dart';

/// A single user-authored script or stylesheet that runs on matching pages.
class UserScript {
  final String id;
  final String name;
  final String urlPattern;
  final String code;
  final bool isCss;
  final bool enabled;

  const UserScript({
    required this.id,
    required this.name,
    required this.urlPattern,
    required this.code,
    this.isCss = false,
    this.enabled = true,
  });

  UserScript copyWith({
    String? name,
    String? urlPattern,
    String? code,
    bool? isCss,
    bool? enabled,
  }) =>
      UserScript(
        id: id,
        name: name ?? this.name,
        urlPattern: urlPattern ?? this.urlPattern,
        code: code ?? this.code,
        isCss: isCss ?? this.isCss,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'urlPattern': urlPattern,
        'code': code,
        'isCss': isCss,
        'enabled': enabled,
      };

  factory UserScript.fromJson(Map<String, dynamic> json) => UserScript(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        urlPattern: json['urlPattern'] as String? ?? '',
        code: json['code'] as String? ?? '',
        isCss: json['isCss'] as bool? ?? false,
        enabled: json['enabled'] as bool? ?? true,
      );
}

/// Stores and matches per-URL user scripts. Scripts are matched against both
/// the full URL and its host using a case-insensitive glob ('*' wildcards).
class UserScriptManager extends ChangeNotifier {
  static const _storeKey = 'browser_user_scripts';

  static UserScriptManager? _instance;
  static UserScriptManager get instance =>
      _instance ??= UserScriptManager();

  UserScriptManager();

  /// Clears the cached singleton so the next [instance] access rebuilds it
  /// from storage. Used by tests.
  @visibleForTesting
  static void resetInstance() {
    _instance = null;
  }

  List<UserScript> _scripts = [];
  bool _loaded = false;

  List<UserScript> get scripts => List.unmodifiable(_scripts);

  bool get isLoaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storeKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        _scripts = list
            .map((e) => UserScript.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e) {
        debugPrint('[DMX] Failed to load user scripts: $e');
        _scripts = [];
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(_scripts.map((s) => s.toJson()).toList());
    await prefs.setString(_storeKey, raw);
  }

  Future<void> add(UserScript script) async {
    _scripts.add(script);
    await _persist();
    notifyListeners();
  }

  Future<void> update(UserScript script) async {
    final index = _scripts.indexWhere((s) => s.id == script.id);
    if (index >= 0) {
      _scripts[index] = script;
      await _persist();
      notifyListeners();
    }
  }

  Future<void> remove(String id) async {
    _scripts.removeWhere((s) => s.id == id);
    await _persist();
    notifyListeners();
  }

  Future<void> toggle(String id, bool enabled) async {
    final index = _scripts.indexWhere((s) => s.id == id);
    if (index >= 0) {
      _scripts[index] = _scripts[index].copyWith(enabled: enabled);
      await _persist();
      notifyListeners();
    }
  }

  Future<void> clear() async {
    _scripts = [];
    await _persist();
    notifyListeners();
  }

  /// Enabled scripts whose pattern matches [url] or its host.
  List<UserScript> scriptsForUrl(String url) {
    if (url.isEmpty) return const [];
    return _scripts
        .where(
          (s) => s.enabled && matchesPattern(s.urlPattern, url),
        )
        .toList();
  }

  /// Case-insensitive glob matcher. '*' matches any run of characters and '?'
  /// matches a single character. The pattern is matched against the full URL
  /// as well as the bare host (e.g. `example.com/*` and `example.com`).
  static bool matchesPattern(String pattern, String url) {
    final trimmed = pattern.trim();
    if (trimmed.isEmpty) return false;

    final normalizedUrl = url.toLowerCase();
    final candidates = <String>{normalizedUrl};
    try {
      final host = Uri.parse(url).host.toLowerCase();
      if (host.isNotEmpty) {
        candidates.add(host);
        candidates.add('$host/*');
      }
    } catch (e) {
      LoggingService.logger('UserScriptManager').info(
        '[UserScriptManager] host extraction failed, matching full URL only: $e',
      );
    }

    final regex = _globToRegex(trimmed.toLowerCase());
    return candidates.any((candidate) => regex.hasMatch(candidate));
  }

  static RegExp _globToRegex(String glob) {
    final buffer = StringBuffer('^');
    for (var i = 0; i < glob.length; i++) {
      final char = glob[i];
      switch (char) {
        case '*':
          buffer.write('.*');
          break;
        case '?':
          buffer.write('.');
          break;
        case '.':
        case '(':
        case ')':
        case '+':
        case '[':
        case ']':
        case '{':
        case '}':
        case '^':
        case '\$':
        case '|':
        case '\\':
          buffer.write('\\$char');
          break;
        default:
          buffer.write(char);
      }
    }
    buffer.write('\$');
    return RegExp(buffer.toString());
  }
}