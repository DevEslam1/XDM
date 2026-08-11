import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dmx/core/services/logging_service.dart';

enum ScriptPermission {
  domRead,
  domWrite,
  network,
  storage,
  cookies,
}

class UserScript {
  final String id;
  final String name;
  final String urlPattern;
  final String code;
  final bool isCss;
  final bool enabled;
  final Set<ScriptPermission> permissions;

  const UserScript({
    required this.id,
    required this.name,
    required this.urlPattern,
    required this.code,
    this.isCss = false,
    this.enabled = true,
    this.permissions = const {
      ScriptPermission.domRead,
      ScriptPermission.domWrite
    },
  });

  UserScript copyWith({
    String? name,
    String? urlPattern,
    String? code,
    bool? isCss,
    bool? enabled,
    Set<ScriptPermission>? permissions,
  }) =>
      UserScript(
        id: id,
        name: name ?? this.name,
        urlPattern: urlPattern ?? this.urlPattern,
        code: code ?? this.code,
        isCss: isCss ?? this.isCss,
        enabled: enabled ?? this.enabled,
        permissions: permissions ?? this.permissions,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'urlPattern': urlPattern,
        'code': code,
        'isCss': isCss,
        'enabled': enabled,
        'permissions': permissions.map((e) => e.name).toList(),
      };

  factory UserScript.fromJson(Map<String, dynamic> json) {
    final List<dynamic>? permsJson = json['permissions'] as List<dynamic>?;
    final Set<ScriptPermission> perms = permsJson != null
        ? permsJson
            .map((e) => ScriptPermission.values.firstWhere(
                  (val) => val.name == e,
                  orElse: () => ScriptPermission.domRead,
                ))
            .toSet()
        : {ScriptPermission.domRead, ScriptPermission.domWrite};

    return UserScript(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      urlPattern: json['urlPattern'] as String? ?? '',
      code: json['code'] as String? ?? '',
      isCss: json['isCss'] as bool? ?? false,
      enabled: json['enabled'] as bool? ?? true,
      permissions: perms,
    );
  }
}

class UserScriptManager extends ChangeNotifier {
  static const _storeKey = 'browser_user_scripts';
  static final _log = LoggingService.logger('UserScriptManager');

  static UserScriptManager? _instance;
  static UserScriptManager get instance => _instance ??= UserScriptManager();
  UserScriptManager();

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

  void _validateScript(UserScript script) {
    if (script.isCss) return;
    final code = script.code;
    if (code.length > 50000) {
      throw Exception('Script too large (max 50,000 characters)');
    }
    if (code.contains('flutter_inappwebview') ||
        code.contains('callHandler') ||
        code.contains('postMessage')) {
      _log.severe(
          'Security Violation: Native bridge access detected in script "${script.name}"');
      throw Exception(
          'Scripts are not allowed to access native application bridges.');
    }
    if (code.contains('eval(') ||
        code.contains('new Function(') ||
        code.contains('importScripts(')) {
      _log.severe(
          'Security Violation: Execution bypass detected in script "${script.name}"');
      throw Exception(
          'Dynamic code execution (eval, new Function) is prohibited for security.');
    }
  }

  Future<void> add(UserScript script) async {
    _validateScript(script);
    _scripts.add(script);
    await _persist();
    notifyListeners();
  }

