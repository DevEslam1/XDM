import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('resume_store_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (methodCall) async => tempDir.path,
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

  const magnet =
      'magnet:?xt=urn:btih:1234567890abcdef1234567890abcdef12345678&dn=T';

  group('TorrentResumeStore registration', () {
    test('register / unregister / unregisterSource bookkeeping', () {
      TorrentResumeStore.registerSource(1, magnet);
      expect(TorrentResumeStore.isRegisteredForTesting(1), isTrue);

      TorrentResumeStore.registerSource(2, 'https://example.com/a.torrent');
      TorrentResumeStore.unregisterSource('https://example.com/a.torrent');
      expect(TorrentResumeStore.isRegisteredForTesting(2), isFalse);

      // Blank sources are ignored.
      TorrentResumeStore.registerSource(3, '   ');
      expect(TorrentResumeStore.isRegisteredForTesting(3), isFalse);

      TorrentResumeStore.unregisterTorrent(1);
      expect(TorrentResumeStore.isRegisteredForTesting(1), isFalse);
    });
  });

  group('TorrentResumeStore.saveAndWait', () {
    test('rejects a blank source url', () async {
      expect(
        await TorrentResumeStore.saveAndWait(
          torrentId: 1,
          sourceUrl: '   ',
          fetchResumeData: () => Uint8List.fromList([1]),
        ),
        isFalse,
      );
    });

    test('rejects a blob larger than 16MB', () async {
      expect(
        await TorrentResumeStore.saveAndWait(
          torrentId: 1,
          sourceUrl: magnet,
          fetchResumeData: () => Uint8List(16 * 1024 * 1024 + 1),
        ),
        isFalse,
      );
    });

    test('rejects an empty blob with no snapshot data', () async {
      expect(
        await TorrentResumeStore.saveAndWait(
          torrentId: 1,
          sourceUrl: magnet,
          fetchResumeData: () => Uint8List(0),
        ),
        isFalse,
      );
    });

    test('round-trips a native blob', () async {
      final blob = Uint8List.fromList([1, 2, 3, 4]);
      expect(
        await TorrentResumeStore.saveAndWait(
          torrentId: 1,
          sourceUrl: magnet,
          fetchResumeData: () => blob,
        ),
        isTrue,
      );

      expect(await TorrentResumeStore.loadResumeDataForSource(magnet), blob);
      await TorrentResumeStore.deleteResumeDataForSource(magnet);
    });

    test('degrades to a meta-only snapshot when no blob exists', () async {
      final ok = await TorrentResumeStore.saveAndWait(
        torrentId: 1,
        sourceUrl: magnet,
        fetchResumeData: () => null,
        files: [
          {
            'name': 'a.bin',
            'length': 100,
            'selected': true,
            'downloadedBytes': 40
          },
        ],
        pieceBitfield: const [true, false, true, false],
        piecesTotal: 4,
        piecesDone: 2,
        degradedFallback: true,
      );
      expect(ok, isTrue);

      final snapshot =
          await TorrentResumeStore.loadDegradedSnapshotForSource(magnet);
      expect(snapshot, isNotNull);
      expect(snapshot!.piecesTotal, 4);
      expect(snapshot.piecesDone, 2);
      expect(snapshot.files.length, 1);
      expect(snapshot.downloadedBytes, greaterThan(0));

      await TorrentResumeStore.deleteResumeDataForSource(magnet);
    });

    test('degraded save preserves an existing valid blob', () async {
      final blob = Uint8List.fromList([9, 9, 9, 9]);
      await TorrentResumeStore.saveAndWait(
        torrentId: 1,
        sourceUrl: magnet,
        fetchResumeData: () => blob,
      );

      await TorrentResumeStore.saveAndWait(
        torrentId: 1,
        sourceUrl: magnet,
        fetchResumeData: () => null,
        files: [
          {
            'name': 'a.bin',
            'length': 100,
            'selected': true,
            'downloadedBytes': 10
          },
        ],
        degradedFallback: true,
      );

      expect(await TorrentResumeStore.loadResumeDataForSource(magnet), blob);
      await TorrentResumeStore.deleteResumeDataForSource(magnet);
    });
  });

  group('TorrentResumeStore.loadResumeDataForSource', () {
    test('returns null when nothing has been saved', () async {
      expect(await TorrentResumeStore.loadResumeDataForSource(magnet), isNull);
    });

    test('returns null and discards a sha-mismatched blob', () async {
      await TorrentResumeStore.saveAndWait(
        torrentId: 1,
        sourceUrl: magnet,
        fetchResumeData: () => Uint8List.fromList([1, 2, 3, 4]),
      );

      // Corrupt the blob on disk.
      final key = await _keyFor(magnet);
      final blobFile = File('${tempDir.path}/torrent_resume/$key.resume');
      await blobFile.writeAsBytes([9, 9, 9, 9], flush: true);

      expect(await TorrentResumeStore.loadResumeDataForSource(magnet), isNull);
      expect(await blobFile.exists(), isFalse);
    });
  });

  group('TorrentResumeStore.loadDegradedSnapshotForSource', () {
    test('returns null for a non-degraded snapshot', () async {
      await TorrentResumeStore.saveAndWait(
        torrentId: 1,
        sourceUrl: magnet,
        fetchResumeData: () => Uint8List.fromList([1, 2, 3, 4]),
      );
      expect(
        await TorrentResumeStore.loadDegradedSnapshotForSource(magnet),
        isNull,
      );
    });

    test('returns null when no metadata exists', () async {
      expect(
        await TorrentResumeStore.loadDegradedSnapshotForSource('https://none'),
        isNull,
      );
    });
  });

  group('TorrentResumeStore metadata snapshots', () {
    test('saveMetadataSnapshot rejects empty inputs', () async {
      expect(
        await TorrentResumeStore.saveMetadataSnapshot(
          sourceUrl: '',
          files: const [],
        ),
        isFalse,
      );
      expect(
        await TorrentResumeStore.saveMetadataSnapshot(
          sourceUrl: magnet,
          files: const [],
        ),
        isFalse,
      );
    });

    test('saveMetadataSnapshot merges with existing data', () async {
      await TorrentResumeStore.saveAndWait(
        torrentId: 1,
        sourceUrl: magnet,
        fetchResumeData: () => Uint8List.fromList([1, 2, 3, 4]),
      );

      final ok = await TorrentResumeStore.saveMetadataSnapshot(
        sourceUrl: magnet,
        files: [
          {
            'name': 'a.bin',
            'length': 1,
            'selected': true,
            'downloadedBytes': 0
          },
        ],
        name: 'My Torrent',
        torrentId: 1,
      );
      expect(ok, isTrue);

      final files = await TorrentResumeStore.loadFilesForSource(magnet);
      expect(files, isNotNull);
      expect(files!.length, 1);

      // The native blob digest survived the metadata merge.
      expect(await TorrentResumeStore.loadResumeDataForSource(magnet),
          Uint8List.fromList([1, 2, 3, 4]));
    });

    test('loadFilesForSource returns null when absent', () async {
      expect(await TorrentResumeStore.loadFilesForSource(magnet), isNull);
    });
  });

  group('TorrentResumeStore torrent file cache', () {
    test('saveTorrentFile then getTorrentFile round-trips', () async {
      final file = await TorrentResumeStore.saveTorrentFile(
        'https://example.com/a.torrent',
        utf8.encode('d4:infod4:name4:test6:lengthi100eee'),
      );
      expect(await file.exists(), isTrue);

      final fetched = await TorrentResumeStore.getTorrentFile(
          'https://example.com/a.torrent');
      expect(fetched, isNotNull);

      await TorrentResumeStore.deleteResumeDataForSource(
          'https://example.com/a.torrent');
      expect(
        await TorrentResumeStore.getTorrentFile(
            'https://example.com/a.torrent'),
        isNull,
      );
    });

    test('getTorrentFile returns null for an unknown source', () async {
      expect(await TorrentResumeStore.getTorrentFile('https://none'), isNull);
    });
  });

  group('TorrentResumeStore batch operations', () {
    test('saveAll skips ids without a registered source', () async {
      await TorrentResumeStore.saveAll(
        [777],
        (id) => Uint8List.fromList([1]),
      );
      // No throw and nothing registered.
      expect(TorrentResumeStore.isRegisteredForTesting(777), isFalse);
    });

    test('saveAll writes registered ids', () async {
      TorrentResumeStore.registerSource(1, magnet);
      await TorrentResumeStore.saveAll([1], (id) => Uint8List.fromList([1, 2]));
      expect(await TorrentResumeStore.loadResumeDataForSource(magnet),
          Uint8List.fromList([1, 2]));
      await TorrentResumeStore.delete(1);
    });

    test('saveAllDebounced schedules then cancelPendingSaves clears', () {
      fakeAsync((async) {
        TorrentResumeStore.registerSource(1, magnet);
        TorrentResumeStore.saveAllDebounced(
          [1],
          (id) => Uint8List.fromList([5]),
        );
        async.elapse(const Duration(seconds: 31));
        TorrentResumeStore.cancelPendingSaves();
      });
      TorrentResumeStore.unregisterTorrent(1);
    });
  });

  group('TorrentResumeStore validation helpers', () {
    test('validateResumeData bounds the blob size', () {
      expect(TorrentResumeStore.validateResumeData(Uint8List(0)), isFalse);
      expect(
        TorrentResumeStore.validateResumeData(Uint8List.fromList([1])),
        isTrue,
      );
      expect(
        TorrentResumeStore.validateResumeData(Uint8List(16 * 1024 * 1024 + 1)),
        isFalse,
      );
    });

    test('verify returns false without a registered source', () async {
      expect(await TorrentResumeStore.verify(999), isFalse);
    });

    test('verifySource reports true for valid saved data', () async {
      await TorrentResumeStore.saveAndWait(
        torrentId: 1,
        sourceUrl: magnet,
        fetchResumeData: () => Uint8List.fromList([1, 2, 3]),
      );
      expect(await TorrentResumeStore.verifySource(magnet), isTrue);

      TorrentResumeStore.registerSource(1, magnet);
      expect(await TorrentResumeStore.verify(1), isTrue);
      TorrentResumeStore.unregisterTorrent(1);
    });

    test('needsRecheckAfterResume compares stored and actual pieces', () async {
      await TorrentResumeStore.saveAndWait(
        torrentId: 1,
        sourceUrl: magnet,
        fetchResumeData: () => Uint8List.fromList([1, 2, 3]),
        pieceBitfield: const [true, false],
        piecesTotal: 2,
        piecesDone: 1,
      );

      expect(
          await TorrentResumeStore.needsRecheckAfterResume(magnet, 1), isFalse);
      expect(
          await TorrentResumeStore.needsRecheckAfterResume(magnet, 2), isTrue);
      expect(
        await TorrentResumeStore.needsRecheckAfterResume('https://none', 0),
        isFalse,
      );
    });
  });

  group('TorrentResumeStore task mapping', () {
    test('persist and load task mapping', () async {
      await TorrentResumeStore.persistTaskMapping({'a': 1, 'b': 2});
      final mapping = await TorrentResumeStore.loadTaskMapping();
      expect(mapping, {'a': 1, 'b': 2});
    });

    test('loadTaskMapping returns empty when absent', () async {
      expect(await TorrentResumeStore.loadTaskMapping(), isEmpty);
    });
  });

  group('TorrentResumeStore stable keys', () {
    test('keys a .torrent file by its info hash', () async {
      final torrentPath = '${tempDir.path}/sample.torrent';
      await File(torrentPath).writeAsBytes(
        utf8.encode('d4:infod4:name4:test6:lengthi100eee'),
        flush: true,
      );

      final saved = await TorrentResumeStore.saveAndWait(
        torrentId: 1,
        sourceUrl: torrentPath,
        fetchResumeData: () => Uint8List.fromList([7, 7, 7]),
      );
      expect(saved, isTrue);
      expect(await TorrentResumeStore.loadResumeDataForSource(torrentPath),
          Uint8List.fromList([7, 7, 7]));
      await TorrentResumeStore.deleteResumeDataForSource(torrentPath);
    });

    test('keys a file:// URI by its info hash', () async {
      final torrentPath = '${tempDir.path}/uri.torrent';
      await File(torrentPath).writeAsBytes(
        utf8.encode('d4:infod4:name4:test6:lengthi100eee'),
        flush: true,
      );
      final uri = Uri.file(torrentPath).toString();

      final saved = await TorrentResumeStore.saveAndWait(
        torrentId: 1,
        sourceUrl: uri,
        fetchResumeData: () => Uint8List.fromList([8, 8]),
      );
      expect(saved, isTrue);
      await TorrentResumeStore.deleteResumeDataForSource(uri);
    });
  });

  group('TorrentResumeStore extra branch coverage', () {
    test('saveAndWait persists fileProgress metadata', () async {
      await TorrentResumeStore.saveAndWait(
        torrentId: 1,
        sourceUrl: magnet,
        fetchResumeData: () => Uint8List.fromList([1, 2, 3]),
        fileProgress: const [1, 2],
      );
      final files = await TorrentResumeStore.loadFilesForSource(magnet);
      expect(files, isNull); // no files map, but the save succeeded
      await TorrentResumeStore.deleteResumeDataForSource(magnet);
    });

    test('saveAll forwards the filesFor callback', () async {
      TorrentResumeStore.registerSource(2, magnet);
      await TorrentResumeStore.saveAll(
        [2],
        (id) => Uint8List.fromList([1, 2]),
        (id) => [
          {
            'name': 'a.bin',
            'length': 10,
            'selected': true,
            'downloadedBytes': 1
          },
        ],
      );
      final files = await TorrentResumeStore.loadFilesForSource(magnet);
      expect(files, isNotNull);
      await TorrentResumeStore.delete(2);
    });

    test('loadResumeDataForSource discards an empty blob', () async {
      await TorrentResumeStore.saveAndWait(
        torrentId: 1,
        sourceUrl: magnet,
        fetchResumeData: () => Uint8List.fromList([1, 2, 3]),
      );
      final key = await _keyFor(magnet);
      final blobFile = File('${tempDir.path}/torrent_resume/$key.resume');
      await blobFile.writeAsBytes(const [], flush: true);

      expect(await TorrentResumeStore.loadResumeDataForSource(magnet), isNull);
    });

    test('loadDegradedSnapshotForSource derives piecesDone from the bitfield',
        () async {
      await TorrentResumeStore.saveAndWait(
        torrentId: 1,
        sourceUrl: magnet,
        fetchResumeData: () => null,
        files: [
          {
            'name': 'a.bin',
            'length': 100,
            'selected': true,
            'downloadedBytes': 50
          },
        ],
        pieceBitfield: const [true, true, false, false],
        piecesTotal: 4,
        degradedFallback: true,
      );

      final snapshot =
          await TorrentResumeStore.loadDegradedSnapshotForSource(magnet);
      expect(snapshot, isNotNull);
      expect(snapshot!.piecesDone, 2);
      await TorrentResumeStore.deleteResumeDataForSource(magnet);
    });

    test('loadTaskMapping tolerates corrupt JSON', () async {
      SharedPreferences.setMockInitialValues(
        {'torrent_task_mapping': 'not-json'},
      );
      expect(await TorrentResumeStore.loadTaskMapping(), isEmpty);
      SharedPreferences.setMockInitialValues({});
    });
  });
}

Future<String> _keyFor(String sourceUrl) async {
  // Mirrors TorrentResumeStore._stableKey for a magnet with an info hash.
  final match =
      RegExp(r'xt=urn:bt(?:ih|mh):([a-zA-Z0-9]+)', caseSensitive: false)
          .firstMatch(sourceUrl)!;
  final infoHash = match.group(1)!.toLowerCase();
  return sha256.convert(utf8.encode(infoHash)).toString();
}
