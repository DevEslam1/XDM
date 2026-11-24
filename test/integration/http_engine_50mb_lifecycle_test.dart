import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:crypto/crypto.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/permission_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';

class _TestConnectivityPlatform extends ConnectivityPlatform {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      const [ConnectivityResult.wifi];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      Stream.value(const [ConnectivityResult.wifi]);
}

class _TestPermissionService extends PermissionService {
  _TestPermissionService(this._defaultDir);

  final String _defaultDir;

  @override
  Future<String> defaultDownloadDirectory() async => _defaultDir;

  @override
  Future<bool> ensureStorageAccess() async => true;

  @override
  Future<bool> isStoragePermissionValid() async => true;

  @override
  Future<bool?> isDirectoryWritable(String directoryPath) async => true;
}

/// Disk-persisted DatabaseService fake using JSON rows so cold app restart
/// scenarios instantiate a fresh DatabaseService, DownloadEngine, and
/// DownloadProvider against real persisted task state on disk.
class _JsonDiskDatabaseService extends DatabaseService {
  _JsonDiskDatabaseService(this.dbFile) : super.forSubclass();

  final File dbFile;
  final Lock _lock = Lock();

  Future<List<Map<String, dynamic>>> _readRaw() async {
    if (!await dbFile.exists()) return [];
    final raw = await dbFile.readAsString();
    if (raw.trim().isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> _writeRaw(List<Map<String, dynamic>> rows) async {
    await dbFile.parent.create(recursive: true);
    await dbFile.writeAsString(jsonEncode(rows), flush: true);
  }

  @override
  Future<List<DownloadTask>> loadTasks() => _lock.synchronized(() async {
        final raw = await _readRaw();
        return raw.map(DownloadTask.fromMap).toList();
      });

  @override
  Future<DownloadTask?> getTask(String id) => _lock.synchronized(() async {
        final raw = await _readRaw();
        for (final row in raw) {
          if (row['id'] == id) return DownloadTask.fromMap(row);
        }
        return null;
      });

  @override
  Future<void> saveTask(DownloadTask task) => _lock.synchronized(() async {
        final raw = await _readRaw();
        raw.removeWhere((r) => r['id'] == task.id);
        raw.add(task.toMap());
        await _writeRaw(raw);
      });

  @override
  Future<void> saveTasks(Iterable<DownloadTask> tasks) =>
      _lock.synchronized(() async {
        final raw = await _readRaw();
        final ids = tasks.map((t) => t.id).toSet();
        raw.removeWhere((r) => ids.contains(r['id']));
        for (final t in tasks) {
          raw.add(t.toMap());
        }
        await _writeRaw(raw);
      });

  @override
  Future<void> saveTaskDebounced(DownloadTask task) => saveTask(task);

  @override
  Future<void> deleteTask(String id) => _lock.synchronized(() async {
        final raw = await _readRaw();
        raw.removeWhere((r) => r['id'] == id);
        await _writeRaw(raw);
      });

  @override
  Future<void> deleteTasks(Iterable<String> ids) => _lock.synchronized(() async {
        final set = ids.toSet();
        final raw = await _readRaw();
        raw.removeWhere((r) => set.contains(r['id']));
        await _writeRaw(raw);
      });

  @override
  Future<void> clearAllTasks() => _lock.synchronized(() async {
        await _writeRaw([]);
      });

  @override
  Future<void> flushPendingSaves() async {}

  @override
  Future<void> flushPendingSavesSync() async {}

  @override
  Future<int> checkpointWal({bool truncate = true}) async => 0;
}

const List<int> _pngHeader = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

int _deterministicByteAt(int offset) {
  if (offset < _pngHeader.length) return _pngHeader[offset];
  return ((offset * 2654435761) ^ (offset >> 13) ^ 0x5A) & 0xFF;
}

Uint8List _generateRangeBytes(int start, int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _deterministicByteAt(start + i);
  }
  return out;
}

({int start, int end})? _parseRangeHeader(String? header, int totalSize) {
  if (header == null) return null;
  final m = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header.trim());
  if (m == null) return null;
  final start = int.parse(m.group(1)!);
  final endGroup = m.group(2)!;
  final rawEnd = endGroup.isEmpty ? totalSize - 1 : int.parse(endGroup);
  final end = math.min(rawEnd, totalSize - 1);
  if (start < 0 || start >= totalSize || end < start) return null;
  return (start: start, end: end);
}

