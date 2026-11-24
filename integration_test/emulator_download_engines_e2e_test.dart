import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dmx/core/di/injection.dart';
import 'package:dmx/core/interfaces/i_download_engine.dart';
import 'package:dmx/core/interfaces/i_torrent_native.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/protocol_cache.dart';
import 'package:dmx/core/services/torrent/libtorrent_native_impl.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';
import 'package:dmx/core/services/torrent_service_ffi.dart';
import 'package:dmx/core/utils/bencode_decoder.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:libtorrent_dart/libtorrent_dart.dart' as lt;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

Uint8List _compactPeerResponse(int port,
    {List<int> ip = const [127, 0, 0, 1]}) {
  final payload = BytesBuilder()
    ..add(utf8.encode('d8:intervali5e5:peers6:'))
    ..add([...ip, (port >> 8) & 0xff, port & 0xff])
    ..add(utf8.encode('e'));
  return payload.toBytes();
}

Future<InternetAddress> _resolveLocalNonLoopbackOrLoopback() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (!addr.isLoopback) return addr;
      }
    }
  } catch (_) {}
  return InternetAddress.loopbackIPv4;
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

class _RecordedHttpRequest {
  final String method;
  final String path;
  final String? rangeHeader;

  _RecordedHttpRequest({
    required this.method,
    required this.path,
    this.rangeHeader,
  });
}

class _LocalRangePayloadServer {
  _LocalRangePayloadServer({required this.payload})
      : etag = '"dmx-${sha256.convert(payload).toString().substring(0, 12)}"';

  final Uint8List payload;
  final String etag;
  HttpServer? _server;
  int paceDelayMs = 25;
  int paceChunkBytes = 16 * 1024;
  final List<_RecordedHttpRequest> requests = [];

  int get port => _server!.port;

