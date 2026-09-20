// FIX-P2-03: Torrent settings mixin for SettingsProvider
// FIX(S3): The shadowed backing fields (globalTorrentSeeding, enableDht,
// enablePex, queueTorrents, maxActiveTorrents) were removed — SettingsProvider
// declares the single source of truth for them.
import 'package:flutter/foundation.dart';

mixin TorrentSettingsMixin on ChangeNotifier {
  String? get proxyHost;
  int? get proxyPort;
  String? get proxyType;
  String? get proxyUsername;
  String? get proxyPassword;
  String? get sslCertPath;
  String? get sslKeyPath;
  String? get sslDhParamsPath;
  bool get isSslActive;

  Future<void> setProxySettings({
    required String host,
    required int port,
    required dynamic type,
    String? username,
    String? password,
  });

  Future<void> setSslSettings({
    required String certPath,
    required String privateKeyPath,
    String? dhParamsPath,
  });
}
