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

      String host = uri.host;
      if (_dnsEnabled()) {
        // Attempt DoH resolution
        final resolved = await DohResolver.instance.resolve(host, _dnsProvider());
        if (resolved != null) {
          host = resolved;
          debugPrint('[DMX DoH] ${uri.host} -> $host via ${_dnsProvider()}');
        }
      }
      
      // Connect to the host (IP if resolved, hostname if not - triggering system DNS fallback)
      return Socket.startConnect(host, uri.port);
    };
    
    return client;
  }
}