  String urlFor(String path) => 'http://127.0.0.1:$port$path';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleRequest);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest req) async {
    final path = req.uri.path;
    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
    requests.add(
      _RecordedHttpRequest(
        method: req.method,
        path: path,
        rangeHeader: rangeHeader,
      ),
    );

    if (path != '/payload.bin' &&
        path != '/payload2.bin' &&
        path != '/mirror-2/payload.bin') {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }

    final total = payload.length;
    req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    req.response.headers.set(HttpHeaders.etagHeader, etag);
    req.response.headers.contentType = ContentType.binary;

    if (req.method == 'HEAD') {
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentLength = total;
      await req.response.close();
      return;
    }

    var start = 0;
    var end = total - 1;
    var isPartial = false;

    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final spec = rangeHeader.substring('bytes='.length).split(',').first;
      final parts = spec.split('-');
      if (parts.length == 2) {
        final rawStart = parts[0].trim();
        final rawEnd = parts[1].trim();
        if (rawStart.isNotEmpty) {
          start = int.parse(rawStart);
          end =
              rawEnd.isNotEmpty ? min(int.parse(rawEnd), total - 1) : total - 1;
        } else if (rawEnd.isNotEmpty) {
          final suffix = int.parse(rawEnd);
          start = max(0, total - suffix);
          end = total - 1;
        }
        if (start >= total || start > end || start < 0) {
          req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          req.response.headers
              .set(HttpHeaders.contentRangeHeader, 'bytes */$total');
          await req.response.close();
          return;
        }
        isPartial = true;
      }
    }

    final length = end - start + 1;
    if (isPartial) {
      req.response.statusCode = HttpStatus.partialContent;
      req.response.headers
          .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
    } else {
      req.response.statusCode = HttpStatus.ok;
    }
    req.response.headers.contentLength = length;

    // Serve tiny probe ranges (e.g., bytes=0-0 and 16KB spot checks) immediately.
    if (length <= 32 * 1024 || paceDelayMs <= 0) {
      req.response.add(Uint8List.sublistView(payload, start, end + 1));
      await req.response.close();
      return;
    }

    var offset = start;
    try {
      while (offset <= end) {
        final nextEnd = min(offset + paceChunkBytes - 1, end);
        req.response.add(Uint8List.sublistView(payload, offset, nextEnd + 1));
        await req.response.flush();
        offset = nextEnd + 1;
        if (offset <= end && paceDelayMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: paceDelayMs));
        }
      }
    } catch (_) {
      // Client closed socket early on pause/stop.
    } finally {
      try {
        await req.response.close();
      } catch (_) {}
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory testRoot;
  late DatabaseService databaseService;
  late SettingsProvider settingsProvider;

  setUpAll(() async {
    await PowerMonitor.init();
    await ProtocolCache.init();

    settingsProvider = SettingsProvider.instance;
    await settingsProvider.load();
    await settingsProvider.setWifiOnly(false);
    await settingsProvider.setPauseOnCellular(false);
    await settingsProvider.setDownloadOnlyWhileCharging(false);
    await settingsProvider.setHttpsOnly(false);
    await settingsProvider.setAutoStart(true);
    await settingsProvider.setMaxDownloads(3);
    await settingsProvider.setDefaultThreadCount(4);
    await settingsProvider.setMaxTotalConnections(16);
    await settingsProvider.setSpeedLimit(0);
    await settingsProvider.setNotificationsEnabled(false);
    await settingsProvider.setEnableProxy(false);
    await settingsProvider.setAutoVerifyChecksum(true);

    await configureDependencies();
    databaseService = DatabaseService();
    if (!databaseService.isInitialized) {
      await databaseService.init();
    }

    final appDocs = await getApplicationDocumentsDirectory();
    testRoot = Directory(p.join(appDocs.path, 'dmx_emulator_e2e_run'))
      ..createSync(recursive: true);
  });

  tearDownAll(() async {
    try {
      await TorrentService.dispose();
    } catch (_) {}
    if (await testRoot.exists()) {
      try {
        await testRoot.delete(recursive: true);
      } catch (_) {}
    }
  });

  group('Part A: Emulator On-Device Download Engines E2E', () {
    testWidgets(
      '1. HTTP Download Engine & All Functions (2MB, 4 threads, pause, resume, stop-keep, link-update, stop-delete)',
      (tester) async {
        const fileSize = 2 * 1024 * 1024; // 2 MB
        final payload = _deterministicBytes(fileSize, 4242);
        final expectedSha256 = _sha256Hex(payload);

        final server = _LocalRangePayloadServer(payload: payload);
        await server.start();

        final httpDir = Directory(p.join(testRoot.path, 'http_e2e'))
          ..createSync(recursive: true);

        DownloadProvider? provider = DownloadProvider(
          databaseService: databaseService,
          settingsProvider: settingsProvider,
          downloadEngine: getIt<IDownloadEngine>(),
          enableBackgroundTimers: false,
        );
        DownloadProvider? restartedProvider;

        String? primaryTaskId;
        String? secondaryTaskId;

        try {
          await provider.load(pauseOrphanDownloads: true, autoResume: false);
          // Clear any pre-existing tasks in DB so queue slots are clean.
          for (final existing in List<DownloadTask>.from(provider.tasks)) {
            await provider.deleteTask(existing.id, deleteFiles: true);
          }

          // Start multi-connection (4-thread) HTTP download via DownloadProvider.
          server.paceDelayMs = 90;
          server.paceChunkBytes = 8 * 1024;
          final primaryUrl = server.urlFor('/payload.bin');
          primaryTaskId = await provider.addDownload(
            url: primaryUrl,
            name: 'payload.bin',
            threadCount: 4,
            savePath: httpDir.path,
            expectedSha256: expectedSha256,
          );
          expect(primaryTaskId, isNotNull);
          final id = primaryTaskId!;

          // Verify accurate fileSize (2 MB) and partial progress updates.
          final activeTask = await _pollUntil<DownloadTask>(
            () {
              final t = provider?.taskById(id);
              if (t != null &&
                  t.status == DownloadStatus.downloading &&
                  t.fileSize == fileSize &&
                  t.downloadedBytes >= 64 * 1024 &&
                  t.downloadedBytes < fileSize) {
                return t;
              }
              return null;
            },
            timeout: const Duration(seconds: 25),
            reason: 'HTTP 2MB partial progress',
          );
          expect(activeTask.fileSize, equals(fileSize));
          expect(activeTask.threadCount, equals(4));

          // PAUSE mid-download.
          await provider.pauseTask(id);
          final pausedTask = provider.taskById(id)!;
          expect(pausedTask.status, equals(DownloadStatus.paused));
          expect(pausedTask.speed, equals(0));
          expect(pausedTask.downloadedBytes, greaterThan(0));
          expect(pausedTask.downloadedBytes, lessThan(fileSize));

          final stateFile = File(
            StateStore.pathFor(pausedTask.tempFilePath, taskId: id),
          );
          final legacyStateFile = File('${pausedTask.tempFilePath}.dmxstate');
          expect(
            stateFile.existsSync() || legacyStateFile.existsSync(),
            isTrue,
            reason: 'Durable .dmxstate file must exist after pause',
          );
          final bytesAtPause = pausedTask.downloadedBytes;
          final reqCountBeforeResume = server.requests.length;

          // START / RESUME and assert HTTP Range resumes without resetting to 0.
          await provider.resumeTask(id);
          final resumedTask = await _pollUntil<DownloadTask>(
            () {
              final t = provider?.taskById(id);
              if (t != null &&
                  t.status == DownloadStatus.downloading &&
                  t.downloadedBytes > bytesAtPause &&
                  t.downloadedBytes < fileSize) {
                return t;
              }
              return null;
            },
            timeout: const Duration(seconds: 25),
            reason: 'HTTP Range resume progress advance',
          );
          expect(resumedTask.downloadedBytes, greaterThan(bytesAtPause));

          final resumeRequests =
              server.requests.sublist(reqCountBeforeResume).where(
                    (r) =>
                        r.path == '/payload.bin' &&
                        r.rangeHeader != null &&
                        r.rangeHeader!.startsWith('bytes=') &&
                        r.rangeHeader != 'bytes=0-0',
                  );
          expect(resumeRequests, isNotEmpty);

          // STOP (keep partial files: deletePartialFiles: false).
          await provider.stopTask(id, deletePartialFiles: false);
          final stoppedTask = provider.taskById(id)!;
          expect(stoppedTask.status, equals(DownloadStatus.paused));
          expect(stoppedTask.speed, equals(0));
          expect(stoppedTask.downloadedBytes, greaterThan(bytesAtPause));
          expect(stoppedTask.downloadedBytes, lessThan(fileSize));
          expect(File(stoppedTask.tempFilePath).existsSync(), isTrue);
          expect(
            stateFile.existsSync() || legacyStateFile.existsSync(),
            isTrue,
          );
          final bytesAtStop = stoppedTask.downloadedBytes;

          // APP RESTART SIMULATION: dispose DownloadProvider and reload from DB + .dmxstate/.dmxpart.
          provider.dispose();
          provider = null;

          restartedProvider = DownloadProvider(
            databaseService: databaseService,
            settingsProvider: settingsProvider,
            downloadEngine: getIt<IDownloadEngine>(),
            enableBackgroundTimers: false,
          );
          await restartedProvider.load(
            pauseOrphanDownloads: true,
            autoResume: false,
          );
          final restoredTask = restartedProvider.taskById(id);
          expect(restoredTask, isNotNull);
          expect(restoredTask!.status, equals(DownloadStatus.paused));
          expect(restoredTask.fileSize, equals(fileSize));
          expect(restoredTask.downloadedBytes, equals(bytesAtStop));

          // LINK UPDATE to /mirror-2/payload.bin -> zero data loss + 100% + SHA-256.
          server.paceDelayMs = 0;
          final mirrorUrl = server.urlFor('/mirror-2/payload.bin');
          final reqCountBeforeMirror = server.requests.length;
          await restartedProvider.updateTaskUrlAndResume(id, mirrorUrl);

          final completedTask = await _pollUntil<DownloadTask>(
            () {
              final t = restartedProvider?.taskById(id);
              if (t == null) return null;
              if (t.status == DownloadStatus.failed) {
                throw StateError(
                  'HTTP mirror download failed: ${t.errorMessage}',
                );
              }
              expect(
                t.downloadedBytes,
                greaterThanOrEqualTo(bytesAtStop),
                reason: 'Link update must not lose existing partial bytes',
              );
              return t.status == DownloadStatus.completed ? t : null;
            },
            timeout: const Duration(seconds: 30),
            reason: 'HTTP mirror link update completion',
          );

          expect(completedTask.url, equals(mirrorUrl));
          expect(completedTask.downloadedBytes, equals(fileSize));
          expect(completedTask.fileSize, equals(fileSize));
          expect(
            server.requests
                .sublist(reqCountBeforeMirror)
                .any((r) => r.path == '/mirror-2/payload.bin'),
            isTrue,
          );

          final finalFile = File(completedTask.localFilePath);
          expect(finalFile.existsSync(), isTrue);
          expect(await finalFile.length(), equals(fileSize));
          expect(
            _sha256Hex(await finalFile.readAsBytes()),
            equals(expectedSha256),
          );

          // STOP (delete partial files: deletePartialFiles: true) on second task.
          server.paceDelayMs = 90;
          secondaryTaskId = await restartedProvider.addDownload(
            url: server.urlFor('/payload2.bin'),
            name: 'payload2.bin',
            threadCount: 4,
            savePath: httpDir.path,
          );
          expect(secondaryTaskId, isNotNull);
          final id2 = secondaryTaskId!;

          final secondActive = await _pollUntil<DownloadTask>(
            () {
              final t = restartedProvider?.taskById(id2);
              if (t != null &&
                  t.status == DownloadStatus.downloading &&
                  t.downloadedBytes >= 64 * 1024 &&
                  t.downloadedBytes < fileSize) {
                return t;
              }
              return null;
            },
            timeout: const Duration(seconds: 25),
            reason: 'second HTTP task partial progress',
          );
          expect(secondActive.downloadedBytes, greaterThan(0));

          await restartedProvider.stopTask(id2, deletePartialFiles: true);
          final deletedPartialTask = restartedProvider.taskById(id2)!;
          expect(deletedPartialTask.status, equals(DownloadStatus.paused));
          expect(deletedPartialTask.downloadedBytes, equals(0));
          expect(File(deletedPartialTask.tempFilePath).existsSync(), isFalse);
          expect(
            File(StateStore.pathFor(deletedPartialTask.tempFilePath,
                    taskId: id2))
                .existsSync(),
            isFalse,
          );
          expect(
            File('${deletedPartialTask.tempFilePath}.dmxstate').existsSync(),
            isFalse,
          );
        } finally {
          final activeProv = restartedProvider ?? provider;
          if (activeProv != null) {
            if (primaryTaskId != null) {
              await activeProv.deleteTask(primaryTaskId, deleteFiles: true);
            }
            if (secondaryTaskId != null) {
              await activeProv.deleteTask(secondaryTaskId, deleteFiles: true);
            }
            activeProv.dispose();
          }
          await server.stop();
        }
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    testWidgets(
      '2a. Torrent Engine Loopback Multi-file Lifecycle (version, selective size, pause, resume, stop, restart, link update, SHA-256)',
      (tester) async {
        final torrentRoot = Directory(p.join(testRoot.path, 'torrent_loopback'))
          ..createSync(recursive: true);
        final seedPayloadDir = Directory(p.join(torrentRoot.path, 'seed_pack'))
          ..createSync(recursive: true);
        final leechDir = Directory(p.join(torrentRoot.path, 'leech_dir'))
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
        expect(expectedTotalFull, equals(589824));
        expect(expectedWantedSelected, equals(327680));
        final expectedShaA = _sha256Hex(bytesA);
        final expectedShaC = _sha256Hex(bytesC);

        final relayAddr = await _resolveLocalNonLoopbackOrLoopback();
        final seederSession = lt.createSession();
        ServerSocket? proxyServer;
        final List<Socket> proxySockets = [];
        var proxyChunkDelayMs = 60;
        var proxyConnCount = 0;
        var proxyBytesForwarded = 0;
        var clientBytesForwarded = 0;
        var proxyConnectErrors = 0;
        final seederReadyCompleter = Completer<void>();
        String? lastProxyErr;
        HttpServer? trackerServer;
        LibtorrentNativeImpl? leecher = LibtorrentNativeImpl();

        try {
          seederSession.setIntSetting(
            lt.LibtorrentSettingsTag.alertMask,
            lt.LibtorrentAlertCategory.all,
          );
          seederSession.applyConfig(
            const lt.SessionConfig(
              torrentPort: 0,
              uploadRateLimit: 24 * 1024,
              enableIncomingTcp: true,
              enableOutgoingTcp: true,
              enableIncomingUtp: false,
              enableOutgoingUtp: false,
              activeSeeds: 16,
              activeLimit: 32,
            ),
          );
          seederSession.setDhtEnabled(false);
          seederSession.setLsdEnabled(false);

          final seederPort = await _pollUntil<int>(() {
            final port = seederSession.listenPort;
            return port > 0 ? port : null;
          }, reason: 'seeder listenPort');

          await runZonedGuarded(() async {
            proxyServer = await ServerSocket.bind(relayAddr, 0);
            proxyServer!.listen((client) {
              proxyConnCount++;
              proxySockets.add(client);
              unawaited(client.done.catchError((_) {}));
              () async {
                try {
                  final upstream = await Socket.connect(
                    relayAddr,
                    seederPort,
                  );
                  proxySockets.add(upstream);
                  unawaited(upstream.done.catchError((_) {}));
                  unawaited(() async {
                    try {
                      await for (final data in client) {
                        clientBytesForwarded += data.length;
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
                        proxyBytesForwarded += data.length;
                        if (proxyChunkDelayMs > 0) {
                          const step = 2048;
                          for (var off = 0; off < data.length; off += step) {
                            final end = (off + step < data.length)
                                ? off + step
                                : data.length;
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
                } catch (e) {
                  proxyConnectErrors++;
                  lastProxyErr = e.toString();
                  try {
                    await client.close();
                  } catch (_) {}
                }
              }();
            });
          }, (_, __) {});
          final advertisedPort = proxyServer!.port;

          final announceRequests = <String>[];
          trackerServer = await HttpServer.bind(relayAddr, 0);
          trackerServer.listen((req) async {
            announceRequests.add(req.uri.toString());
            req.response.statusCode = 200;
            final portMatch =
                RegExp(r'(?:^|&)port=(\d+)').firstMatch(req.uri.query);
            final peerPort = int.tryParse(portMatch?.group(1) ?? '');
            if (peerPort == seederPort) {
              req.response.add(utf8.encode('d8:intervali5e5:peers0:e'));
            } else {
              if (!seederReadyCompleter.isCompleted) {
                await seederReadyCompleter.future.timeout(
                  const Duration(seconds: 20),
                  onTimeout: () {},
                );
              }
              req.response.add(
                _compactPeerResponse(
                  advertisedPort,
                  ip: relayAddr.rawAddress,
                ),
              );
            }
            await req.response.close();
          });
          final trackerUrl =
              'http://${relayAddr.address}:${trackerServer.port}/announce';

          final torrentPath = p.join(torrentRoot.path, 'pack.torrent');
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

          await leecher.init(
            downloadLimit: 24 * 1024,
            pollInterval: const Duration(milliseconds: 100),
          );
          expect(leecher.libraryVersion, startsWith('2.0.11'));
          TorrentService.setNativeForTesting(leecher);
          leecher.configureSession(
            const NativeBtConfig(
              downloadRateLimit: 24 * 1024,
              disableUtp: true,
              disableDht: true,
              disableUpnp: true,
            ),
          );
          final loopAlerts = <String>[];
          final loopAlertSub = leecher.alertStream.listen((a) {
            if (loopAlerts.length < 50) {
              loopAlerts.add('${a.type.name}:${a.message}');
            }
          });

          final tid = leecher.addTorrentFile(torrentPath, leechDir.path);
          expect(tid, greaterThan(0));
          TorrentResumeStore.registerSource(tid, torrentPath);
          await TorrentResumeStore.registerInfoHash(torrentPath, infoHash);

          final nativeFiles = leecher.getFiles(tid);
          expect(nativeFiles.length, equals(3));
          final priorities = nativeFiles
              .map((f) => f.name.contains('skipped') ? 0 : 4)
              .toList();
          expect(priorities, equals([4, 0, 4]));
          leecher.setFilePriorities(tid, priorities);

          final sizedStatus = await _pollUntil(
            () {
              final st = leecher?.getTorrentStatus(tid);
              if (st != null && st.totalWanted == expectedWantedSelected) {
                return st;
              }
              return null;
            },
            timeout: const Duration(seconds: 15),
            reason: 'selective totalWanted',
          );
          expect(sizedStatus.totalWanted, equals(327680));
          expect(sizedStatus.totalWanted, lessThan(589824));
          expect(sizedStatus.totalWantedDone,
              lessThanOrEqualTo(sizedStatus.totalWanted));

          // Start native seeder.
          final seederHandle = seederSession.addTorrentFile(
            torrentPath: torrentPath,
            savePath: torrentRoot.path,
          );
          seederHandle.resume();
          await _pollUntil<bool>(() {
            final st = seederHandle.getStatus();
            return (st.state == lt.LibtorrentTorrentState.seeding ||
                    st.totalDone >= expectedTotalFull)
                ? true
                : null;
          }, timeout: const Duration(seconds: 15), reason: 'seeder ready');
          if (!seederReadyCompleter.isCompleted) {
            seederReadyCompleter.complete();
          }
          leecher.announceNow(tid);

          late final NativeTorrentStatus midStatus;
          try {
            midStatus = await _pollUntil(
              () {
                final st = leecher?.getTorrentStatus(tid);
                if (st != null && st.totalWantedDone >= 16 * 1024) return st;
                return null;
              },
              timeout: const Duration(seconds: 25),
              interval: const Duration(milliseconds: 50),
              reason: 'initial torrent downloaded bytes',
            );
          } catch (_) {
            final lSt = leecher.getTorrentStatus(tid);
            final sSt = seederHandle.getStatus();
            final seederAlerts = <String>[];
            while (seederAlerts.length < 40) {
              final a = seederSession.popAlertInfo();
              if (a == null) break;
              seederAlerts.add('${a.what}:${a.message}');
            }
            // ignore: avoid_print
            print(
              'LOOPBACK INIT DIAG relay=${relayAddr.address} announces=${announceRequests.length} '
              'proxyConns=$proxyConnCount clientBytes=$clientBytesForwarded proxyBytes=$proxyBytesForwarded '
              'proxyErrs=$proxyConnectErrors lastProxyErr=$lastProxyErr '
              'seederPort=$seederPort advPort=$advertisedPort '
              'leecher=(state=${lSt?.stateLabel}, peers=${lSt?.numPeers}, seeds=${lSt?.numSeeds}, done=${lSt?.totalWantedDone}, wanted=${lSt?.totalWanted}, err=${lSt?.errorMsg}) '
              'seeder=(state=${sSt.state}, paused=${sSt.paused}, peers=${sSt.numPeers}, err=${sSt.error}) '
              'leecherAlerts=$loopAlerts '
              'seederAlerts=$seederAlerts',
            );
            rethrow;
          } finally {
            await loopAlertSub.cancel();
          }
          expect(midStatus.totalWantedDone,
              lessThanOrEqualTo(expectedWantedSelected));

          // PAUSE
          await leecher.pauseTorrent(tid);
          final pausedStatus = await _pollUntil(
            () {
              final st = leecher?.getTorrentStatus(tid);
              if (st != null && st.isPaused) return st;
              return null;
            },
            timeout: const Duration(seconds: 10),
            reason: 'torrent paused status',
          );
          expect(pausedStatus.downloadRate, equals(0));
          final bytesAtPause = pausedStatus.totalWantedDone;
          expect(bytesAtPause, greaterThanOrEqualTo(16 * 1024));

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
              final dl = idx < fileProgressAtPause.length
                  ? fileProgressAtPause[idx]
                  : 0;
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

          // START / RESUME
          await leecher.resumeTorrent(tid);
          leecher.announceNow(tid);
          late final NativeTorrentStatus resumedStatus;
          try {
            resumedStatus = await _pollUntil(
              () {
                final st = leecher?.getTorrentStatus(tid);
                if (st != null &&
                    !st.isPaused &&
                    st.totalWantedDone > bytesAtPause &&
                    st.totalWantedDone <= expectedWantedSelected) {
                  return st;
                }
                return null;
              },
              timeout: const Duration(seconds: 25),
              reason: 'torrent resume progress advance',
            );
          } catch (_) {
            final lSt = leecher.getTorrentStatus(tid);
            final sSt = seederHandle.getStatus();
            // ignore: avoid_print
            print(
              'LOOPBACK RESUME DIAG bytesAtPause=$bytesAtPause '
              'announces=${announceRequests.length} '
              'leecher=(state=${lSt?.stateLabel}, paused=${lSt?.isPaused}, peers=${lSt?.numPeers}, seeds=${lSt?.numSeeds}, done=${lSt?.totalWantedDone}, wanted=${lSt?.totalWanted}, err=${lSt?.errorMsg}) '
              'seeder=(state=${sSt.state}, paused=${sSt.paused}, peers=${sSt.numPeers}, err=${sSt.error})',
            );
            rethrow;
          }
          expect(resumedStatus.totalWantedDone, greaterThan(bytesAtPause));

          // STOP (keep partials)
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
              final dl = idx < stoppedFileProgress.length
                  ? stoppedFileProgress[idx]
                  : 0;
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

          // APP RESTART SIMULATION
          await TorrentService.dispose();
          await leecher.dispose();
          leecher = null;

          final snapAfterRestart =
              await TorrentResumeStore.loadTaskReconciliationSnapshot(
            torrentPath,
            infoHash: infoHash,
          );
          expect(snapAfterRestart, isNotNull);
          expect(snapAfterRestart!.selectedTotalBytes, equals(327680));
          expect(snapAfterRestart.hasNativeResumeBlob, isTrue);
          expect(snapAfterRestart.selectedDownloadedBytes, greaterThan(0));

          final resumeBlob = await TorrentResumeStore.loadResumeDataForSource(
            torrentPath,
            infoHash: infoHash,
          );
          expect(resumeBlob, isNotNull);
          expect(resumeBlob!.isNotEmpty, isTrue);

          // LINK UPDATE
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

          leecher = LibtorrentNativeImpl();
          await leecher.init(
            downloadLimit: 0,
            pollInterval: const Duration(milliseconds: 100),
          );
          TorrentService.setNativeForTesting(leecher);
          leecher.configureSession(
            const NativeBtConfig(
              downloadRateLimit: 0,
              disableUtp: true,
              disableDht: true,
              disableUpnp: true,
            ),
          );
          seederSession.setUploadRateLimit(0);
          proxyChunkDelayMs = 0;

          final restoredId = leecher.addMagnet(
            updatedMagnet,
            leechDir.path,
            resumeData: migratedBlob,
          );
          expect(restoredId, greaterThan(0));
          TorrentService.updateTorrentSource(restoredId, updatedMagnet);

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
            timeout: const Duration(seconds: 15),
            reason: 'restored torrent handle post-check',
          );
          expect(restoredInitial.totalWanted, equals(327680));
          expect(
            restoredInitial.totalWantedDone,
            greaterThanOrEqualTo(
              (bytesAtStop - 32 * 1024).clamp(0, bytesAtStop),
            ),
          );

          final finishedStatus = await _pollUntil(
            () {
              final st = leecher?.getTorrentStatus(restoredId);
              if (st != null &&
                  st.totalWanted == 327680 &&
                  st.totalWantedDone == 327680 &&
                  st.isFinished) {
                return st;
              }
              return null;
            },
            timeout: const Duration(seconds: 30),
            reason: 'torrent 100% completion after restart & link update',
          );
          expect(finishedStatus.totalWantedDone, equals(327680));
          expect(
            TorrentService.getTrackers(restoredId)
                .any((t) => t.url.contains('mirror=2')),
            isTrue,
          );
          leecher.announceNow(restoredId);
          await _pollUntil<bool>(
            () => announceRequests.any((u) => u.contains('mirror=2'))
                ? true
                : null,
            timeout: const Duration(seconds: 15),
            reason: 'mirror=2 tracker announce',
          );

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
          if (!seederReadyCompleter.isCompleted) {
            seederReadyCompleter.complete();
          }
          for (final s in proxySockets) {
            s.destroy();
          }
          await proxyServer?.close();
          await trackerServer?.close(force: true);
          try {
            seederSession.close();
          } catch (_) {}
          if (leecher != null) {
            try {
              await TorrentService.dispose();
            } catch (_) {}
            await leecher.dispose();
          }
        }
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    testWidgets(
      '2b. Real Live Public Internet Torrent Download (sintel.torrent smallest .srt file)',
      (tester) async {
        final publicRoot = Directory(p.join(testRoot.path, 'torrent_public'))
          ..createSync(recursive: true);
        final torrentPath = p.join(publicRoot.path, 'sintel.torrent');
        final downloadDir = Directory(p.join(publicRoot.path, 'public_dl'))
          ..createSync(recursive: true);

        final httpClient = HttpClient()
          ..connectionTimeout = const Duration(seconds: 15);
        late Uint8List torrentBytes;
        try {
          final req = await httpClient.getUrl(
            Uri.parse('https://webtorrent.io/torrents/sintel.torrent'),
          );
          final res = await req.close().timeout(const Duration(seconds: 20));
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
        await native.init(
          pollInterval: const Duration(milliseconds: 200),
        );
        expect(native.libraryVersion, startsWith('2.0.11'));

        final publicAlerts = <String>[];
        final alertSub = native.alertStream.listen((a) {
          if (publicAlerts.length < 40) {
            publicAlerts.add('${a.type.name}:${a.message}');
          }
        });

        try {
          final tid = native.addTorrentFile(torrentPath, downloadDir.path);
          expect(tid, greaterThan(0));
          // Also add HTTP announce endpoint for opentrackr in case emulator NAT drops UDP.
          native.addTracker(
            tid,
            'http://tracker.opentrackr.org:1337/announce',
            tier: 0,
          );

          final files = native.getFiles(tid);
          expect(files.length, greaterThan(1));

          var smallestIdx = -1;
          var smallestSize = 1 << 60;
          for (var i = 0; i < files.length; i++) {
            final f = files[i];
            if (f.size > 0 &&
                f.name.toLowerCase().endsWith('.srt') &&
                f.size < smallestSize) {
              smallestSize = f.size;
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

          // Pause then resume to verify real swarm recovery.
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

          late final NativeTorrentStatus done;
          try {
            done = await _pollUntil(
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
              timeout: const Duration(seconds: 75),
              reason: 'public torrent completion (${targetFile.name})',
            );
          } catch (_) {
            final st = native.getTorrentStatus(tid);
            final trk = native.getTrackers(tid).map((t) => t.url).toList();
            // ignore: avoid_print
            print(
              'PUBLIC TORRENT DIAG file=${targetFile.name}(${targetFile.size}B) '
              'state=${st?.stateLabel} paused=${st?.isPaused} peers=${st?.numPeers} '
              'seeds=${st?.numSeeds} done=${st?.totalWantedDone}/${st?.totalWanted} '
              'rate=${st?.downloadRate} err=${st?.errorMsg} trackers=$trk '
              'alerts=$publicAlerts',
            );
            rethrow;
          }
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
          await alertSub.cancel();
          await native.dispose();
        }
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });
}
