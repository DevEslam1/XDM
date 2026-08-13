import 'package:shared_preferences/shared_preferences.dart';
import 'package:logging/logging.dart';
import 'ad_blocker_service.dart';

/// Manages user-defined ad-block hostnames with persistence.
class CustomAdBlockStore {
  static final _log = Logger('CustomAdBlockStore');
  CustomAdBlockStore._();
  static final CustomAdBlockStore instance = CustomAdBlockStore._();

  static const String _prefKeyHosts = 'custom_adblock_hosts';
  static const String _prefKeyUseCustomOnly = 'custom_adblock_use_custom_only';

  final Set<String> _hosts = {};
  bool _useCustomOnly = false;

  Set<String> get hosts => Set.unmodifiable(_hosts);
  bool get useCustomOnly => _useCustomOnly;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _useCustomOnly = prefs.getBool(_prefKeyUseCustomOnly) ?? false;
      final savedHosts = prefs.getStringList(_prefKeyHosts) ?? [];
      _hosts.clear();
      _hosts.addAll(savedHosts);
    } catch (e) {
      _log.warning('[CustomAdBlockStore] Init error: $e');
    }
  }

  Future<void> setUseCustomOnly(bool value) async {
    if (_useCustomOnly != value) {
      _useCustomOnly = value;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_prefKeyUseCustomOnly, value);
      } catch (e) {
        _log.warning('[CustomAdBlockStore] Failed to save useCustomOnly: $e');
      }
      AdBlockerService.instance.refresh();
    }
  }

  String _sanitizeHost(String input) {
    var host = input.trim().toLowerCase();
    if (host.isEmpty) return '';

    // Strip scheme if present
    if (host.contains('://')) {
      try {
        final uri = Uri.parse(host);
        host = uri.host;
      } catch (_) {
        host = host.split('://').last;
      }
    }

    // Strip path/query/fragment
    final slashIdx = host.indexOf('/');
    if (slashIdx != -1) host = host.substring(0, slashIdx);

    // Strip port if present (handling IPv6 brackets gracefully)
    if (host.startsWith('[')) {
      final closingBracket = host.indexOf(']');
      if (closingBracket != -1) {
        host = host.substring(0, closingBracket + 1);
      }
    } else {
      final colonIdx = host.indexOf(':');
      if (colonIdx != -1) host = host.substring(0, colonIdx);
    }

    host = host.trim();
    if (host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }

    if (host.isEmpty) return '';

    // IPv4 Address check (e.g. 192.168.1.1, 127.0.0.1, 0.0.0.0)
    if (RegExp(r'^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$').hasMatch(host)) {
      return host;
    }

    // IPv6 Address check (e.g. ::1, fe80::1)
    if (RegExp(r'^\[?[0-9a-fA-F:]+\]?$').hasMatch(host)) {
      return host;
    }

    // Hostname check (supports standard domains, local TLDs like .local/.lan, localhost, etc.)
    if (RegExp(r'^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$').hasMatch(host)) {
      return host;
    }
    return '';
  }

  /// Adds one or more hosts from a string (newline, comma, or space separated).
  Future<void> addHosts(String rawInput) async {
    final separators = RegExp(r'[,\n\s]+');
    final inputs = rawInput.split(separators);
    var changed = false;
    for (var input in inputs) {
      final host = _sanitizeHost(input);
      if (host.isNotEmpty && !_hosts.contains(host)) {
        _hosts.add(host);
        changed = true;
      }
    }
    if (changed) {
      await _save();
      AdBlockerService.instance.refresh();
    }
  }

  Future<void> removeHost(String input) async {
    final sanitized = _sanitizeHost(input);
    final target =
        sanitized.isNotEmpty ? sanitized : input.trim().toLowerCase();
    if (_hosts.remove(target)) {
      await _save();
      AdBlockerService.instance.refresh();
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefKeyHosts, _hosts.toList());
    } catch (e) {
      _log.warning('[CustomAdBlockStore] Failed to save hosts: $e');
    }
  }

  /// Checks if [host] or any of its parent domains are in the custom list.
  bool contains(String host) {
    if (host.isEmpty) return false;
    final lower = host.toLowerCase();

    if (_hosts.contains(lower)) return true;

    // Subdomain walk-up logic (reuse AdBlockFilterUpdater pattern)
    final parts = lower.split('.');
    for (var i = 1; i < parts.length - 1; i++) {
      final parent = parts.sublist(i).join('.');
      if (_hosts.contains(parent)) return true;
    }
    return false;
  }
}
