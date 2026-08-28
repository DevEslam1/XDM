import 'dart:io';

/// Thrown when a request URL targets a scheme or host that is not allowed on
/// the download path (SSRF / cleartext guard).
class SsrfBlockedException implements Exception {
  const SsrfBlockedException(this.message, {this.url});
  final String message;
  final String? url;
  @override
  String toString() => 'SsrfBlockedException: $message';
}

/// Validates outbound download / metadata-probe URLs against an SSRF policy:
/// - scheme allowlist (http/https, or https-only when configured)
/// - block requests to loopback / link-local / private / CGNAT / multicast /
///   reserved IP literals, including the integer, hex and octal encodings that
///   bypass a naive dotted-quad check (e.g. `http://2130706433` == 127.0.0.1).
///
/// Non-IP hostnames are allowed: there is no synchronous DNS resolution here,
/// so DNS-rebinding is intentionally out of scope for this layer (the OS
/// resolver still applies, and the connection-time IP is what matters for the
/// well-known metadata endpoints this guard targets, e.g. 169.254.169.254).
class SsrfGuard {
  const SsrfGuard._();

  /// Validates [uri]. Throws [SsrfBlockedException] when disallowed.
  ///
  /// [allowPrivate] relaxes the policy for the *initial*, user-typed download
  /// URL so that LAN / loopback / private-range targets are permitted (matching
  /// 1DM/ADM/FDM, which let users download from their own NAS, router or a
  /// `localhost` dev server). Cloud-metadata / link-local (169.254/16),
  /// 0.0.0.0, and multicast/reserved ranges stay blocked even then, because
  /// those are never a legitimate download source. Redirect hops must keep the
  /// strict default (`allowPrivate: false`) so a remote server cannot pivot a
  /// download into the user's internal network via a 3xx.
  static void validate(Uri uri,
      {bool httpsOnly = false, bool allowPrivate = false}) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw SsrfBlockedException('Blocked non-web scheme "$scheme".',
          url: uri.toString());
    }
    if (httpsOnly && scheme == 'http') {
      throw SsrfBlockedException(
          'Blocked insecure http:// request (HTTPS-only is enabled).',
          url: uri.toString());
    }
    final host = uri.host;
    if (host.isEmpty) {
      throw SsrfBlockedException('Blocked request with empty host.',
          url: uri.toString());
    }
    if (isBlockedHost(host, allowPrivate: allowPrivate)) {
      throw SsrfBlockedException(
          'Blocked request to non-routable/internal host "$host".',
          url: uri.toString());
    }
  }

  /// True when [host] is an IP literal in a blocked range. Returns false for
  /// ordinary hostnames (which are not resolved here). When [allowPrivate] is
  /// true, private / loopback / CGNAT / unique-local ranges are permitted, but
  /// link-local (incl. 169.254/16 cloud metadata), multicast, reserved and
  /// 0.0.0.0 stay blocked.
  static bool isBlockedHost(String host, {bool allowPrivate = false}) {
    // Uri.host may keep the brackets around an IPv6 literal on some platforms.
    var h = host;
    if (h.startsWith('[') && h.endsWith(']')) {
      h = h.substring(1, h.length - 1);
    }
    final addr = _decodeIpv4Literal(h) ?? InternetAddress.tryParse(h);
    if (addr == null) return false; // hostname, not an IP literal
    // Link-local (169.254/16 + fe80::/10) and multicast are ALWAYS blocked —
    // they are never a legitimate download target, even in allowPrivate mode.
    if (addr.isLinkLocal || addr.isMulticast) return true;
    final raw = addr.rawAddress;
    if (addr.type == InternetAddressType.IPv4 && raw.length == 4) {
      return _isBlockedIpv4(raw, allowPrivate: allowPrivate);
    }
    if (addr.type == InternetAddressType.IPv6 && raw.length == 16) {
      // IPv6 loopback (::1) is private, not link-local, so gate it here.
      if (addr.isLoopback) return !allowPrivate;
      return _isBlockedIpv6(raw, allowPrivate: allowPrivate);
    }
    return false;
  }

  /// Decodes integer / hex / octal IPv4 encodings into an
  /// [InternetAddress]. Returns null for anything else.
  static InternetAddress? _decodeIpv4Literal(String host) {
    final h = host.trim();
    if (h.contains('.')) {
      final parts = h.split('.');
      if (parts.length == 4) {
        final bytes = <int>[];
        for (final p in parts) {
          int? v;
          if (p.startsWith('0x') || p.startsWith('0X')) {
            v = int.tryParse(p.substring(2), radix: 16);
          } else if (p.length > 1 && p.startsWith('0')) {
            v = int.tryParse(p, radix: 8);
          } else {
            v = int.tryParse(p);
          }
          if (v == null || v < 0 || v > 255) return null;
          bytes.add(v);
        }
        return InternetAddress.tryParse(
            '${bytes[0]}.${bytes[1]}.${bytes[2]}.${bytes[3]}');
      }
    }
    int? value;
    if (RegExp(r'^[0-9]+$').hasMatch(h)) {
      // A leading zero denotes octal (0177...), otherwise decimal.
      value = h.length > 1 && h.startsWith('0')
          ? int.tryParse(h, radix: 8)
          : int.tryParse(h);
    } else if (RegExp(r'^0[xX][0-9a-fA-F]+$').hasMatch(h)) {
      value = int.tryParse(h.substring(2), radix: 16);
    }
    if (value == null || value < 0 || value > 0xFFFFFFFF) return null;
    final b0 = (value >> 24) & 0xFF;
    final b1 = (value >> 16) & 0xFF;
    final b2 = (value >> 8) & 0xFF;
    final b3 = value & 0xFF;
    return InternetAddress.tryParse('$b0.$b1.$b2.$b3');
  }

  static bool _isBlockedIpv4(List<int> b, {required bool allowPrivate}) {
    final a = b[0];
    final c = b[1];
    // Always blocked — never a legitimate download target, even for a
    // user-typed initial URL.
    if (a == 0) return true; // 0.0.0.0/8 "this network"
    if (a == 169 && c == 254) {
      return true; // 169.254.0.0/16 link-local + metadata
    }
    if (a >= 224) return true; // 224/4 multicast, 240/4 reserved, 255 broadcast
    // Private / loopback / CGNAT — permitted only when the caller opted in
    // (the initial user-typed URL), blocked on redirect hops.
    if (allowPrivate) return false;
    if (a == 10) return true; // 10.0.0.0/8 private
    if (a == 127) return true; // 127.0.0.0/8 loopback
    if (a == 172 && c >= 16 && c <= 31) return true; // 172.16.0.0/12 private
    if (a == 192 && c == 168) return true; // 192.168.0.0/16 private
    if (a == 100 && c >= 64 && c <= 127) return true; // 100.64.0.0/10 CGNAT
    return false;
  }

  static bool _isBlockedIpv6(List<int> b, {required bool allowPrivate}) {
    // Block IPv6 unspecified address (:: / all zeros) - always blocked
    var allZero = true;
    for (var i = 0; i < 16; i++) {
      if (b[i] != 0) {
        allZero = false;
        break;
      }
    }
    if (allZero) return true;

    // IPv4-mapped (::ffff:a.b.c.d) — validate the embedded v4 address with the
    // same policy (this also enforces the always-blocked v4 ranges).
    var prefixZero = true;
    for (var i = 0; i < 10; i++) {
      if (b[i] != 0) {
        prefixZero = false;
        break;
      }
    }
    if (prefixZero && b[10] == 0xFF && b[11] == 0xFF) {
      return _isBlockedIpv4([b[12], b[13], b[14], b[15]],
          allowPrivate: allowPrivate);
    }
    if (allowPrivate) return false;
    // fc00::/7 unique-local (first 7 bits 1111 110x).
    if ((b[0] & 0xFE) == 0xFC) return true;
    return false; // loopback/link-local/multicast handled via address flags
  }
}