  Future<void> update(UserScript script) async {
    _validateScript(script);
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

  List<UserScript> scriptsForUrl(String url) {
    if (url.isEmpty) return const [];
    return _scripts
        .where(
          (s) => s.enabled && matchesPattern(s.urlPattern, url),
        )
        .toList();
  }

  String _buildSandbox(UserScript script) {
    final marker =
        'xdm_user_script_${script.id.replaceAll(RegExp('[^A-Za-z0-9_]'), '_')}';
    final perms = script.permissions;

    final blockedList = [
      if (!perms.contains(ScriptPermission.network)) ...[
        'fetch',
        'XMLHttpRequest',
        'WebSocket',
        'navigator.sendBeacon'
      ],
      if (!perms.contains(ScriptPermission.storage)) ...[
        'localStorage',
        'sessionStorage',
        'indexedDB'
      ],
      'eval', 'Function', 'importScripts', 'Worker', 'SharedWorker',
    ];

    final jsBlocked = blockedList.map((e) => "'$e'").join(',');

    return '''
if (!window['$marker']) {
  window['$marker'] = true;
  (function() {
    const _blocked = [$jsBlocked];
    const _root = window;
    const _origSetTimeout = _root.setTimeout;
    const _origSetInterval = _root.setInterval;

    const sandboxSetTimeout = function(fn, delay) {
      if (typeof fn === 'string') {
        console.warn('[DMX Sandbox] Blocked setTimeout string execution');
        return null;
      }
      var args = Array.prototype.slice.call(arguments, 2);
      return _origSetTimeout.apply(_root, [fn, delay].concat(args));
    };

    const sandboxSetInterval = function(fn, delay) {
      if (typeof fn === 'string') {
        console.warn('[DMX Sandbox] Blocked setInterval string execution');
        return null;
      }
      var args = Array.prototype.slice.call(arguments, 2);
      return _origSetInterval.apply(_root, [fn, delay].concat(args));
    };

    const sandbox = new Proxy(_root, {
      get(target, prop) {
        if (prop === '__proto__' || prop === 'prototype') {
          return null;
        }
        if (prop === 'window' || prop === 'self' || prop === 'globalThis' ||
            prop === 'parent' || prop === 'top' || prop === 'opener') {
          return sandbox;
        }
        if (prop === 'setTimeout') return sandboxSetTimeout;
        if (prop === 'setInterval') return sandboxSetInterval;
        if (_blocked.includes(prop) || (typeof prop === 'string' && prop.startsWith('flutter_'))) {
          console.warn('[DMX Sandbox] Access denied to: ' + prop);
          return undefined;
        }
        let value = target[prop];
        if (typeof value === 'function') return value.bind(target);
        return value;
      },
      set(target, prop, value) {
        if (prop === '__proto__' || prop === 'prototype') return false;
        if (_blocked.includes(prop) || (typeof prop === 'string' && prop.startsWith('flutter_'))) return false;
        target[prop] = value;
        return true;
      },
      has(target, prop) {
        if (prop === '__proto__' || prop === 'prototype') return false;
        if (_blocked.includes(prop)) return false;
        return prop in target;
      },
      // FIX: Add ownKeys trap to prevent enumeration of blocked properties
      ownKeys(target) {
        return Object.keys(target).filter(k => !_blocked.includes(k) && !k.startsWith('flutter_'));
      },
      getOwnPropertyDescriptor(target, prop) {
        if (_blocked.includes(prop) || (typeof prop === 'string' && prop.startsWith('flutter_'))) {
          return undefined;
        }
        return Object.getOwnPropertyDescriptor(target, prop);
      }
    });

    Object.freeze(sandbox);

    if (!${perms.contains(ScriptPermission.cookies)}) {
      try {
        Object.defineProperty(document, 'cookie', {
          get: function() { return ''; },
          set: function() { return false; },
          configurable: true
        });
      } catch(e) {}
    }

    ${!perms.contains(ScriptPermission.domWrite) ? "const _origWrite = document.write; document.write = () => {}; document.writeln = () => {};" : ""}

    (function(window, self, globalThis) {
      'use strict';
      try {
        ${script.code}
      } catch(e) {
        console.error('[DMX UserScript Error] ' + ${jsonEncode(script.name)} + ':', e);
      }
    })(sandbox, sandbox, sandbox);
  })();
}
''';
  }

  Future<String> getJsForUrl(String url) async {
    final matches = scriptsForUrl(url);
    if (matches.isEmpty) return '';
    final sb = StringBuffer();
    for (final script in matches) {
      if (script.isCss) {
        final jsonCss = jsonEncode(script.code);
        sb.writeln('''
(function() {
  var style = document.getElementById('xdm-user-css');
  if (!style) {
    style = document.createElement('style');
    style.id = 'xdm-user-css';
    document.head.appendChild(style);
  }
  style.textContent = $jsonCss;
})();
''');
      } else {
        sb.writeln(_buildSandbox(script));
      }
    }
    return sb.toString();
  }

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