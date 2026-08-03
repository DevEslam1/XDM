import 'dart:io';
import '../features/settings/provider/settings_provider.dart';
import 'services/doh_resolver.dart';

/// Globally overrides HttpClient behavior to support DNS-over-HTTPS.
class DohHttpOverrides extends HttpOverrides {
  final SettingsProvider settings;

  DohHttpOverrides(this.settings);

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
      if (settings.dnsEnabled) {
        // Attempt DoH resolution
        final resolved = await DohResolver.instance.resolve(host, settings.dnsProvider);
        if (resolved != null) {
          host = resolved;
        }
      }
      
      // Connect to the host (IP if resolved, hostname if not - triggering system DNS fallback)
      return Socket.startConnect(host, uri.port);
    };
    
    return client;
  }
}
