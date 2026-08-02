import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

enum ProtocolSupport { http11, http2, http3 }

class _HostCaps {
  final ProtocolSupport support;
  final DateTime at;

  _HostCaps({required this.support, required this.at});

  bool get isExpired => DateTime.now().difference(at) > ProtocolCache._ttl;

  Map<String, dynamic> toJson() => {
        'support': support.name,
        'at': at.toIso8601String(),
      };

  factory _HostCaps.fromJson(Map<String, dynamic> json) {
    return _HostCaps(
      support: ProtocolSupport.values.firstWhere(
        (e) => e.name == json['support'],
        orElse: () => ProtocolSupport.http11,
      ),
      at: DateTime.parse(json['at'] as String),
    );
  }
}

/// Remembers per-host protocol support so we never re-probe unnecessarily.
class ProtocolCache {
  static const _key = 'protocol_capabilities';
  static Map<String, _HostCaps>? _cache;
  static const _ttl = Duration(days: 7);

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    _cache = raw == null ? {} : _decode(raw);
    _cache!.removeWhere((_, c) => c.isExpired);
  }

  static ProtocolSupport? get(String url) {
    final host = Uri.tryParse(url)?.host;
    if (host == null) return null;
    final caps = _cache?[host];
    if (caps == null || caps.isExpired) return null;
    return caps.support;
  }

  static Future<void> record(String url, ProtocolSupport support) async {
    final host = Uri.tryParse(url)?.host;
    if (host == null) return;
    _cache ??= {};
    _cache![host] = _HostCaps(support: support, at: DateTime.now());
    await _persist();
  }

  static Map<String, _HostCaps> _decode(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map(
        (k, v) => MapEntry(k, _HostCaps.fromJson(v as Map<String, dynamic>)),
      );
    } catch (_) {
      return {};
    }
  }

  static Future<void> _persist() async {
    if (_cache == null) return;
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(
      _cache!.map((k, v) => MapEntry(k, v.toJson())),
    );
    await prefs.setString(_key, encoded);
  }
}
