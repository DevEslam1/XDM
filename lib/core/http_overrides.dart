import 'dart:io';
import 'package:flutter/foundation.dart';
import '../features/settings/provider/settings_provider.dart';
import 'services/doh_resolver.dart';

/// Globally overrides HttpClient behavior to support DNS-over-HTTPS.
class DohHttpOverrides extends HttpOverrides {
  final bool Function() _dnsEnabled;
  final String Function() _dnsProvider;

  DohHttpOverrides(SettingsProvider settings)
      : this._(() => settings.dnsEnabled, () => settings.dnsProvider);

  DohHttpOverrides.fromValues({
    required bool dnsEnabled,
    required String dnsProvider,
  }) : this._(() => dnsEnabled, () => dnsProvider);

  DohHttpOverrides._(this._dnsEnabled, this._dnsProvider);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    
    // Override connection factory to inject DoH resolution
    client.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
      // If a proxy is active, we must connect to the proxy and let it handle resolution
      if (proxyHost != null) {
        return Socket.startConnect(proxyHost, proxyPort!);
      }

      if (_dnsEnabled()) {
        try {
          // 1. Fast system DNS lookup (preserves CDN geo-routing & native ALPN)
          final addresses = await InternetAddress.lookup(uri.host)
              .timeout(const Duration(seconds: 2));
          if (addresses.isNotEmpty) {
            return Socket.startConnect(addresses.first, uri.port);
          }
        } catch (_) {
          // 2. System DNS failed (e.g. ISP censorship / DNS blocking) -> Fallback to DoH
          final resolved = await DohResolver.instance.resolve(uri.host, _dnsProvider());
          if (resolved != null) {
            debugPrint('[DMX DoH Fallback] ${uri.host} -> $resolved via ${_dnsProvider()}');
            try {
              final ipAddress = InternetAddress(resolved);
              return Socket.startConnect(ipAddress, uri.port);
            } catch (_) {}
          }
        }
      }
      
      // Connect to the host using hostname (triggering system DNS fallback)
      return Socket.startConnect(uri.host, uri.port);
    };
    
    return client;
  }
}
