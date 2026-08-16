import 'dart:convert';
import 'dart:typed_data';

import 'package:dmx/core/services/torrent_models.dart';
import 'package:dmx/core/services/torrent_session_config.dart';
import 'package:dmx/core/utils/bencode_decoder.dart';
import 'package:dmx/core/utils/url_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';


void main() {
  group('BitTorrent v2 and Hybrid Metadata Parsing', () {
    test('parses BitTorrent v2 file tree and calculates SHA-256 hash', () {
      const mockTreeInfo =
          'd4:infod9:file treed8:test.txtd0:d6:lengthi500e11:pieces root32:01234567890123456789012345678901eee12:meta versioni2e4:name8:test.txtee';
      final bytes = Uint8List.fromList(utf8.encode(mockTreeInfo));

      final parsed = BencodeDecoder.parseTorrentBytes(bytes);
      expect(parsed, isNotNull);
      expect(parsed!['name'], 'test.txt');
      expect(parsed['length'], 500);
      expect(parsed['files'], isNotEmpty);
      final hashV2 = parsed['infoHashV2'] as String?;
      expect(hashV2, isNotNull);
      expect(hashV2!.length, 64);
    });


    test('extracts both BTIH (v1) and BTMH (v2) from Hybrid magnet URI', () {
      const magnet =
          'magnet:?xt=urn:btih:1111111111111111111111111111111111111111&xt=urn:btmh:12202222222222222222222222222222222222222222222222222222222222222222&dn=Ubuntu+Hybrid';
      final parsed = parseMagnetUrl(magnet);

      expect(parsed['name'], 'Ubuntu Hybrid');
      expect(parsed['infoHashV1'], '1111111111111111111111111111111111111111');
      expect(parsed['infoHashV2'], '2222222222222222222222222222222222222222222222222222222222222222');
      expect(parsed['isHybrid'], 'true');
    });

    test('extracts standard v1 magnet URI with BTIH', () {
      const magnet = 'magnet:?xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709&dn=Test';
      final parsed = parseMagnetUrl(magnet);

      expect(parsed['name'], 'Test');
      expect(parsed['infoHash'], 'DA39A3EE5E6B4B0D3255BFEF95601890AFD80709');
      expect(parsed['isV1Only'], 'true');
    });
  });

  group('TorrentSettingsPack and BtConfig mapping', () {
    test('builds BtConfig with SOCKS5 proxy and protocol switches', () {
      const pack = TorrentSettingsPack(
        enableDht: true,
        enableLsd: false,
        enablePex: true,
        enableUpnp: true,
        maxConnectionsGlobal: 300,
        maxDownloadRate: 1048576,
        maxUploadRate: 524288,
        forceEncrypt: true,
        enableUtp: true,
        socks5ProxyHost: '127.0.0.1',
        socks5ProxyPort: 9050,
        enforceProxy: true,
        cacheSize: 1073741824,
      );

      const baseConfig = BtConfig();
      final btConfig =
          TorrentSessionConfig.buildBtConfigFromPack(pack, baseConfig: baseConfig);


      expect(btConfig.disableDht, isFalse);
      expect(btConfig.disableUpnp, isFalse);
      expect(btConfig.disableUtp, isFalse);
      expect(btConfig.forceEncrypt, isTrue);
      expect(btConfig.connectionsLimit, 300);
      expect(btConfig.downloadRateLimit, 1024);
      expect(btConfig.uploadRateLimit, 512);
      expect(btConfig.cacheSize, 1073741824);
    });


    test('validates TorrentSettingsPack direct construction', () {
      const pack = TorrentSettingsPack(
        enableDht: true,
        enableLsd: true,
        enablePex: true,
        enableUpnp: true,
        maxConnectionsGlobal: 250,
        maxDownloadRate: 200000,
        maxUploadRate: 100000,
        forceEncrypt: false,
        enableUtp: true,
        socks5ProxyHost: 'proxy.dmx.io',
        socks5ProxyPort: 1080,
        enforceProxy: false,
        cacheSize: 536870912,
      );

      expect(pack.enableDht, isTrue);
      expect(pack.maxConnectionsGlobal, 250);
      expect(pack.socks5ProxyHost, 'proxy.dmx.io');
      expect(pack.socks5ProxyPort, 1080);
      expect(pack.cacheSize, 512 * 1024 * 1024);
    });
  });

  group('TorrentAlertEvent Model', () {
    test('creates alert model with category and timestamp', () {
      final alert = TorrentAlertEvent(
        type: 1,
        torrentId: 42,
        message: 'Piece 10 downloaded',
        timestamp: DateTime.now(),
        category: 'download',
      );

      expect(alert.type, 1);
      expect(alert.torrentId, 42);
      expect(alert.message, 'Piece 10 downloaded');
      expect(alert.category, 'download');
    });
  });
}

