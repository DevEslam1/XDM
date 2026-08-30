import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';

/// Regression tests for the torrent-resume-store fix batch
/// (B15 degraded round-trip, B22 meta merge, B23 tracked retry timer).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('torrent_store_fixbatch_');
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

  group('B15: degraded snapshot round-trip', () {
    test('save with null native blob → load returns bitfield/bytes', () async {
      const url = 'magnet:?xt=urn:btih:f15bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1';
      final saved = await TorrentResumeStore.saveAndWait(
        torrentId: 11,
        sourceUrl: url,
        // Simulates libtorrent_flutter 1.9.2: the native bridge returns null.
        fetchResumeData: () async => null,
        files: [
          {
            'name': 'a.bin',
            'length': 1000,
            'downloadedBytes': 0,
            'selected': true,
            'priority': 4,
          },
          {
            'name': 'b.bin',
            'length': 1000,
            'downloadedBytes': 0,
            'selected': true,
            'priority': 4,
          },
        ],
        pieceBitfield: [true, true, false, false],
        piecesTotal: 4,
        piecesDone: 2,
        degradedFallback: true,
      );
      expect(saved, isTrue);

      // The native-blob load path must stay null — no blob was written and
      // the degraded meta must not masquerade as one.
      expect(await TorrentResumeStore.loadResumeDataForSource(url), isNull);

      // But the degraded snapshot must be readable, with the stored bitfield
      // and a usable byte total.
      final snap = await TorrentResumeStore.loadDegradedSnapshotForSource(url);
      expect(snap, isNotNull);
      expect(snap!.piecesBitfield, [true, true, false, false]);
      expect(snap.piecesDone, 2);
      expect(snap.piecesTotal, 4);
      // 2 of 4 pieces across 2000 wanted bytes → 1000 bytes claimed.
      expect(snap.downloadedBytes, 1000);
      expect(snap.files, hasLength(2));

      await TorrentResumeStore.delete(11);
    });

    test('load returns null for sources without a degraded snapshot',
        () async {
      const url = 'magnet:?xt=urn:btih:f15bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2';
      expect(await TorrentResumeStore.loadDegradedSnapshotForSource(url),
          isNull);
    });

    test('native-blob saves are not exposed as degraded snapshots', () async {
      const url = 'magnet:?xt=urn:btih:f15bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb3';
      await TorrentResumeStore.saveAndWait(
        torrentId: 12,
        sourceUrl: url,
        fetchResumeData: () => Uint8List.fromList([1, 2, 3]),
      );
      expect(await TorrentResumeStore.loadDegradedSnapshotForSource(url),
          isNull);
      expect(await TorrentResumeStore.loadResumeDataForSource(url), isNotNull);
      await TorrentResumeStore.delete(12);
    });
  });

  group('B22: saveMetadataSnapshot merges with existing meta', () {
    test('preserves sha256-era state (bitfield/pieces) and refreshes files',
        () async {
      const url = 'magnet:?xt=urn:btih:f22bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1';
      await TorrentResumeStore.saveAndWait(
        torrentId: 21,
        sourceUrl: url,
        fetchResumeData: () async => null,
        files: [
          {
            'name': 'old.bin',
            'length': 100,
            'downloadedBytes': 0,
            'selected': true,
          }
        ],
        pieceBitfield: [true, false],
        piecesTotal: 2,
        piecesDone: 1,
        degradedFallback: true,
      );
      var snap = await TorrentResumeStore.loadDegradedSnapshotForSource(url);
      expect(snap, isNotNull);
      expect(snap!.piecesBitfield, [true, false]);

      // The metadata probe saves a fresh file snapshot — it must MERGE with
      // the existing meta, not clobber the piece state saved next to it.
      final ok = await TorrentResumeStore.saveMetadataSnapshot(
        sourceUrl: url,
        files: [
          {
            'name': 'new.bin',
            'length': 200,
            'downloadedBytes': 0,
            'selected': true,
          }
        ],
        name: 'New name',
      );
      expect(ok, isTrue);

      snap = await TorrentResumeStore.loadDegradedSnapshotForSource(url);
      expect(snap, isNotNull,
          reason: 'piecesBitfield must survive a metadata snapshot save');
      expect(snap!.piecesBitfield, [true, false]);

      final files = await TorrentResumeStore.loadFilesForSource(url);
      expect(files, isNotNull);
      expect(files!.first['name'], 'new.bin',
          reason: 'the fresh file snapshot must be stored');

      await TorrentResumeStore.delete(21);
    });
  });

  group('B23: saveAll retry timer is tracked', () {
    test('cancelPendingSaves stops the scheduled retry from writing',
        () async {
      const url = 'magnet:?xt=urn:btih:f23bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1';
      TorrentResumeStore.registerSource(77, url);

      var progressCalls = 0;
      Uint8List progressFor(int id) {
        progressCalls++;
        return Uint8List.fromList([1, 2, 3]);
      }

      // filesFor throws while building the save argument → saveAll's catch
      // schedules the 5s retry. (saveAndWait itself never throws, so this is
      // the path that reaches the retry.)
      await TorrentResumeStore.saveAll(
        [77],
        progressFor,
        (id) => throw StateError('boom'),
      );

      // Dispose semantics: pending saves must not write afterwards.
      TorrentResumeStore.cancelPendingSaves();

      // The retry fires at 5s — give it ample time to prove it never did.
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(progressCalls, 0,
          reason: 'the retry timer must be cancelled with pending saves');

      await TorrentResumeStore.delete(77);
    });
  });
}
