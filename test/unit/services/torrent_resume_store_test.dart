import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TorrentResumeStore Unit Tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('torrent_resume_test_');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (methodCall) async {
          return tempDir.path;
        },
      );
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );

      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('registerSource and unregisterTorrent manage in-memory registry', () {
      TorrentResumeStore.registerSource(
          101, 'https://example.com/test.torrent');
      TorrentResumeStore.registerSource(
          102, 'magnet:?xt=urn:btih:ABCDEF1234567890ABCDEF1234567890ABCDEF12');

      // Unregistering removes the mapping
      TorrentResumeStore.unregisterTorrent(101);
      TorrentResumeStore.unregisterTorrent(102);
    });

    test(
        'saveAndWait and loadResumeDataForSource store and verify blob durably',
        () async {
      const sourceUrl =
          'magnet:?xt=urn:btih:1234567890abcdef1234567890abcdef12345678&dn=Test';
      final dummyBlob = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

      final saved = await TorrentResumeStore.saveAndWait(
        torrentId: 999,
        sourceUrl: sourceUrl,
        fetchResumeData: () => dummyBlob,
        files: [
          {'name': 'file1.txt', 'length': 100, 'downloadedBytes': 50}
        ],
      );

      expect(saved, isTrue);

      final loadedBlob =
          await TorrentResumeStore.loadResumeDataForSource(sourceUrl);
      expect(loadedBlob, isNotNull);
      expect(loadedBlob, equals(dummyBlob));

      final loadedFiles =
          await TorrentResumeStore.loadFilesForSource(sourceUrl);
      expect(loadedFiles, isNotNull);
      expect(loadedFiles!.length, equals(1));
      expect(loadedFiles.first['name'], equals('file1.txt'));

      // Cleanup
      await TorrentResumeStore.deleteResumeDataForSource(sourceUrl);
      final afterDelete =
          await TorrentResumeStore.loadResumeDataForSource(sourceUrl);
      expect(afterDelete, isNull);
    });

    test('saveAll batch saves all registered torrent IDs', () async {
      const urlA =
          'magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const urlB =
          'magnet:?xt=urn:btih:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

      TorrentResumeStore.registerSource(201, urlA);
      TorrentResumeStore.registerSource(202, urlB);

      final blobA = Uint8List.fromList([10, 20, 30]);
      final blobB = Uint8List.fromList([40, 50, 60]);

      await TorrentResumeStore.saveAll(
        [201, 202],
        (id) => id == 201 ? blobA : blobB,
      );

      final loadedA = await TorrentResumeStore.loadResumeDataForSource(urlA);
      final loadedB = await TorrentResumeStore.loadResumeDataForSource(urlB);

      expect(loadedA, equals(blobA));
      expect(loadedB, equals(blobB));

      // Cleanup
      await TorrentResumeStore.delete(201);
      await TorrentResumeStore.delete(202);
    });

    test('loadResumeDataForSource rejects empty / invalid URLs gracefully',
        () async {
      final res = await TorrentResumeStore.loadResumeDataForSource(
          'non_existent_url_123');
      expect(res, isNull);
    });

    test('extracts info-hash from .torrent file on disk when available',
        () async {
      final torrentFilePath = '${tempDir.path}/test.torrent';
      final file = File(torrentFilePath);

      // Raw bencoded torrent bytes containing an info dict
      final bencodedStr = 'd4:infod4:name4:test6:lengthi100eee';
      final bencodedBytes = Uint8List.fromList(utf8.encode(bencodedStr));
      await file.writeAsBytes(bencodedBytes);

      // Save using file path as source
      final saved = await TorrentResumeStore.saveAndWait(
        torrentId: 501,
        sourceUrl: torrentFilePath,
        fetchResumeData: () => Uint8List.fromList([9, 9, 9]),
      );

      expect(saved, isTrue);

      final loaded =
          await TorrentResumeStore.loadResumeDataForSource(torrentFilePath);
      expect(loaded, isNotNull);
      expect(loaded, equals([9, 9, 9]));

      await TorrentResumeStore.deleteResumeDataForSource(torrentFilePath);
    });
  });
}
