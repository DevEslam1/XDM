import 'dart:convert';

import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  static String _decodeUnicodeEscapes(String input) {
    return input.replaceAllMapped(
      RegExp(r'\\u([0-9a-fA-F]{4})|\\u\{([0-9a-fA-F]+)\}'),
      (match) {
        final hex = match.group(1) ?? match.group(2);
        if (hex != null) {
          final code = int.tryParse(hex, radix: 16);
          if (code != null) {
            return String.fromCharCode(code);
          }
        }
        return match.group(0)!;
      },
    );
  }

  void _validateScript(UserScript script) {
    if (script.isCss) return;
    final code = script.code;
    if (code.length > 50000) {
      _log.warning(
          'Security Rejection: Script "${script.name}" exceeds 50,000 characters');
      throw Exception('Script too large (max 50,000 characters)');
    }

    final decoded = _decodeUnicodeEscapes(code);
    final stripped = decoded.replaceAll(RegExp(r'/\*[\s\S]*?\*/|//.*'), '');

    if (stripped.contains('flutter_inappwebview') ||
        stripped.contains('callHandler') ||
        stripped.contains('postMessage')) {
      _log.warning(
          'Security Violation: Native bridge access detected in script "${script.name}"');
      throw Exception(
          'Scripts are not allowed to access native application bridges.');
    }

    if (RegExp(r'\beval\b').hasMatch(stripped) ||
        stripped.contains('eval(') ||
        stripped.contains('eval ') ||
        RegExp(r'\bFunction\b').hasMatch(stripped) ||
        stripped.contains('new Function') ||
        stripped.contains('importScripts(') ||
        stripped.contains('importScripts ')) {
      _log.warning(
          'Security Violation: Dynamic code execution (eval/Function) detected in script "${script.name}"');
      throw Exception(
          'Dynamic code execution (eval, new Function) is prohibited for security.');
    }

    if (stripped.contains('document.cookie') ||
        RegExp(r'document\s*\[\s*["\x27]cookie["\x27]\s*\]')
            .hasMatch(stripped)) {
      _log.warning(
          'Security Violation: Cookie access in script "${script.name}"');
      throw Exception('Cookie access is prohibited in UserScripts.');
    }

    if (stripped.contains('window.open(') ||
        stripped.contains('window.open ')) {
      _log.warning(
          'Security Violation: window.open in script "${script.name}"');
      throw Exception('Opening new windows is prohibited in UserScripts.');
    }

    if (stripped.contains('Symbol.toPrimitive') ||
        stripped.contains('Symbol.iterator') ||
        stripped.contains('Symbol.hasInstance')) {
      _log.warning(
          'Security Violation: Symbol-based sandbox escape in script "${script.name}"');
      throw Exception('Symbol-based sandbox escape blocked.');
    }

    if (RegExp(r'\bwith\s*\(').hasMatch(stripped)) {
      _log.warning(
          'Security Violation: "with" statement in script "${script.name}"');
      throw Exception('"with" statement is prohibited.');
    }

    if (stripped.contains('__proto__') ||
        stripped.contains('constructor.prototype') ||
        stripped.contains('Object.prototype') ||
        stripped.contains('Function.prototype')) {
      _log.warning(
          'Security Violation: Prototype pollution in script "${script.name}"');
      throw Exception('Prototype access or pollution is prohibited.');
    }

    if (stripped.contains('navigator.sendBeacon')) {
      _log.warning('Security Violation: sendBeacon in script "${script.name}"');
      throw Exception('Beacon transmission is prohibited in UserScripts.');
    }

    if (RegExp(r'\bimport\s*[\(\b]').hasMatch(stripped) ||
        RegExp(r'\bimport\s+').hasMatch(stripped)) {
      _log.warning(
          'Security Violation: dynamic import in script "${script.name}"');
      throw Exception('Dynamic imports are prohibited in UserScripts.');
    }

    final hasObfuscatedEval =
        RegExp(r'window\s*\[\s*["\x27]ev').hasMatch(stripped);
    final hasObfuscatedFunction =
        RegExp(r'window\s*\[\s*["\x27]Function').hasMatch(stripped);
    final hasGlobalThis = RegExp(r'globalThis\s*\[').hasMatch(stripped);
    final hasConstructorCall = RegExp(r'constructor\s*\(').hasMatch(stripped);
    final hasCharCode = stripped.contains('String.fromCharCode');
    final hasAtob = stripped.contains('atob(');
    final hasBtoa = stripped.contains('btoa(');
    final hasReflect =
        stripped.contains('Reflect.') || stripped.contains('Reflect[');
    final hasProxy =
        stripped.contains('Proxy(') || stripped.contains('new Proxy');
    final hasProtoGetSet = stripped.contains('getPrototypeOf') ||
        stripped.contains('setPrototypeOf');

    if (hasObfuscatedEval ||
        hasObfuscatedFunction ||
        hasGlobalThis ||
        hasConstructorCall ||
        hasCharCode ||
        hasAtob ||
        hasBtoa ||
        hasReflect ||
        hasProxy ||
        hasProtoGetSet) {
      _log.warning(
          'Security Violation: Obfuscated dynamic execution / reflection in script "${script.name}"');
      throw Exception('Obfuscated dynamic execution or reflection detected');
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

    final hasNetwork = perms.contains(ScriptPermission.network);
    final hasCookies = perms.contains(ScriptPermission.cookies);
    final hasDomWrite = perms.contains(ScriptPermission.domWrite);

    return '''
if (!window['$marker']) {
  window['$marker'] = true;
  (function() {
    'use strict';
    const _sandboxTimeoutMs = 5000;
    const _startTime = Date.now();

    // Isolated scope wrappers
    const _noop = function() {};

    // FIX: Block Function.prototype.constructor access
    try {
      Object.defineProperty(Function.prototype, 'constructor', {
        get: function() { throw new Error('[XDM Sandbox] Function constructor blocked'); },
        configurable: false
      });
    } catch(e) {}

    // DOM Write blocking
    if (!$hasDomWrite) {
      try {
        document.write = function() {
          throw new Error('[DMX Sandbox] document.write denied by permission policy');
        };
        document.writeln = function() {
          throw new Error('[DMX Sandbox] document.writeln denied by permission policy');
        };
      } catch(e) {}
    }
    
    // Cookie blocking
    if (!$hasCookies) {
      try {
        Object.defineProperty(document, 'cookie', {
          get: function() { return ''; },
          set: function() { throw new Error('[DMX Sandbox] Cookie access denied'); },
          configurable: false
        });
      } catch(e) {}
    }

    // Network blocking
    if (!$hasNetwork) {
      window['fetch'] = function() {
        throw new Error('[DMX Sandbox] Network fetch denied by permission policy');
      };
      window['XMLHttpRequest'] = function() {
        throw new Error('[DMX Sandbox] XMLHttpRequest denied by permission policy');
      };
      if (window['WebSocket']) {
        window['WebSocket'] = function() {
          throw new Error('[DMX Sandbox] WebSocket denied by permission policy');
        };
      }
    }

    // FIX-S1: Sandbox scope proxy blocking parent, top, opener, eval, window.open/close/postMessage, and rate limiting timers
    const _isolatedWindow = new Proxy(window, {
      get(target, prop) {
        if (prop === 'parent' || prop === 'top' || prop === 'opener') {
          return null;
        }
        if (prop === 'open' || prop === 'close' || prop === 'postMessage') {
          return function() {
            throw new Error('[DMX Sandbox] Access to ' + String(prop) + ' is prohibited');
          };
        }
        if (prop === 'eval' || prop === 'Function' || prop === 'importScripts' || prop === 'Reflect' || prop === 'Proxy') {
          throw new Error('[DMX Sandbox] Dynamic execution / reflection prohibited: ' + String(prop));
        }
        if (typeof prop === 'symbol') {
          if (prop === Symbol.toPrimitive || prop === Symbol.iterator || prop === Symbol.hasInstance) {
            return undefined;
          }
        }
        if (prop === 'setTimeout' || prop === 'setInterval') {
          return function(fn, delay, ...args) {
            const safeDelay = Math.max(50, Number(delay) || 0);
            return target[prop](fn, safeDelay, ...args);
          };
        }
        if (prop === 'crypto' && target.crypto) {
          return { subtle: undefined };
        }
        if (prop === '__proto__' || prop === 'prototype' || prop === 'constructor') {
          return null;
        }
        let val = target[prop];
        if (typeof val === 'function') return val.bind(target);
        return val;
      },
      set(target, prop, value) {
        if (prop === 'parent' || prop === 'top' || prop === 'opener' || prop === '__proto__' ||
            prop === 'prototype' || prop === 'constructor' ||
            prop === 'open' || prop === 'close' || prop === 'postMessage') {
          return false;
        }
        target[prop] = value;
        return true;
      }
    });

    try {
      window.eval = function() { throw new Error('[DMX Sandbox] eval is disabled'); };
      window.Function = function() { throw new Error('[DMX Sandbox] Function constructor is disabled'); };
    } catch(e) {}

    try {
      if (typeof Object.freeze === 'function') {
        try { Object.freeze(Object.prototype); } catch(e) {}
        try { Object.freeze(Function.prototype); } catch(e) {}
        try { Object.freeze(Array.prototype); } catch(e) {}
        try { Object.freeze(String.prototype); } catch(e) {}
      }
    } catch(e) {}

    try {
      (function(window, self, globalThis, parent, top, opener) {
        if (Date.now() - _startTime > _sandboxTimeoutMs) {
          throw new Error('[DMX Sandbox] Script execution timeout exceeded (5s)');
        }
        ${script.code}
      })(_isolatedWindow, _isolatedWindow, _isolatedWindow, null, null, null);
    } catch(e) {
      console.error('[DMX UserScript Sandbox Error] ' + ${jsonEncode(script.name)} + ':', e);
    }
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