Future<DownloadTask> _waitForTaskCondition(
  DownloadProvider provider,
  String taskId,
  bool Function(DownloadTask task) condition, {
  Duration timeout = const Duration(seconds: 60),
  String description = 'task condition',
}) async {
  final sw = Stopwatch()..start();
  DownloadTask? last;
  while (sw.elapsed < timeout) {
    last = provider.findTaskById(taskId);
    if (last != null && condition(last)) {
      return last;
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw StateError(
    'Timed out waiting for $description after ${timeout.inSeconds}s. '
    'Last state: status=${last?.status}, downloaded=${last?.downloadedBytes}, '
    'fileSize=${last?.fileSize}, err=${last?.errorMessage}',
  );
}

Future<void> _serveDeterministicRange(
  HttpRequest req, {
  required int totalSize,
  required String etag,
  required String lastModified,
  required String contentType,
  required int sliceDelayBytes,
  required int sliceDelayMs,
}) async {
  final rangeHeader = req.headers.value('range');
  req.response.headers.set('accept-ranges', 'bytes');
  req.response.headers.set('etag', etag);
  req.response.headers.set('last-modified', lastModified);
  req.response.headers.set('content-type', contentType);

  if (req.method == 'HEAD') {
    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentLength = totalSize;
    await req.response.close();
    return;
  }

  var closed = false;
  req.response.done.then((_) => closed = true).catchError((_) => closed = true);

  if (rangeHeader != null) {
    final parsed = _parseRangeHeader(rangeHeader, totalSize);
    if (parsed == null) {
      req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      req.response.headers.set('content-range', 'bytes */$totalSize');
      await req.response.close();
      return;
    }
    final length = parsed.end - parsed.start + 1;
    req.response.statusCode = HttpStatus.partialContent;
    req.response.headers.contentLength = length;
    req.response.headers
        .set('content-range', 'bytes ${parsed.start}-${parsed.end}/$totalSize');

    var offset = parsed.start;
    final endInclusive = parsed.end;
    while (offset <= endInclusive && !closed) {
      final chunkLen = math.min(sliceDelayBytes, endInclusive - offset + 1);
      final data = _generateRangeBytes(offset, chunkLen);
      try {
        req.response.add(data);
        await req.response.flush();
      } catch (_) {
        break;
      }
      offset += chunkLen;
      if (sliceDelayMs > 0 && length > 16384 && offset <= endInclusive) {
        await Future<void>.delayed(Duration(milliseconds: sliceDelayMs));
      }
    }
    try {
      await req.response.close();
    } catch (_) {}
    return;
  }

  req.response.statusCode = HttpStatus.ok;
  req.response.headers.contentLength = totalSize;
  var offset = 0;
  while (offset < totalSize && !closed) {
    final chunkLen = math.min(sliceDelayBytes, totalSize - offset);
    final data = _generateRangeBytes(offset, chunkLen);
    try {
      req.response.add(data);
      await req.response.flush();
    } catch (_) {
      break;
    }
    offset += chunkLen;
    if (sliceDelayMs > 0 && offset < totalSize) {
      await Future<void>.delayed(Duration(milliseconds: sliceDelayMs));
    }
  }
  try {
    await req.response.close();
  } catch (_) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    HttpOverrides.global = null;
    ConnectivityPlatform.instance = _TestConnectivityPlatform();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.example.dmx/widget'),
      (methodCall) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (methodCall) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.dmx.app/media'),
      (methodCall) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (methodCall) async => null,
    );
  });

  group('HTTP Engine 50 MB Lifecycle & Durability Integration', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dmx_50mb_lifecycle_');
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider.instance;
      await settings.load();
      settings.autoRetryEnabled = false;
      settings.autoVerifyChecksum = false;
      settings.adaptiveThreads = false;
      settings.wifiOnly = false;
      settings.pauseOnCellular = false;
      settings.downloadOnlyWhileCharging = false;
      settings.httpsOnly = false;
      settings.vibration = false;
      settings.notificationsEnabled = false;
      settings.autoStart = false;
    });

    tearDown(() async {
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test(
      '50 MB multi-threaded lifecycle on 1.3 GB iconpng stream: '
      'start, pause, start, stop, cold app restart, expired/HTML link protection, '
      'rotated-ETag link update, and byte-for-byte verification',
      () async {
        const totalSize13Gb = 1395864371; // Exact 1.3 GiB
        const fiftyMb = 50 * 1024 * 1024;
        var v1ExpiredChallenge = false;

        final challengeBody = List<int>.filled(5278, 0x41);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        server.listen((req) async {
          final path = req.uri.path;
          if (path == '/v1/1.3GBiconpng') {
            if (v1ExpiredChallenge) {
              req.response.statusCode = HttpStatus.forbidden;
              req.response.headers.set('cf-mitigated', 'challenge');
              req.response.headers.set('server', 'cloudflare');
              req.response.headers
                  .set('content-type', 'text/html; charset=UTF-8');
              req.response.headers.contentLength = challengeBody.length;
              if (req.method != 'HEAD') {
                req.response.add(challengeBody);
              }
              await req.response.close();
              return;
            }
            await _serveDeterministicRange(
              req,
              totalSize: totalSize13Gb,
              etag: 'W/"cdn1-1395864371"',
              lastModified: 'Wed, 21 Oct 2026 07:28:00 GMT',
              contentType: 'image/png',
              sliceDelayBytes: 32 * 1024,
              sliceDelayMs: 1,
            );
            return;
          }

          if (path == '/bad-login') {
            req.response.statusCode = HttpStatus.ok;
            req.response.headers
                .set('content-type', 'text/html; charset=UTF-8');
            req.response.headers.contentLength = challengeBody.length;
            if (req.method != 'HEAD') {
              req.response.add(challengeBody);
            }
            await req.response.close();
            return;
          }

          if (path == '/v2/1.3GBiconpng') {
            await _serveDeterministicRange(
              req,
              totalSize: totalSize13Gb,
              etag: '"cdn2-strong-rotated"',
              lastModified: 'Thu, 22 Oct 2026 12:00:00 GMT',
              contentType: 'image/png',
              sliceDelayBytes: 32 * 1024,
              sliceDelayMs: 1,
            );
            return;
          }

          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
        });

        final baseUrl = 'http://127.0.0.1:${server.port}';
        final dbFile = File('${tempDir.path}/tasks_db.json');
        final saveDir = Directory('${tempDir.path}/downloads');
        await saveDir.create(recursive: true);

        final settings = SettingsProvider.instance;
        final permService = _TestPermissionService(saveDir.path);
        final db1 = _JsonDiskDatabaseService(dbFile);
        final engine1 = DownloadEngine(enableCleanupTimer: false);
        final provider1 = DownloadProvider(
          databaseService: db1,
          settingsProvider: settings,
          downloadEngine: engine1,
          permissionService: permService,
          enableBackgroundTimers: false,
        );
        await provider1.load(autoResume: false);

        final taskId = await provider1.addDownload(
          url: '$baseUrl/v1/1.3GBiconpng',
          name: '1.3GBiconpng.png',
          size: null,
          savePath: saveDir.path,
          threadCount: 8,
        );
        expect(taskId, isNotNull);
        final id = taskId!;

        try {
          // 1. Wait until >= 15 MB downloaded and fileSize resolves to true 1.3 GB.
          final at15Mb = await _waitForTaskCondition(
            provider1,
            id,
            (t) =>
                t.status == DownloadStatus.downloading &&
                t.fileSize == totalSize13Gb &&
                t.downloadedBytes >= 15 * 1024 * 1024,
            timeout: const Duration(seconds: 45),
            description: '15 MB progress on 1.3 GB stream',
          );
          expect(at15Mb.fileSize, totalSize13Gb);
          expect(at15Mb.downloadedBytes, greaterThanOrEqualTo(15 * 1024 * 1024));

          // 2. Pause and verify durable .dmxstate == UI task state & speed == 0.
          await provider1.pauseTask(id);
          final pausedTask = provider1.findTaskById(id)!;
          final pausedState =
              await StateStore.load(pausedTask.tempFilePath, taskId: id);
          expect(pausedTask.status, DownloadStatus.paused);
          expect(pausedTask.speed, 0);
          expect(pausedTask.eta, isNull);
          expect(pausedTask.fileSize, totalSize13Gb);
          expect(pausedState, isNotNull);
          expect(pausedState!.totalSize, totalSize13Gb);
          expect(pausedTask.downloadedBytes, pausedState.downloadedBytes);
          expect(pausedTask.downloadedBytes,
              greaterThanOrEqualTo(15 * 1024 * 1024));
          expect(pausedTask.downloadedBytes, lessThan(totalSize13Gb));

          // 3. Start (resume) via startTask -> advance to >= 25 MB -> Stop via stopTask.
          await provider1.startTask(id);
          await _waitForTaskCondition(
            provider1,
            id,
            (t) =>
                t.status == DownloadStatus.downloading &&
                t.downloadedBytes >= 25 * 1024 * 1024,
            timeout: const Duration(seconds: 45),
            description: '25 MB progress after startTask',
          );
          await provider1.stopTask(id);

          final stoppedTask = provider1.findTaskById(id)!;
          final stoppedState =
              await StateStore.load(stoppedTask.tempFilePath, taskId: id);
          expect(stoppedTask.status, DownloadStatus.paused);
          expect(stoppedTask.speed, 0);
          expect(stoppedTask.eta, isNull);
          expect(stoppedTask.fileSize, totalSize13Gb);
          expect(stoppedState, isNotNull);
          expect(stoppedTask.downloadedBytes, stoppedState!.downloadedBytes);
          expect(stoppedTask.downloadedBytes,
              greaterThanOrEqualTo(25 * 1024 * 1024));
          final exactSavedBytes = stoppedState.downloadedBytes;

          // 4. Cold App Restart: dispose provider1 + engine1, create fresh instances.
          provider1.dispose();
          engine1.dispose();

          final db2 = _JsonDiskDatabaseService(dbFile);
          final engine2 = DownloadEngine(enableCleanupTimer: false);
          final provider2 = DownloadProvider(
            databaseService: db2,
            settingsProvider: settings,
            downloadEngine: engine2,
            permissionService: permService,
            enableBackgroundTimers: false,
          );
          addTearDown(() {
            provider2.dispose();
            engine2.dispose();
          });

          await provider2.load(autoResume: false);
          final restarted = provider2.findTaskById(id)!;
          expect(restarted.status, DownloadStatus.paused);
          expect(restarted.speed, 0);
          expect(restarted.fileSize, totalSize13Gb);
          expect(restarted.downloadedBytes, exactSavedBytes);

          // 5. Switch /v1 to 403 Cf-Mitigated challenge and try resuming -> ZERO data loss.
          v1ExpiredChallenge = true;
          await provider2.startTask(id);
          final failedExpired = await _waitForTaskCondition(
            provider2,
            id,
            (t) => t.status == DownloadStatus.failed,
            timeout: const Duration(seconds: 20),
            description: '403 Cf-Mitigated failure on expired /v1 link',
          );
          expect(failedExpired.fileSize, totalSize13Gb);
          expect(failedExpired.downloadedBytes, exactSavedBytes);
          expect(
            (await StateStore.load(failedExpired.tempFilePath, taskId: id))!
                .downloadedBytes,
            exactSavedBytes,
          );

          // 6. Update URL to /bad-login (200 OK text/html 5278 B) -> ZERO data loss.
          await provider2.updateTaskUrlAndResume(id, '$baseUrl/bad-login');
          final failedHtml = await _waitForTaskCondition(
            provider2,
            id,
            (t) => t.status == DownloadStatus.failed,
            timeout: const Duration(seconds: 20),
            description: 'HTML failure on /bad-login link update',
          );
          expect(failedHtml.fileSize, totalSize13Gb);
          expect(failedHtml.downloadedBytes, exactSavedBytes);
          expect(
            (await StateStore.load(failedHtml.tempFilePath, taskId: id))!
                .downloadedBytes,
            exactSavedBytes,
          );

          // 7. Update URL to /v2/1.3GBiconpng with rotated ETag & Last-Modified -> resume to >= 50 MB!
          await provider2.updateTaskUrlAndResume(
            id,
            '$baseUrl/v2/1.3GBiconpng?sig=rotated2',
          );
          await _waitForTaskCondition(
            provider2,
            id,
            (t) =>
                t.status == DownloadStatus.downloading &&
                t.downloadedBytes >= fiftyMb,
            timeout: const Duration(seconds: 60),
            description: '50 MB progress on rotated /v2 link',
          );
          await provider2.pauseTask(id);

          final finalTask = provider2.findTaskById(id)!;
          final finalState =
              await StateStore.load(finalTask.tempFilePath, taskId: id);
          expect(finalTask.status, DownloadStatus.paused);
          expect(finalTask.speed, 0);
          expect(finalTask.eta, isNull);
          expect(finalTask.fileSize, totalSize13Gb);
          expect(finalState, isNotNull);
          expect(finalState!.totalSize, totalSize13Gb);
          expect(finalTask.downloadedBytes, finalState.downloadedBytes);
          expect(finalTask.downloadedBytes, greaterThanOrEqualTo(fiftyMb));

          // 8. Verify EVERY downloaded byte across EVERY chunk matches deterministic bytes!
          final tempFile = File(finalTask.tempFilePath);
          expect(await tempFile.exists(), isTrue);
          final raf = await tempFile.open(mode: FileMode.read);
          try {
            var totalVerifiedBytes = 0;
            final headerCheck = Uint8List(_pngHeader.length);
            await raf.setPosition(0);
            await raf.readInto(headerCheck);
            expect(headerCheck, equals(_pngHeader));

            for (final chunk in finalState.chunks) {
              if (chunk.downloaded <= 0) continue;
              var remaining = chunk.downloaded;
              var filePos = chunk.start;
              const blockSize = 256 * 1024;
              while (remaining > 0) {
                final toRead = math.min(blockSize, remaining);
                final actualBuf = Uint8List(toRead);
                await raf.setPosition(filePos);
                final readCount = await raf.readInto(actualBuf);
                expect(readCount, toRead,
                    reason:
                        'Short read at offset $filePos in chunk ${chunk.start}-${chunk.end}');
                for (var i = 0; i < readCount; i++) {
                  final expected = _deterministicByteAt(filePos + i);
                  if (actualBuf[i] != expected) {
                    fail(
                      'Byte mismatch at offset ${filePos + i}: '
                      'expected $expected, got ${actualBuf[i]}',
                    );
                  }
                }
                filePos += readCount;
                remaining -= readCount;
                totalVerifiedBytes += readCount;
              }
            }
            expect(totalVerifiedBytes, finalState.downloadedBytes);
            expect(totalVerifiedBytes, greaterThanOrEqualTo(fiftyMb));
          } finally {
            await raf.close();
          }
        } finally {
          provider1.dispose();
          engine1.dispose();
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'Full 0% -> 100% multi-threaded completion across pause, cold app restart, '
      'and rotated-ETag link update with SHA-256 verification',
      () async {
        const totalSize12Mb = 12 * 1024 * 1024;
        final fullPayload = _generateRangeBytes(0, totalSize12Mb);
        final expectedSha256 = sha256.convert(fullPayload).toString();

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        server.listen((req) async {
          if (req.uri.path == '/v1/archive.bin') {
            await _serveDeterministicRange(
              req,
              totalSize: totalSize12Mb,
              etag: 'W/"v1-12mb"',
              lastModified: 'Wed, 21 Oct 2026 07:28:00 GMT',
              contentType: 'application/octet-stream',
              sliceDelayBytes: 16 * 1024,
              sliceDelayMs: 25,
            );
            return;
          }
          if (req.uri.path == '/v2/archive.bin') {
            await _serveDeterministicRange(
              req,
              totalSize: totalSize12Mb,
              etag: '"v2-strong-12mb"',
              lastModified: 'Thu, 22 Oct 2026 12:00:00 GMT',
              contentType: 'application/octet-stream',
              sliceDelayBytes: 256 * 1024,
              sliceDelayMs: 0,
            );
            return;
          }
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
        });

        final baseUrl = 'http://127.0.0.1:${server.port}';
        final dbFile = File('${tempDir.path}/tasks_12mb_db.json');
        final saveDir = Directory('${tempDir.path}/downloads_12mb');
        await saveDir.create(recursive: true);

        final settings = SettingsProvider.instance;
        final permService = _TestPermissionService(saveDir.path);
        final db1 = _JsonDiskDatabaseService(dbFile);
        final engine1 = DownloadEngine(enableCleanupTimer: false);
        final provider1 = DownloadProvider(
          databaseService: db1,
          settingsProvider: settings,
          downloadEngine: engine1,
          permissionService: permService,
          enableBackgroundTimers: false,
        );
        await provider1.load(autoResume: false);

        final taskId = (await provider1.addDownload(
          url: '$baseUrl/v1/archive.bin',
          name: 'archive.bin',
          size: null,
          savePath: saveDir.path,
          threadCount: 4,
          expectedSha256: expectedSha256,
        ))!;

        await _waitForTaskCondition(
          provider1,
          taskId,
          (t) =>
              t.status == DownloadStatus.downloading &&
              t.downloadedBytes >= 3 * 1024 * 1024,
          timeout: const Duration(seconds: 30),
          description: '3 MB progress on 12 MB download',
        );
        await provider1.pauseTask(taskId);

        final pausedTask = provider1.findTaskById(taskId)!;
        final pausedState =
            await StateStore.load(pausedTask.tempFilePath, taskId: taskId);
        expect(pausedTask.fileSize, totalSize12Mb);
        expect(pausedTask.downloadedBytes, pausedState!.downloadedBytes);
        final savedBytes = pausedState.downloadedBytes;

        // Cold app restart
        provider1.dispose();
        engine1.dispose();

        final db2 = _JsonDiskDatabaseService(dbFile);
        final engine2 = DownloadEngine(enableCleanupTimer: false);
        final provider2 = DownloadProvider(
          databaseService: db2,
          settingsProvider: settings,
          downloadEngine: engine2,
          permissionService: permService,
          enableBackgroundTimers: false,
        );
        addTearDown(() {
          provider2.dispose();
          engine2.dispose();
        });

        await provider2.load(autoResume: false);
        final restarted = provider2.findTaskById(taskId)!;
        expect(restarted.fileSize, totalSize12Mb);
        expect(restarted.downloadedBytes, savedBytes);

        // Update link to /v2/archive.bin with rotated strong ETag and complete
        await provider2.updateTaskUrlAndResume(
          taskId,
          '$baseUrl/v2/archive.bin?token=new',
        );
        final completed = await _waitForTaskCondition(
          provider2,
          taskId,
          (t) => t.status == DownloadStatus.completed,
          timeout: const Duration(seconds: 45),
          description: 'completion on rotated 12 MB link',
        );

        expect(completed.fileSize, totalSize12Mb);
        expect(completed.downloadedBytes, totalSize12Mb);
        expect(completed.speed, 0);

        final finalFile = File(completed.localFilePath);
        expect(await finalFile.exists(), isTrue);
        expect(await finalFile.length(), totalSize12Mb);
        expect(await File(completed.tempFilePath).exists(), isFalse);
        expect(
          await File(StateStore.pathFor(completed.tempFilePath, taskId: taskId))
              .exists(),
          isFalse,
        );

        final actualDigest =
            sha256.convert(await finalFile.readAsBytes()).toString();
        expect(actualDigest, expectedSha256);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'Cloudflare 403 Cf-Mitigated challenge guard (matching testfile.org/1.3GBiconpng headers)',
      () async {
        final htmlChallenge = List<int>.filled(5278, 0x3C);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        server.listen((req) async {
          req.response.statusCode = HttpStatus.forbidden;
          req.response.headers.set('server', 'cloudflare');
          req.response.headers.set('cf-mitigated', 'challenge');
          req.response.headers.set('content-type', 'text/html; charset=UTF-8');
          req.response.headers.contentLength = htmlChallenge.length;
          if (req.method != 'HEAD') {
            req.response.add(htmlChallenge);
          }
          await req.response.close();
        });

        final engine = DownloadEngine(enableCleanupTimer: false);
        addTearDown(() => engine.dispose());

        final meta = await engine.resolveMetadata(
          url: 'http://127.0.0.1:${server.port}/1.3GBiconpng',
        );
        expect(meta.fileSize, 0);
        expect(meta.supportsResume, isFalse);
      },
    );

    test(
      'pauseTask racing with transfer completion preserves clean completed or resumable paused state',
      () async {
        const totalSize1Mb = 1024 * 1024;
        final fullPayload = _generateRangeBytes(0, totalSize1Mb);
        final expectedSha256 = sha256.convert(fullPayload).toString();

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        server.listen((req) async {
          if (req.uri.path == '/fast-1mb.bin') {
            await _serveDeterministicRange(
              req,
              totalSize: totalSize1Mb,
              etag: '"fast-1mb"',
              lastModified: 'Wed, 21 Oct 2026 07:28:00 GMT',
              contentType: 'application/octet-stream',
              sliceDelayBytes: 128 * 1024,
              sliceDelayMs: 0,
            );
            return;
          }
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
        });

        final baseUrl = 'http://127.0.0.1:${server.port}';
        final dbFile = File('${tempDir.path}/tasks_race_db.json');
        final saveDir = Directory('${tempDir.path}/downloads_race');
        await saveDir.create(recursive: true);

        final db = _JsonDiskDatabaseService(dbFile);
        final engine = DownloadEngine(enableCleanupTimer: false);
        final provider = DownloadProvider(
          databaseService: db,
          settingsProvider: SettingsProvider.instance,
          downloadEngine: engine,
          permissionService: _TestPermissionService(saveDir.path),
          enableBackgroundTimers: false,
        );
        addTearDown(() {
          provider.dispose();
          engine.dispose();
        });
        await provider.load(autoResume: false);

        final id = (await provider.addDownload(
          url: '$baseUrl/fast-1mb.bin',
          name: 'fast-1mb.bin',
          size: null,
          savePath: saveDir.path,
          threadCount: 4,
          expectedSha256: expectedSha256,
        ))!;

        await _waitForTaskCondition(
          provider,
          id,
          (t) =>
              t.status == DownloadStatus.completed ||
              t.downloadedBytes >= 256 * 1024,
          timeout: const Duration(seconds: 20),
          description: 'progress or completion on fast 1 MB download',
        );
        await provider.pauseTask(id);

        final task = provider.findTaskById(id)!;
        expect(
          task.status == DownloadStatus.completed ||
              task.status == DownloadStatus.paused,
          isTrue,
        );
        if (task.status == DownloadStatus.completed) {
          final finalFile = File(task.localFilePath);
          expect(await finalFile.exists(), isTrue);
          expect(await finalFile.length(), totalSize1Mb);
          expect(task.fileSize, totalSize1Mb);
          expect(task.downloadedBytes, totalSize1Mb);
          expect(
            sha256.convert(await finalFile.readAsBytes()).toString(),
            expectedSha256,
          );
        } else {
          final state = await StateStore.load(task.tempFilePath, taskId: id);
          expect(state, isNotNull);
          expect(await File(task.tempFilePath).exists(), isTrue);
          expect(task.downloadedBytes, state!.downloadedBytes);
        }
      },
    );
  });
}
