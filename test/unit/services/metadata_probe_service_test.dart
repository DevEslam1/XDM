import 'dart:io';

import 'package:dmx/core/services/dio_client_pool.dart';
import 'package:dmx/core/services/metadata_probe_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MetadataProbeService Tests', () {
    late DioClientPool pool;
    late MetadataProbeService service;

    setUp(() {
      pool = DioClientPool();
      service = MetadataProbeService(pool);
    });

    tearDown(() {
      pool.dispose();
    });

    test('resolveMetadata identifies torrent and resolves file metadata correctly', () async {
      final tempDir = await Directory.systemTemp.createTemp('meta_test_');
      final torrentFile = File('${tempDir.path}/test.torrent');
      await torrentFile.writeAsBytes([0x64, 0x34, 0x3a, 0x6e, 0x61, 0x6d, 0x65, 0x65]); // basic bytes

      final meta = await service.resolveMetadata(
        url: Uri.file(torrentFile.path).toString(),
        requestedFileName: 'my_torrent.torrent',
      );

      expect(meta, isNotNull);
      expect(meta.category, equals('Torrent'));
      expect(meta.supportsResume, isTrue);

      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('resolveMetadata handles generic torrent fallback gracefully', () async {
      final meta = await service.resolveMetadata(
        url: 'file:///non_existent_path/video.torrent',
      );

      expect(meta, isNotNull);
      expect(meta.fileName, equals('torrent_download.zip'));
      expect(meta.supportsResume, isTrue);
      expect(meta.fileSize, equals(0));
    });
  });
}
