import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dmx/core/interfaces/i_torrent_native.dart';
import 'package:dmx/core/services/torrent/libtorrent_native_impl.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';
import 'package:dmx/core/services/torrent_service_ffi.dart';
import 'package:dmx/core/utils/bencode_decoder.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libtorrent_dart/libtorrent_dart.dart' as lt;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _deterministicBytes(int length, int seed) {
  final out = Uint8List(length);
  var state = seed & 0x7fffffff;
  for (var i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    out[i] = (state >> 16) & 0xff;
  }
  return out;
}

String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

Uint8List _compactPeerResponse(int port) {
  final payload = BytesBuilder()
    ..add(utf8.encode('d8:intervali5e5:peers6:'))
    ..add([127, 0, 0, 1, (port >> 8) & 0xff, port & 0xff])
    ..add(utf8.encode('e'));
  return payload.toBytes();
}

Future<T> _pollUntil<T>(
  FutureOr<T?> Function() probe, {
  Duration timeout = const Duration(seconds: 30),
  Duration interval = const Duration(milliseconds: 100),
  String reason = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final result = await probe();
    if (result != null) return result;
    await Future<void>.delayed(interval);
  }
  throw TimeoutException('Timed out waiting for $reason after $timeout');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late Directory supportDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempRoot = await Directory.systemTemp.createTemp('dmx_real_torrent_e2e_');
    supportDir = Directory(p.join(tempRoot.path, 'app_support'))
      ..createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => supportDir.path,
    );
  });

  tearDown(() async {
    try {
      await TorrentService.dispose();
    } catch (_) {}
    TorrentService.setNativeForTesting(LibtorrentNativeImpl());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (await tempRoot.exists()) {
      try {
        await tempRoot.delete(recursive: true);
      } catch (_) {}
    }
  });

  test(
    'TorrentResumeStore normalizes Base32/hex infoHash and migrates links losslessly',
    () async {
      // Standard 32-char Base32 encoding of 20 bytes 0x00..0x13:
      // hex: 000102030405060708090a0b0c0d0e0f10111213
      const hexHash = '000102030405060708090a0b0c0d0e0f10111213';
      const base32Hash = 'AAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQT';
      expect(TorrentResumeStore.normalizeInfoHash(base32Hash), equals(hexHash));
      expect(
        TorrentResumeStore.extractCanonicalInfoHash(
          'magnet:?xt=urn:btih:$base32Hash&dn=Base32Test',
        ),
        equals(hexHash),
      );

      const oldUrl = 'https://mirror-a.example.org/pack.torrent';
      const newUrl = 'https://mirror-b.example.org/pack.torrent';
      await TorrentResumeStore.registerInfoHash(oldUrl, hexHash);
      final saved = await TorrentResumeStore.saveAndWait(
        torrentId: 7,
        sourceUrl: oldUrl,
        infoHash: hexHash,
        fetchResumeData: () => Uint8List.fromList([1, 2, 3, 4, 5]),
        files: [
          {
            'name': 'keep.bin',
            'length': 1000,
            'selected': true,
            'priority': 4,
            'downloadedBytes': 400,
          },
          {
            'name': 'skip.bin',
            'length': 5000,
            'selected': false,
            'priority': 0,
            'downloadedBytes': 0,
          },
        ],
      );
      expect(saved, isTrue);

      final migrated = await TorrentResumeStore.migrateSourceKey(
        oldUrl,
        newUrl,
        infoHash: hexHash,
      );
      expect(migrated, isTrue);

      final blob = await TorrentResumeStore.loadResumeDataForSource(
        newUrl,
        infoHash: hexHash,
      );
      expect(blob, equals(Uint8List.fromList([1, 2, 3, 4, 5])));

      final snap = await TorrentResumeStore.loadTaskReconciliationSnapshot(
        newUrl,
        infoHash: hexHash,
      );
      expect(snap, isNotNull);
      expect(snap!.selectedTotalBytes, equals(1000));
      expect(snap.selectedDownloadedBytes, equals(400));
      expect(snap.hasNativeResumeBlob, isTrue);
      expect(snap.isComplete, isFalse);
    },
  );

  test(
    'Real native libtorrent 2.0.11 multi-file E2E: selective size, pause, start/resume, stop, app restart, link update',
    () async {
      final seedPayloadDir = Directory(p.join(tempRoot.path, 'seed_pack'))
        ..createSync(recursive: true);
      final leechDir = Directory(p.join(tempRoot.path, 'leech_dir'))
        ..createSync(recursive: true);

      final fileA = File(p.join(seedPayloadDir.path, 'file_a.bin'));
      final fileB = File(p.join(seedPayloadDir.path, 'file_b_skipped.bin'));
      final fileC = File(p.join(seedPayloadDir.path, 'file_c.bin'));

      final bytesA = _deterministicBytes(192 * 1024, 101);
      final bytesB = _deterministicBytes(256 * 1024, 202);
      final bytesC = _deterministicBytes(128 * 1024, 303);

      await fileA.writeAsBytes(bytesA, flush: true);
      await fileB.writeAsBytes(bytesB, flush: true);
      await fileC.writeAsBytes(bytesC, flush: true);

      final expectedTotalFull = bytesA.length + bytesB.length + bytesC.length;
      final expectedWantedSelected = bytesA.length + bytesC.length;
      final expectedShaA = _sha256Hex(bytesA);
      final expectedShaC = _sha256Hex(bytesC);

      // Boot native seeder session first so tracker can advertise its live port.
      final seederSession = lt.createSession();
      ServerSocket? proxyServer;
      final List<Socket> proxySockets = [];
      var proxyChunkDelayMs = 40;
      HttpServer? trackerServer;
      LibtorrentNativeImpl? leecher = LibtorrentNativeImpl();

      try {
        seederSession.applyConfig(
          const lt.SessionConfig(
            torrentPort: 0,
            enableIncomingTcp: true,
            enableOutgoingTcp: true,
            enableIncomingUtp: false,
            enableOutgoingUtp: false,
            activeSeeds: 16,
            activeLimit: 32,
          ),
        );
        seederSession.setIntSetting(
          lt.LibtorrentSettingsTag.alertMask,
          lt.LibtorrentAlertCategory.all,
        );
        seederSession.setDhtEnabled(false);

        final seederPort = await _pollUntil<int>(() {
          final port = seederSession.listenPort;
          return port > 0 ? port : null;
        }, reason: 'seeder listenPort');

        // Throttled loopback TCP proxy between leecher and seeder so
        // mid-transfer states (pause, resume, stop, restart, link update)
        // are captured deterministically before 100% completion.
        proxyServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        proxyServer.listen((client) async {
          proxySockets.add(client);
          try {
            final upstream = await Socket.connect(
              InternetAddress.loopbackIPv4,
              seederPort,
            );
            proxySockets.add(upstream);
            unawaited(() async {
              try {
                await for (final data in client) {
                  upstream.add(data);
                }
              } catch (_) {}
              try {
                await upstream.close();
              } catch (_) {}
            }());
            unawaited(() async {
              try {
                await for (final data in upstream) {
                  if (proxyChunkDelayMs > 0) {
                    const step = 4096;
                    for (var off = 0; off < data.length; off += step) {
                      final end =
                          (off + step < data.length) ? off + step : data.length;
                      client.add(Uint8List.sublistView(data, off, end));
                      await Future<void>.delayed(
                        Duration(milliseconds: proxyChunkDelayMs),
                      );
                    }
                  } else {
                    client.add(data);
                  }
                }
              } catch (_) {}
              try {
                await client.close();
              } catch (_) {}
            }());
          } catch (_) {
            try {
              await client.close();
            } catch (_) {}
          }
        });
        final advertisedPort = proxyServer.port;

        final announceRequests = <String>[];
        trackerServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        trackerServer.listen((req) async {
          announceRequests.add(req.uri.toString());
          req.response.statusCode = 200;
          req.response.add(_compactPeerResponse(advertisedPort));
          await req.response.close();
        });
        final trackerUrl = 'http://127.0.0.1:${trackerServer.port}/announce';

        final torrentPath = p.join(tempRoot.path, 'pack.torrent');
        final createdPath = await leecher.createTorrent(
          sourcePath: seedPayloadDir.path,
          outputPath: torrentPath,
          trackers: [trackerUrl],
          pieceSize: 16 * 1024,
        );
        expect(createdPath, equals(torrentPath));
        expect(File(torrentPath).existsSync(), isTrue);

        final parsedMeta = BencodeDecoder.parseTorrentBytes(
          await File(torrentPath).readAsBytes(),
        );
        expect(parsedMeta, isNotNull);
        final infoHash = (parsedMeta!['infoHashV1'] as String? ??
                parsedMeta['infoHash'] as String)
            .toLowerCase();

        // Start native leecher via LibtorrentNativeImpl + TorrentService BEFORE
        // adding torrent to seeder so file priorities apply cleanly at 0 bytes.
        await leecher.init(
          listenInterface: '0.0.0.0:0',
          pollInterval: const Duration(milliseconds: 100),
        );
        expect(leecher.libraryVersion, startsWith('2.0.11'));
        TorrentService.setNativeForTesting(leecher);

        final tid = leecher.addTorrentFile(torrentPath, leechDir.path);
        expect(tid, greaterThan(0));
        TorrentResumeStore.registerSource(tid, torrentPath);
        await TorrentResumeStore.registerInfoHash(torrentPath, infoHash);

        // Deselect the middle file (`file_b_skipped.bin`).
        final nativeFiles = leecher.getFiles(tid);
        expect(nativeFiles.length, equals(3));
        final priorities =
            nativeFiles.map((f) => f.name.contains('skipped') ? 0 : 4).toList();
        leecher.setFilePriorities(tid, priorities);

        // Verify accurate totalWanted reflects ONLY selected files (not deselected file_b).
        final sizedStatus = await _pollUntil(
          () {
            final st = leecher?.getTorrentStatus(tid);
            if (st != null && st.totalWanted == expectedWantedSelected) {
              return st;
            }
            return null;
          },
          timeout: const Duration(seconds: 10),
          reason: 'selective totalWanted',
        );
        expect(sizedStatus.totalWanted, equals(expectedWantedSelected));
        expect(sizedStatus.totalWanted, lessThan(expectedTotalFull));

        // Now add and start seeder so pieces transfer via throttled proxy.
        final seederHandle = seederSession.addTorrentFile(
          torrentPath: torrentPath,
          savePath: tempRoot.path,
        );
        seederHandle.resume();
        await _pollUntil<bool>(() {
          final st = seederHandle.getStatus();
          return (st.state == lt.LibtorrentTorrentState.seeding ||
                  st.totalDone >= expectedTotalFull)
              ? true
              : null;
        }, timeout: const Duration(seconds: 15), reason: 'seeder ready');
        leecher.announceNow(tid);

        // Wait for partial real payload transfer before testing pause/resume.
        final alertsLog = <String>[];
        final alertSub = leecher.alertStream.listen(
          (a) => alertsLog.add('${a.type.name}:${a.message}'),
        );
        late final NativeTorrentStatus midStatus;
        try {
          midStatus = await _pollUntil(
            () {
              final st = leecher?.getTorrentStatus(tid);
              if (st != null && st.totalWantedDone >= 16 * 1024) return st;
              return null;
            },
            timeout: const Duration(seconds: 25),
            reason: 'initial downloaded bytes',
          );
        } catch (e) {
          final lSt = leecher.getTorrentStatus(tid);
          final sSt = seederHandle.getStatus();
          final seederAlerts = <String>[];
          while (true) {
            final a = seederSession.popAlertInfo();
            if (a == null) break;
            seederAlerts.add('${a.what}:${a.message}');
          }
          // ignore: avoid_print
          print(
            'DIAGNOSTIC announces=${announceRequests.length} seederPort=$seederPort '
            'leecher=(state=${lSt?.stateLabel}, peers=${lSt?.numPeers}, seeds=${lSt?.numSeeds}, err=${lSt?.errorMsg}, done=${lSt?.totalWantedDone}, wanted=${lSt?.totalWanted}) '
            'seeder=(state=${sSt.state}, paused=${sSt.paused}, err=${sSt.error}, peers=${sSt.numPeers}) '
            'leecherAlerts=${alertsLog.take(30).toList()} '
            'seederAlerts=${seederAlerts.take(30).toList()}',
          );
          rethrow;
        } finally {
          await alertSub.cancel();
        }
        expect(midStatus.totalWantedDone,
            lessThanOrEqualTo(expectedWantedSelected));

        // 1) PAUSE
        await leecher.pauseTorrent(tid);
        final pausedStatus = await _pollUntil(
          () {
            final st = leecher?.getTorrentStatus(tid);
            if (st != null && st.isPaused) return st;
            return null;
          },
          timeout: const Duration(seconds: 10),
          reason: 'paused status',
        );
        expect(pausedStatus.downloadRate, equals(0));
        final bytesAtPause = pausedStatus.totalWantedDone;
        expect(bytesAtPause, greaterThanOrEqualTo(16 * 1024));

        // Save durable fast-resume + file snapshot to TorrentResumeStore.
        final fileProgressAtPause = leecher.getFileProgress(tid);
        final savedOnPause = await TorrentResumeStore.saveAndWait(
          torrentId: tid,
          sourceUrl: torrentPath,
          infoHash: infoHash,
          fetchResumeData: () async {
            final data = await leecher!.saveResumeData(tid);
            return data == null ? null : Uint8List.fromList(data);
          },
          files: nativeFiles.asMap().entries.map((entry) {
            final idx = entry.key;
            final nf = entry.value;
            final dl =
                idx < fileProgressAtPause.length ? fileProgressAtPause[idx] : 0;
            return {
              'name': nf.name,
              'length': nf.size,
              'selected': priorities[idx] > 0,
              'priority': priorities[idx],
              'downloadedBytes': dl,
            };
          }).toList(),
        );
        expect(savedOnPause, isTrue);

        // 2) START / RESUME
        await leecher.resumeTorrent(tid);
        leecher.announceNow(tid);
        final resumedStatus = await _pollUntil(
          () {
            final st = leecher?.getTorrentStatus(tid);
            if (st != null &&
                !st.isPaused &&
                st.totalWantedDone > bytesAtPause &&
                st.totalWantedDone < expectedWantedSelected) {
              return st;
            }
            if (st != null &&
                !st.isPaused &&
                st.totalWantedDone >= expectedWantedSelected) {
              return st;
            }
            return null;
          },
          timeout: const Duration(seconds: 20),
          reason: 'resume progress advance',
        );
        expect(
            resumedStatus.totalWantedDone, greaterThanOrEqualTo(bytesAtPause));

        // 3) STOP (pause + flush resume data + remove handle keeping partial files)
        await leecher.pauseTorrent(tid);
        final stoppedFileProgress = leecher.getFileProgress(tid);
        final savedOnStop = await TorrentResumeStore.saveAndWait(
          torrentId: tid,
          sourceUrl: torrentPath,
          infoHash: infoHash,
          fetchResumeData: () async {
            final data = await leecher!.saveResumeData(tid);
            return data == null ? null : Uint8List.fromList(data);
          },
          files: nativeFiles.asMap().entries.map((entry) {
            final idx = entry.key;
            final nf = entry.value;
            final dl =
                idx < stoppedFileProgress.length ? stoppedFileProgress[idx] : 0;
            return {
              'name': nf.name,
              'length': nf.size,
              'selected': priorities[idx] > 0,
              'priority': priorities[idx],
              'downloadedBytes': dl,
            };
          }).toList(),
        );
        expect(savedOnStop, isTrue);
        final bytesAtStop =
            leecher.getTorrentStatus(tid)?.totalWantedDone ?? bytesAtPause;
        leecher.removeTorrent(tid, deleteFiles: false);
        expect(leecher.getTorrentStatus(tid), isNull);

        // 4) APP RESTART SIMULATION: dispose session completely & recreate fresh.
        await TorrentService.dispose();
        await leecher.dispose();
        leecher = null;

        final snapAfterRestart =
            await TorrentResumeStore.loadTaskReconciliationSnapshot(
          torrentPath,
          infoHash: infoHash,
        );
        expect(snapAfterRestart, isNotNull);
        expect(snapAfterRestart!.selectedTotalBytes,
            equals(expectedWantedSelected));
        expect(snapAfterRestart.hasNativeResumeBlob, isTrue);

        final resumeBlob = await TorrentResumeStore.loadResumeDataForSource(
          torrentPath,
          infoHash: infoHash,
        );
        expect(resumeBlob, isNotNull);
        expect(resumeBlob!.isNotEmpty, isTrue);

        // 5) LINK UPDATE BEFORE/DURING RESUME (mirror magnet with new tracker).
        final updatedMagnet =
            'magnet:?xt=urn:btih:$infoHash&dn=pack&tr=${Uri.encodeComponent('$trackerUrl?mirror=2')}';
        final migratedOk = await TorrentResumeStore.migrateSourceKey(
          torrentPath,
          updatedMagnet,
          infoHash: infoHash,
        );
        expect(migratedOk, isTrue);
        final migratedBlob = await TorrentResumeStore.loadResumeDataForSource(
          updatedMagnet,
          infoHash: infoHash,
        );
        expect(migratedBlob, isNotNull);

        // Fresh native session (simulated restarted app).
        leecher = LibtorrentNativeImpl();
        await leecher.init(
          listenInterface: '127.0.0.1:0',
          downloadLimit: 0, // uncap for completion
          pollInterval: const Duration(milliseconds: 100),
        );
        TorrentService.setNativeForTesting(leecher);

        // Remove proxy throttle and complete remaining bytes after link update.
        proxyChunkDelayMs = 0;

        final restoredId = leecher.addMagnet(
          updatedMagnet,
          leechDir.path,
          resumeData: migratedBlob,
        );
        expect(restoredId, greaterThan(0));
        TorrentService.updateTorrentSource(restoredId, updatedMagnet);

        // Wait for handle to settle after resume check, then re-verify size/progress retention.
        final restoredInitial = await _pollUntil(
          () {
            final st = leecher?.getTorrentStatus(restoredId);
            if (st != null &&
                st.hasMetadata &&
                st.stateLabel != 'Checking resume data' &&
                st.stateLabel != 'Checking files') {
              return st;
            }
            return null;
          },
          timeout: const Duration(seconds: 10),
          reason: 'restored handle post-check',
        );
        expect(restoredInitial.totalWanted, equals(expectedWantedSelected));
        expect(
          restoredInitial.totalWantedDone,
          greaterThanOrEqualTo((bytesAtStop - 32 * 1024).clamp(0, bytesAtStop)),
        );

        // 6) COMPLETE TO 100% AND VERIFY EXACT BYTES ON DISK
        final finishedStatus = await _pollUntil(
          () {
            final st = leecher?.getTorrentStatus(restoredId);
            if (st != null &&
                st.totalWanted == expectedWantedSelected &&
                st.totalWantedDone == expectedWantedSelected &&
                st.isFinished) {
              return st;
            }
            return null;
          },
          timeout: const Duration(seconds: 30),
          reason: '100% completion after restart & link update',
        );
        expect(finishedStatus.totalWantedDone, equals(expectedWantedSelected));
        expect(
          TorrentService.getTrackers(restoredId)
              .any((t) => t.url.contains('mirror=2')),
          isTrue,
        );
        leecher.announceNow(restoredId);
        await _pollUntil<bool>(
          () =>
              announceRequests.any((u) => u.contains('mirror=2')) ? true : null,
          timeout: const Duration(seconds: 10),
          reason: 'updated mirror=2 tracker announce',
        );

        // Flush cache via saveResumeData before hashing disk files.
        await leecher.saveResumeData(restoredId);

        final dlA = File(p.join(leechDir.path, 'seed_pack', 'file_a.bin'));
        final dlC = File(p.join(leechDir.path, 'seed_pack', 'file_c.bin'));
        expect(dlA.existsSync(), isTrue);
        expect(dlC.existsSync(), isTrue);
        expect(await dlA.length(), equals(bytesA.length));
        expect(await dlC.length(), equals(bytesC.length));
        expect(_sha256Hex(await dlA.readAsBytes()), equals(expectedShaA));
        expect(_sha256Hex(await dlC.readAsBytes()), equals(expectedShaC));
      } finally {
        for (final s in proxySockets) {
          s.destroy();
        }
        await proxyServer?.close();
        await trackerServer?.close(force: true);
        try {
          seederSession.close();
        } catch (_) {}
        if (leecher != null) {
          await leecher.dispose();
        }
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'Real live internet public torrent download (sintel.torrent selective subtitle file)',
    () async {
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      final torrentPath = p.join(tempRoot.path, 'sintel.torrent');
      final downloadDir = Directory(p.join(tempRoot.path, 'public_dl'))
        ..createSync(recursive: true);

      // Fetch real public legal Creative Commons sintel.torrent over HTTPS.
      final httpClient = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      late Uint8List torrentBytes;
      try {
        final req = await httpClient.getUrl(
          Uri.parse('https://webtorrent.io/torrents/sintel.torrent'),
        );
        final res = await req.close().timeout(const Duration(seconds: 15));
        expect(res.statusCode, equals(200));
        final builder = BytesBuilder();
        await for (final chunk in res) {
          builder.add(chunk);
        }
        torrentBytes = builder.takeBytes();
      } finally {
        httpClient.close(force: true);
      }

      await File(torrentPath).writeAsBytes(torrentBytes, flush: true);
      final meta = BencodeDecoder.parseTorrentBytes(torrentBytes);
      expect(meta, isNotNull);

      final native = LibtorrentNativeImpl();
      await native.init(pollInterval: const Duration(milliseconds: 200));
      try {
        final tid = native.addTorrentFile(torrentPath, downloadDir.path);
        expect(tid, greaterThan(0));

        final files = native.getFiles(tid);
        expect(files.length, greaterThan(1));

        // Select ONLY the smallest non-empty file (e.g. a small .srt subtitle).
        var smallestIdx = -1;
        var smallestSize = 1 << 60;
        for (var i = 0; i < files.length; i++) {
          if (files[i].size > 0 && files[i].size < smallestSize) {
            smallestSize = files[i].size;
            smallestIdx = i;
          }
        }
        expect(smallestIdx, greaterThanOrEqualTo(0));
        final targetFile = files[smallestIdx];
        final priorities = List<int>.generate(
          files.length,
          (i) => i == smallestIdx ? 4 : 0,
        );
        native.setFilePriorities(tid, priorities);

        // Wait until totalWanted reflects the piece-aligned wanted range
        // (far smaller than the full 129MB+ multi-file torrent).
        final fullTorrentBytes = files.fold<int>(0, (sum, f) => sum + f.size);
        final sized = await _pollUntil(
          () {
            final st = native.getTorrentStatus(tid);
            if (st != null &&
                st.totalWanted >= targetFile.size &&
                st.totalWanted < fullTorrentBytes) {
              return st;
            }
            return null;
          },
          timeout: const Duration(seconds: 15),
          reason: 'public torrent selective totalWanted',
        );
        expect(sized.totalWanted, greaterThanOrEqualTo(targetFile.size));
        expect(sized.totalWanted, lessThan(fullTorrentBytes));

        // Pause cleanly then resume to verify real swarm recovery.
        await native.pauseTorrent(tid);
        final paused = await _pollUntil(
          () {
            final st = native.getTorrentStatus(tid);
            if (st != null && st.isPaused) return st;
            return null;
          },
          timeout: const Duration(seconds: 10),
          reason: 'public torrent pause',
        );
        expect(paused.isPaused, isTrue);

        await native.resumeTorrent(tid);

        // Wait for complete download of the real selected file from public swarm.
        final done = await _pollUntil(
          () {
            final st = native.getTorrentStatus(tid);
            if (st != null &&
                st.totalWanted > 0 &&
                st.totalWantedDone >= st.totalWanted &&
                st.isFinished) {
              return st;
            }
            return null;
          },
          timeout: const Duration(seconds: 60),
          reason:
              'public torrent selected file completion (${targetFile.name})',
        );
        expect(done.totalWantedDone, equals(done.totalWanted));
        final fileProg = native.getFileProgress(tid);
        expect(fileProg[smallestIdx], equals(targetFile.size));
        await native.saveResumeData(tid);

        final diskFile = File(
          p.joinAll([
            downloadDir.path,
            ...targetFile.path.replaceAll('\\', '/').split('/'),
          ]),
        );
        expect(diskFile.existsSync(), isTrue);
        expect(await diskFile.length(), equals(targetFile.size));
      } finally {
        await native.dispose();
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
