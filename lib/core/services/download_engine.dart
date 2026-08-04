import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

import 'package:dmx/core/services/bandwidth_governor.dart';
import 'package:dmx/core/services/connection_manager.dart';
import 'package:dmx/core/services/download_journal.dart';
import '../http_overrides.dart';
import 'package:dmx/core/services/diagnostic_service.dart';
import 'package:dmx/core/services/mirror_failover.dart';
import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/retry_interceptor.dart';
import 'package:dmx/core/services/torrent_service.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';
import '../../features/settings/provider/settings_provider.dart';
import 'engines/http_download_engine.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import '../utils/bencode_decoder.dart';
import '../utils/file_utils.dart';
import '../utils/url_utils.dart';

part 'download_isolate_pool.dart';

class DownloadMetadata {
  final String fileName;
  final String category;
  final int fileSize;
  final bool supportsResume;
  final List<Map<String, dynamic>>? torrentFiles;
  final int? torrentId;

  const DownloadMetadata({
    required this.fileName,
    required this.category,
    required this.fileSize,
    required this.supportsResume,
    this.torrentFiles,
    this.torrentId,
  });
}

class IsolateSpawnTimeoutException implements Exception {
  final String message;

  const IsolateSpawnTimeoutException([
    this.message = 'Download engine failed to initialize. Please retry.',
  ]);

  @override
  String toString() => 'IsolateSpawnTimeoutException: $message';
}

/// Thrown when there is not enough free disk space for a download. Marked as
/// non-retryable by the orchestrator so the task fails fast with a clear
/// user-facing message instead of a confusing mid-download error.
class InsufficientStorageException implements Exception {
  final String message;

  const InsufficientStorageException([
    this.message =
        'Not enough storage space to download this file. Please free up space and try again.',
  ]);

  @override
  String toString() => 'InsufficientStorageException: $message';
}

class DownloadProgress {
  final int downloadedBytes;
  final int fileSize;
  final double speed;
  final int? eta;
  final List<double>? chunks;
  final String? fileName;
  final List<Map<String, dynamic>>? torrentFiles;
  final bool? supportsResume;
  final String? statusMessage;

  DownloadProgress({
    required this.downloadedBytes,
    required this.fileSize,
    required this.speed,
    required this.eta,
    this.chunks,
    this.fileName,
    this.torrentFiles,
    this.supportsResume,
    this.statusMessage,
  });
}

class DownloadEngine {
  // Progress report interval: 500ms = max 2 updates/sec per task
  // This reduces UI thread pressure when multiple downloads are active.
  static const int _progressReportIntervalMs = 500;
  static const int _stateSaveIntervalMs = 2000;
  static const int _isolatePoolSize = 4;

  int get effectiveProgressReportIntervalMs =>
      PowerMonitor.throttleFactor < 1.0 ? 1000 : _progressReportIntervalMs;


  final List<CancelToken> _activeCancelTokens = [];

  /// A delay that completes immediately if [cancelToken] is cancelled.
  /// Prevents the engine from being stuck in a sleep when the user
  /// cancels or deletes a download.
  static Future<void> _cancellableDelay(
    Duration duration, {
    required CancelToken cancelToken,
  }) async {
    if (cancelToken.isCancelled) return;
    final completer = Completer<void>();
    final timer = Timer(duration, () {
      if (!completer.isCompleted) completer.complete();
    });
    final sub = cancelToken.whenCancel.then((_) {
      timer.cancel();
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;
    await sub;
  }

  DownloadIsolatePool? _pool;
  bool _dohEnabled;
  String _dohProvider;
  Future<DownloadIsolatePool>? _poolInit;
  final _httpEngine = HttpDownloadEngine();

  final Set<int> _activeTorrentIds = <int>{};

  final Dio _sharedDio;
  final Set<Dio> _activeDioClients = {};
  final Set<Dio> _reservedDioClients = {};
  final Map<Dio, DateTime> _dioClientCreationTimes = {};
  final Map<Dio, Set<String>> _activeDownloadsPerClient = {};

  Timer? _cleanupTimer;
  bool _closed = false;

  DownloadEngine({
    Dio? dio,
    bool enableCleanupTimer = true,
    bool dohEnabled = true,
    String dohProvider = 'dns.adguard.com',
  })  : _sharedDio = dio ?? Dio(),
        _dohEnabled = dohEnabled,
        _dohProvider = dohProvider {
    if (enableCleanupTimer) {
      _cleanupTimer = Timer.periodic(const Duration(seconds: 120), (_) {
        if (_closed) return;
        final now = DateTime.now();

        _activeDioClients.removeWhere((client) {
          final isReserved = _reservedDioClients.contains(client);
          final activeDownloads = _activeDownloadsPerClient[client];
          final hasActiveDownloads =
              activeDownloads != null && activeDownloads.isNotEmpty;

          final createdAt = _dioClientCreationTimes[client];
          final age =
              createdAt != null ? now.difference(createdAt) : Duration.zero;

          if (isReserved) {
            if (!hasActiveDownloads && age > const Duration(minutes: 10)) {
              debugPrint(
                '[DMX] Cleanup timer WARNING: force-closing reserved Dio client '
                'idle for over 10 minutes (${age.inMinutes}m old)',
              );
              try {
                client.close(force: true);
              } catch (e) {
                debugPrint(
                  '[DMX] Failed to close reserved client during cleanup: $e',
                );
              }
              _reservedDioClients.remove(client);
              _dioClientCreationTimes.remove(client);
              _activeDownloadsPerClient.remove(client);
              return true;
            }
            return false;
          }

          if (hasActiveDownloads) {
            return false;
          }

          if (age > const Duration(minutes: 5)) {
            debugPrint(
              '[DMX] Cleanup timer: closing orphaned Dio client '
              '(${age.inSeconds}s old)',
            );

            try {
              client.close(force: true);
            } catch (e) {
              debugPrint('[DMX] Failed to close client during cleanup: $e');
            }

            _dioClientCreationTimes.remove(client);
            _activeDownloadsPerClient.remove(client);
            return true;
          }

          return false;
        });
      });
    }
  }

  /// Updates DoH settings for subsequent worker jobs and future respawns.
  /// Existing sockets retain their current connection; new jobs receive the
  /// latest settings through the worker command.
  void updateDohSettings(bool enabled, String provider) {
    _dohEnabled = enabled;
    _dohProvider = provider;
    _pool?.updateDohSettings(enabled, provider);
  }

  Future<DownloadIsolatePool> _ensurePool() {
    final existing = _pool;
    if (existing != null) return Future.value(existing);

    return _poolInit ??= () async {
      final pool = DownloadIsolatePool(
        size: _isolatePoolSize,
        dohEnabled: _dohEnabled,
        dohProvider: _dohProvider,
      );
      await pool.init();
      _pool = pool;
      return pool;
    }();
  }

  @visibleForTesting
  bool isLikelyHtmlResponse(String? contentType) {
    final normalized = (contentType ?? '').toLowerCase();
    return normalized.contains('text/html') ||
        normalized.contains('application/xhtml');
  }

  Dio _buildIsolatedClient({
    String? url,
    String? customUserAgent,
    String? referer,
    bool enableProxy = false,
    String? proxyAddress,
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
    bool bypassSSL = false,
    String? cookies,
    String? oauthToken,
  }) {
    final client = Dio();
    client.interceptors.add(ProfessionalRetryInterceptor(client));

    client.options.connectTimeout = const Duration(seconds: 30);
    client.options.sendTimeout = const Duration(seconds: 60);
    client.options.receiveTimeout = const Duration(seconds: 60);

    final uri = url != null ? Uri.tryParse(url) : null;
    final host = uri?.host.toLowerCase() ?? '';

    final isYoutubeUrl = host.contains('youtube.com') ||
        host == 'youtu.be' ||
        host.endsWith('.googlevideo.com');

    if (isYoutubeUrl) {
      client.options.headers['Origin'] = 'https://www.youtube.com';
      client.options.headers['Referer'] =
          (referer != null && referer.isNotEmpty)
              ? referer
              : 'https://www.youtube.com/';
      client.options.headers['User-Agent'] =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

      if (oauthToken != null && oauthToken.isNotEmpty) {
        client.options.headers['Authorization'] = 'Bearer $oauthToken';
      }
    } else if (customUserAgent != null && customUserAgent.trim().isNotEmpty) {
      client.options.headers['User-Agent'] = customUserAgent.trim();
    } else {
      client.options.headers['User-Agent'] =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
    }

    if (referer != null &&
        referer.isNotEmpty &&
        !client.options.headers.containsKey('Referer')) {
      client.options.headers['Referer'] = referer;
    }

    if (cookies != null && cookies.isNotEmpty) {
      client.options.headers['Cookie'] = cookies;
    }

    if (client.httpClientAdapter is IOHttpClientAdapter) {
      final adapter = client.httpClientAdapter as IOHttpClientAdapter;

      final String proxyHostResolved = (enableProxy &&
              proxyHost != null &&
              proxyHost.trim().isNotEmpty)
          ? proxyHost.trim()
          : (enableProxy && proxyAddress != null && proxyAddress.contains(':')
              ? proxyAddress.split(':')[0].trim()
              : (enableProxy ? proxyAddress?.trim() ?? '' : ''));

      final int port = (enableProxy && proxyPort != null && proxyPort > 0)
          ? proxyPort
          : (enableProxy && proxyAddress != null && proxyAddress.contains(':')
              ? int.tryParse(proxyAddress.split(':')[1]) ?? 8080
              : 8080);

      final downloadUri = url != null ? Uri.tryParse(url) : null;
      final downloadHost = downloadUri?.host;
      // User-controlled opt-in via the "Bypass SSL" settings toggle.
      final effectiveBypassSSL = bypassSSL;

      adapter.createHttpClient = () {
        final httpClient = HttpClient();

        if (enableProxy && proxyHostResolved.isNotEmpty) {
          httpClient.findProxy = (uri) {
            return 'PROXY $proxyHostResolved:$port';
          };

          if (proxyUsername != null && proxyUsername.isNotEmpty) {
            httpClient.authenticateProxy = (h, p, scheme, realm) async {
              httpClient.addProxyCredentials(
                h,
                p,
                realm ?? '',
                HttpClientBasicCredentials(proxyUsername, proxyPassword ?? ''),
              );
              return true;
            };
          }
        }

        if (effectiveBypassSSL) {
          debugPrint(
            '[DMX] SSL verification is BYPASSED for host $downloadHost',
          );
          debugPrint(
            '[DMX AUDIT] SSL bypass active for URL: ${_redactUrl(url)}',
          );

          httpClient.badCertificateCallback = (cert, h, p) => true;
        }

        return httpClient;
      };
    }

    _activeDioClients.add(client);
    _reservedDioClients.add(client);
    _dioClientCreationTimes[client] = DateTime.now();
    _activeDownloadsPerClient[client] = {};

    return client;
  }

  /// Estimate optimal thread count using a lightweight HEAD request range check
  /// instead of downloading actual data bytes.
  Future<int> estimateOptimalThreads({
    required String url,
    required int requestedThreads,
    required int fileSize,
    Dio? dio,
    CancelToken? cancelToken,
  }) async {
    if (requestedThreads <= 1) return 1;
    if (fileSize > 0 && fileSize < 512 * 1024) return 1;

    final client = dio ?? _sharedDio;
    try {
      final response = await client.head(
        url,
        cancelToken: cancelToken,
        options: Options(
          headers: const {'Range': 'bytes=0-0'},
          validateStatus: (_) => true,
        ),
      );

      final acceptRanges = response.headers.value('accept-ranges');
      if (acceptRanges == 'none') return 1;

      final connectionHeader = response.headers.value('connection');
      if (connectionHeader?.toLowerCase() == 'close') return 1;

      return requestedThreads;
    } catch (e, st) {
      Logger(
        'download_engine',
      ).warning('[download_engine] operation failed', e, st);
      return requestedThreads;
    }
  }

  /// Cleans up temporary/orphan files associated with a download task upon cancellation.
  static Future<void> cleanupOrphanFiles(String tempFilePath) async {
    if (tempFilePath.isEmpty) return;
    try {
      final file = File(tempFilePath);
      final dir = file.parent;
      if (!await dir.exists()) return;

      final baseName = p.basenameWithoutExtension(tempFilePath);
      final patterns = [
        '$baseName.dmxpart',
        '$baseName.dmxstate',
        '$baseName.journal',
        '$baseName.audio',
        '$baseName.merged.mp4',
        '$baseName.merged.mkv',
      ];

      for (final name in patterns) {
        final f = File(p.join(dir.path, name));
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (e) {
            debugPrint(
              '[DownloadEngine] Failed to delete orphan file ${f.path}: $e',
            );
          }
        }
      }

      await for (final entity in dir.list()) {
        if (entity is File &&
            entity.path.contains('$baseName.part') &&
            entity.path != tempFilePath) {
          try {
            await entity.delete();
          } catch (e, st) {
            Logger(
              'download_engine',
            ).warning('[download_engine] operation failed', e, st);
          }
        }
      }
    } catch (e) {
      debugPrint('[DownloadEngine] Cleanup orphan files error: $e');
    }
  }

  Future<DownloadMetadata> resolveMetadata({
    required String url,
    String? requestedFileName,
    String? customUserAgent,
    String? referer,
    bool enableProxy = false,
    String? proxyAddress,
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
    bool bypassSSL = false,
    String? cookies,
    String? oauthToken,
    CancelToken? cancelToken,
  }) async {
    final isTorrent = isTorrentUrl(url, fileName: requestedFileName);

    if (isTorrent) {
      var fileName = requestedFileName?.trim().isNotEmpty == true
          ? safeFileName(requestedFileName!.trim())
          : 'torrent_download.zip';
      var fileSize = 0;
      List<Map<String, dynamic>>? torrentFiles;

      if (url.startsWith('magnet:')) {
        final magnetParams = parseMagnetUrl(url);
        final magnetName = magnetParams['name'];

        final resolvedName = requestedFileName?.trim().isNotEmpty == true
            ? safeFileName(requestedFileName!.trim())
            : (magnetName != null && magnetName.trim().isNotEmpty
                ? safeFileName(magnetName.trim())
                : 'torrent_download.zip');

        String tempDir = '';

        if (!kIsWeb) {
          try {
            final directory = await getTemporaryDirectory();
            tempDir = directory.path;
          } catch (e) {
            debugPrint('Failed to get temporary directory: $e');
            throw StateError(
              'Cannot resolve temporary directory for Torrent download: $e',
            );
          }
        }

        final torrentId = TorrentService.addMagnet(url, tempDir);
        TorrentService.resumeTorrent(torrentId);

        final completer = Completer<DownloadMetadata>();
        StreamSubscription? sub;
        Timer? metadataTimer;

        // Handle cancellation
        void handleCancel() {
          sub?.cancel();
          metadataTimer?.cancel();
          try {
            TorrentService.pauseTorrent(torrentId);
            TorrentService.removeTorrent(torrentId, deleteFiles: false);
          } catch (e) {
            debugPrint(
              '[DMX] Error cleaning up torrent during cancellation: $e',
            );
          }
          if (!completer.isCompleted) {
            completer.completeError(
              DioException(
                requestOptions: RequestOptions(path: url),
                type: DioExceptionType.cancel,
                message: 'Download cancelled during metadata resolution',
              ),
            );
          }
        }

        cancelToken?.whenCancel.then((_) => handleCancel());
        if (cancelToken?.isCancelled == true) {
          handleCancel();
          return completer.future;
        }

        sub = TorrentService.torrentUpdates.listen((torrents) {
          final torrent = torrents[torrentId];

          if (torrent != null && torrent.hasMetadata) {
            sub?.cancel();

            final files = TorrentService.getFiles(torrentId);
            final resolvedFiles = files
                .map(
                  (f) => {
                    'name': f.name,
                    'length': f.size,
                    'selected': true,
                    'priority': 4,
                    'downloadedBytes': 0,
                    'speed': 0.0,
                  },
                )
                .toList();

            final totalSize = resolvedFiles.fold(
              0,
              (sum, f) => sum + (f['length'] as int),
            );

            if (!completer.isCompleted) {
              metadataTimer?.cancel();

              try {
                TorrentService.pauseTorrent(torrentId);
                TorrentService.removeTorrent(torrentId, deleteFiles: false);
              } catch (e) {
                debugPrint(
                  '[DMX] Error pausing/removing torrent during metadata parsing: $e',
                );
              }

              completer.complete(
                DownloadMetadata(
                  fileName: torrent.name,
                  category: categoryFromFileName(torrent.name),
                  fileSize: totalSize,
                  supportsResume: true,
                  torrentFiles: resolvedFiles,
                  torrentId: null,
                ),
              );
            }
          }
        });

        metadataTimer = Timer(const Duration(seconds: 60), () {
          if (!completer.isCompleted) {
            sub?.cancel();

            try {
              TorrentService.pauseTorrent(torrentId);
              TorrentService.removeTorrent(torrentId, deleteFiles: false);
            } catch (e) {
              debugPrint(
                '[DMX] Error pausing/removing torrent during metadata timeout: $e',
              );
            }

            completer.complete(
              DownloadMetadata(
                fileName: resolvedName,
                category: 'Torrent',
                fileSize: 0,
                supportsResume: true,
                torrentFiles: null,
                torrentId: null,
              ),
            );
          }
        });

        return completer.future;
      } else if (url.startsWith('file://')) {
        final filePath = Uri.parse(url).toFilePath();
        final file = File(filePath);

        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final meta = await compute(BencodeDecoder.parseTorrentBytes, bytes);

          if (meta != null) {
            fileName = meta['name'] ?? fileName;
            fileSize = meta['length'] ?? fileSize;

            torrentFiles = (meta['files'] as List? ?? []).map((f) {
              final fileMap = f as Map;
              return {
                'name': fileMap['name'] as String? ?? '',
                'length': fileMap['length'] as int? ?? 0,
                'selected': true,
                'priority': 4,
                'downloadedBytes': 0,
                'speed': 0.0,
              };
            }).toList();

            if (fileSize == 0) {
              fileSize = torrentFiles.fold(
                0,
                (sum, f) => sum + ((f['length'] as int?) ?? 0),
              );
            }
          }
        }

        return DownloadMetadata(
          fileName: fileName,
          category: 'Torrent',
          fileSize: fileSize,
          supportsResume: true,
          torrentFiles: torrentFiles,
        );
      }
    }

    final punyUrl = convertIdnToPunycode(url);

    var fileName = requestedFileName?.trim().isNotEmpty == true
        ? safeFileName(requestedFileName!.trim())
        : fileNameFromUrl(punyUrl);

    var fileSize = 0;

    final uri = Uri.tryParse(punyUrl);
    final host = uri?.host.toLowerCase() ?? '';

    final isYoutube = host.contains('youtube.com') ||
        host == 'youtu.be' ||
        host.endsWith('.googlevideo.com');

    var supportsResume = isYoutube;

    final isolatedDio = _buildIsolatedClient(
      url: punyUrl,
      customUserAgent: customUserAgent,
      referer: referer,
      enableProxy: enableProxy,
      proxyAddress: proxyAddress,
      proxyHost: proxyHost,
      proxyPort: proxyPort,
      proxyUsername: proxyUsername,
      proxyPassword: proxyPassword,
      bypassSSL: bypassSSL,
      cookies: cookies,
      oauthToken: oauthToken,
    );

    try {
      final response = await isolatedDio.head<dynamic>(
        punyUrl,
        cancelToken: cancelToken,
        options: Options(followRedirects: true, validateStatus: (_) => true),
      );

      final headerName = fileNameFromContentDisposition(response.headers);
      if (requestedFileName?.trim().isNotEmpty != true && headerName != null) {
        fileName = headerName;
      }

      final length = response.headers.value(Headers.contentLengthHeader);
      fileSize = int.tryParse(length ?? '') ?? 0;

      final acceptRanges =
          response.headers.value('accept-ranges')?.toLowerCase();

      if (acceptRanges != null) {
        supportsResume = acceptRanges == 'bytes';
      } else {
        supportsResume = isYoutube || response.statusCode == 206;
      }

      if (fileSize == 0 ||
          response.statusCode == 403 ||
          response.statusCode == 405 ||
          response.statusCode == 400) {
        try {
          final getResponse = await isolatedDio.get<ResponseBody>(
            punyUrl,
            cancelToken: cancelToken,
            options: Options(
              responseType: ResponseType.stream,
              followRedirects: true,
              headers: {'Range': 'bytes=0-0'},
              validateStatus: (_) => true,
            ),
          );

          if (getResponse.statusCode == 200 || getResponse.statusCode == 206) {
            final getHeaderName = fileNameFromContentDisposition(
              getResponse.headers,
            );

            if (requestedFileName?.trim().isNotEmpty != true &&
                getHeaderName != null) {
              fileName = getHeaderName;
            }

            final contentRange = getResponse.headers.value('content-range');
            if (contentRange != null) {
              final totalMatch = RegExp(r'/(\d+)').firstMatch(contentRange);
              if (totalMatch != null) {
                fileSize = int.tryParse(totalMatch.group(1)!) ?? 0;
              }
            }

            if (fileSize == 0) {
              final getLen = getResponse.headers.value(
                Headers.contentLengthHeader,
              );
              fileSize = int.tryParse(getLen ?? '') ?? 0;
            }

            supportsResume = isYoutube ||
                getResponse.statusCode == 206 ||
                getResponse.headers.value('accept-ranges') == 'bytes';

            await getResponse.data?.stream.listen((_) {}).cancel();
          }
        } catch (e) {
          debugPrint(
            '[DownloadEngine] resolveMetadata ranged GET probe failed: $e',
          );
        }
      }
    } catch (e) {
      debugPrint('HEAD request failed for ${_redactUrl(punyUrl)}: $e');
    } finally {
      _reservedDioClients.remove(isolatedDio);
      _activeDioClients.remove(isolatedDio);
      _dioClientCreationTimes.remove(isolatedDio);
      isolatedDio.close(force: true);
    }

    return DownloadMetadata(
      fileName: fileName,
      category: categoryFromFileName(fileName),
      fileSize: fileSize,
      supportsResume: supportsResume,
    );
  }

  void updateSpeedLimit(int bytesPerSecond, int activeCount) {
    TorrentService.setDownloadLimit(bytesPerSecond);
    _pool?.updateSpeedLimit(bytesPerSecond, activeCount);
  }

  /// Low-storage warning threshold (500 MB free).
  static const int _lowSpaceThresholdBytes = 500 * 1024 * 1024;

  /// Checks if there is enough free disk space for a download of
  /// [requiredBytes]. A 10% safety margin is applied. Returns true when the
  /// space is sufficient OR when the check cannot determine the free space
  /// (graceful fallback — never blocks a download on a failed probe).
  Future<bool> hasEnoughDiskSpace(String savePath, int requiredBytes) async {
    try {
      // Add 10% margin for safety
      final requiredWithMargin = (requiredBytes * 1.1).toInt();

      final dir = Directory(savePath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final stat = await _getDiskSpace(savePath);
      if (stat == null) return true; // Can't determine, allow
      return stat.freeBytes >= requiredWithMargin;
    } catch (e) {
      debugPrint('[DownloadEngine] Disk space check failed: $e');
      return true; // Don't block download if check fails
    }
  }

  /// Proactively logs a warning when free space on the target volume drops
  /// below the 500 MB threshold. Never throws.
  Future<void> checkLowStorageWarning(String savePath) async {
    try {
      final spaceInfo = await _getDiskSpace(savePath);
      if (spaceInfo != null &&
          spaceInfo.freeBytes < _lowSpaceThresholdBytes) {
        debugPrint(
          '[DownloadEngine] WARNING: Low disk space: '
          '${(spaceInfo.freeBytes / 1024 / 1024).toStringAsFixed(0)} MB remaining',
        );
      }
    } catch (_) {}
  }

  Future<_DiskSpaceInfo?> _getDiskSpace(String path) async {
    try {
      if (Platform.isAndroid || Platform.isLinux || Platform.isMacOS) {
        final result = await Process.run('df', ['-B1', path]);
        if (result.exitCode != 0) return null;
        final lines = (result.stdout as String).trim().split('\n');
        if (lines.length < 2) return null;
        final parts = lines[1].trim().split(RegExp(r'\s+'));
        if (parts.length < 4) return null;
        final available = int.tryParse(parts[3]) ?? 0;
        return _DiskSpaceInfo(freeBytes: available);
      }
      // iOS / Windows / unknown: no reliable CLI probe available. Return null
      // so callers fall back to allowing the download.
      return null;
    } catch (e) {
      debugPrint('[DownloadEngine] _getDiskSpace failed for $path: $e');
      return null;
    }
  }

  Future<void> download({
    required String taskId,
    required String url,
    required String tempFilePath,
    required String localFilePath,
    required int knownFileSize,
    required bool supportsResume,
    required CancelToken cancelToken,
    required ValueChangedProgress onProgress,
    required int Function() speedLimitBytesPerSecond,
    required int Function() activeDownloadCount,
    int threadCount = 0, // 0 = use default
    String? customUserAgent,
    String? referer,
    bool enableProxy = false,
    String? proxyAddress,
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
    bool bypassSSL = false,
    String? cookies,
    String? oauthToken,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int? torrentId,
    bool isNameAutoGenerated = false,
    List<String>? mirrorUrls,
    bool adaptiveThreads = false,
    int speedLimitKbps = 0,
  }) async {
    _activeCancelTokens.add(cancelToken);

    // If threadCount > 0, override the task's threadCount
    final int defaultCount = SettingsProvider.instance.effectiveDefaultThreadCount;
    final int effectiveThreadCount = (threadCount > 0 ? threadCount : defaultCount)
        .clamp(1, PowerMonitor.maxAllowedThreads);


    int resolvedFileSize = knownFileSize;
    bool resolvedSupportsResume = supportsResume;
    String? resolvedFileName;

    final String currentTempFilePath = tempFilePath;
    final String currentLocalFilePath = localFilePath;

    final isTorrent = isTorrentUrl(
      url,
      fileName: p.basename(currentLocalFilePath),
    );

    if (!isTorrent && resolvedFileSize == 0 && isNameAutoGenerated) {
      try {
        final meta = await resolveMetadata(
          url: url,
          customUserAgent: customUserAgent,
          referer: referer,
          enableProxy: enableProxy,
          proxyAddress: proxyAddress,
          proxyHost: proxyHost,
          proxyPort: proxyPort,
          proxyUsername: proxyUsername,
          proxyPassword: proxyPassword,
          bypassSSL: bypassSSL,
          cookies: cookies,
          oauthToken: oauthToken,
        );

        resolvedFileSize = meta.fileSize;
        resolvedSupportsResume = meta.supportsResume;
        resolvedFileName = meta.fileName;
      } catch (e) {
        debugPrint(
          '[DownloadEngine] resolveMetadata failed in startDownload: $e',
        );
      }

      if (resolvedFileName != null || resolvedFileSize > 0) {
        onProgress(
          DownloadProgress(
            downloadedBytes: 0,
            fileSize: resolvedFileSize,
            speed: 0.0,
            eta: null,
            fileName: resolvedFileName,
            supportsResume: resolvedSupportsResume,
          ),
        );
      }
    }

    // Disk space pre-check: fail fast with a clear message before any bytes
    // are written, instead of surfacing a confusing mid-download error.
    // Runs for both HTTP and torrent paths whenever the size is known.
    if (resolvedFileSize > 0) {
      final saveDir = Directory(currentLocalFilePath).parent.path;
      final hasSpace = await hasEnoughDiskSpace(saveDir, resolvedFileSize);
      if (!hasSpace) {
        _activeCancelTokens.remove(cancelToken);
        throw const InsufficientStorageException();
      }
      // Non-blocking proactive low-storage warning.
      await checkLowStorageWarning(saveDir);
    }

    if (isTorrent) {
      try {
        await _handleTorrentDownload(
          url: url,
          currentTempFilePath: currentTempFilePath,
          currentLocalFilePath: currentLocalFilePath,
          knownFileSize: resolvedFileSize,
          cancelToken: cancelToken,
          onProgress: onProgress,
          getTorrentFiles: getTorrentFiles,
          torrentId: torrentId,
          enableProxy: enableProxy,
          proxyAddress: proxyAddress,
          proxyHost: proxyHost,
          proxyPort: proxyPort,
          proxyUsername: proxyUsername,
          proxyPassword: proxyPassword,
          bypassSSL: bypassSSL,
        );
      } finally {
        _activeCancelTokens.remove(cancelToken);
      }
      return;
    }

    var finalUrl = url;
    finalUrl = finalUrl.replaceAll(RegExp(r'(?<=[?&])range=[^&]*&?'), '');

    if (finalUrl.endsWith('?')) {
      finalUrl = finalUrl.substring(0, finalUrl.length - 1);
    }

    if (finalUrl.endsWith('&')) {
      finalUrl = finalUrl.substring(0, finalUrl.length - 1);
    }

    final punyUrl = convertIdnToPunycode(finalUrl);

    final command = DownloadCommand(
      url: url,
      punyUrl: punyUrl,
      tempFilePath: currentTempFilePath,
      localFilePath: currentLocalFilePath,
      knownFileSize: resolvedFileSize,
      supportsResume: resolvedSupportsResume,
      threadCount: effectiveThreadCount,
      customUserAgent: customUserAgent,
      referer: referer,
      enableProxy: enableProxy,
      proxyAddress: proxyAddress,
      proxyHost: proxyHost,
      proxyPort: proxyPort,
      proxyUsername: proxyUsername,
      proxyPassword: proxyPassword,
      bypassSSL: bypassSSL,
      cookies: cookies,
      oauthToken: oauthToken,
      isNameAutoGenerated: isNameAutoGenerated,
      speedLimit: speedLimitBytesPerSecond(),
      activeCount: activeDownloadCount(),
      taskId: taskId,
      mirrorUrls: mirrorUrls,
      adaptiveThreads: adaptiveThreads,
      speedLimitKbps: speedLimitKbps,
      dnsEnabled: _dohEnabled,
      dnsProvider: _dohProvider,
    );

    final pool = await _ensurePool();
    final job = pool.submit(command);

    final completer = Completer<void>();
    bool acked = false;
    bool cancelRequested = false;

    Timer? watchdog;
    Timer? inactivityTimer;
    const inactivityTimeout = Duration(minutes: 30);

    void resetInactivityTimer() {
      inactivityTimer?.cancel();
      inactivityTimer = Timer(inactivityTimeout, () {
        if (!completer.isCompleted) {
          completer.completeError(
            DioException(
              requestOptions: RequestOptions(path: punyUrl),
              type: DioExceptionType.receiveTimeout,
              message: 'Download job timed out after 30 minutes of inactivity.',
            ),
          );
        }
      });
    }

    // Start the inactivity timer
    resetInactivityTimer();

    watchdog = Timer(const Duration(seconds: 30), () {
      if (!acked && !completer.isCompleted) {
        inactivityTimer?.cancel();
        completer.completeError(
          const IsolateSpawnTimeoutException(
            'Download engine failed to initialize within 30 seconds. Please retry.',
          ),
        );
      }
    });

    void requestCancel() {
      cancelRequested = true;
      job.cancel();
    }

    cancelToken.whenCancel.then((_) => requestCancel());

    if (cancelToken.isCancelled) {
      requestCancel();
    }

    final sub = job.messages.listen((message) {
      final type = message.type;

      if (type == 'ack') {
        acked = true;
        if (cancelRequested) job.cancel();
      } else if (type == 'progress') {
        final p = message.data;

        // Reset inactivity timer on progress
        resetInactivityTimer();

        onProgress(
          DownloadProgress(
            downloadedBytes: (p['downloadedBytes'] as num?)?.toInt() ?? 0,
            fileSize: (p['fileSize'] as num?)?.toInt() ?? 0,
            speed: (p['speed'] as num?)?.toDouble() ?? 0.0,
            eta: (p['eta'] as num?)?.toInt(),
            chunks: p['chunks'] != null
                ? List<double>.from(p['chunks'] as List)
                : null,
            fileName: p['fileName'] as String?,
            supportsResume: p['supportsResume'] as bool?,
            statusMessage: p['statusMessage'] as String?,
          ),
        );
      } else if (type == 'done') {
        inactivityTimer?.cancel();
        if (!completer.isCompleted) completer.complete();
      } else if (type == 'error') {
        final data = message.data;
        final errType = data['errorType'];
        final errMsg = data['errorMessage']?.toString();
        final errStatus = data['errorStatus'] as int?;

        if (errType == 'integrity') {
          if (!completer.isCompleted) {
            inactivityTimer?.cancel();
            completer.completeError(DownloadIntegrityException(errMsg ?? ''));
          }
        } else if (errType == 'fileChanged') {
          if (!completer.isCompleted) {
            inactivityTimer?.cancel();
            completer.completeError(
              DioException(
                requestOptions: RequestOptions(path: punyUrl),
                type: DioExceptionType.unknown,
                message: errMsg ?? 'File changed on server. Restart required.',
              ),
            );
          }
        } else if (errType == 'diskFull') {
          if (!completer.isCompleted) {
            inactivityTimer?.cancel();
            completer.completeError(
              DioException(
                requestOptions: RequestOptions(path: punyUrl),
                type: DioExceptionType.unknown,
                message: 'Not enough storage space.',
              ),
            );
          }
        } else {
          DioExceptionType dioType = DioExceptionType.unknown;

          if (errType == 'cancel') {
            dioType = DioExceptionType.cancel;
          } else if (errType == 'badResponse') {
            dioType = DioExceptionType.badResponse;
          } else if (errType == 'connectionTimeout') {
            dioType = DioExceptionType.connectionTimeout;
          } else if (errType == 'receiveTimeout') {
            dioType = DioExceptionType.receiveTimeout;
          } else if (errType == 'sendTimeout') {
            dioType = DioExceptionType.sendTimeout;
          } else if (errType == 'connectionError') {
            dioType = DioExceptionType.connectionError;
          } else if (errType == 'uncaught') {
            dioType = DioExceptionType.unknown;
          }

          final dioException = DioException(
            requestOptions: RequestOptions(path: punyUrl),
            type: dioType,
            message: errMsg,
            response: errStatus != null
                ? Response(
                    requestOptions: RequestOptions(path: punyUrl),
                    statusCode: errStatus,
                  )
                : null,
          );

          if (!completer.isCompleted) {
            inactivityTimer?.cancel();
            completer.completeError(dioException);
          }
        }
      }
    });

    try {
      await completer.future;
    } finally {
      watchdog.cancel();
      inactivityTimer?.cancel();
      await sub.cancel();
      job.dispose();
      _activeCancelTokens.remove(cancelToken);
    }
  }

  Future<void> _handleTorrentDownload({
    required String url,
    required String currentTempFilePath,
    required String currentLocalFilePath,
    required int knownFileSize,
    required CancelToken cancelToken,
    required ValueChangedProgress onProgress,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int? torrentId,
    bool enableProxy = false,
    String? proxyAddress,
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
    bool bypassSSL = false,
  }) async {
    int id = torrentId ?? -1;

    if (id == -1) {
      final saveDir = File(currentLocalFilePath).parent.path;

      if (url.startsWith('magnet:')) {
        id = TorrentService.addMagnet(url, saveDir);
      } else {
        String filePath = url;

        if (url.startsWith('file://')) {
          filePath = Uri.parse(url).toFilePath();
        } else if (url.startsWith('http://') || url.startsWith('https://')) {
          final tempTorrentPath = p.join(
            Directory.systemTemp.path,
            'temp_${DateTime.now().millisecondsSinceEpoch}.torrent',
          );

          final tempTorrentFile = File(tempTorrentPath);

          final torrentDio = _buildIsolatedClient(
            url: url,
            enableProxy: enableProxy,
            proxyAddress: proxyAddress,
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            proxyUsername: proxyUsername,
            proxyPassword: proxyPassword,
            bypassSSL: bypassSSL,
          );

          try {
            await torrentDio.download(url, tempTorrentPath);
            filePath = tempTorrentPath;
            id = TorrentService.addTorrentFile(
              filePath,
              saveDir,
              sourceKey: url,
            );
          } finally {
            _reservedDioClients.remove(torrentDio);
            _activeDioClients.remove(torrentDio);
            _dioClientCreationTimes.remove(torrentDio);
            torrentDio.close(force: true);

            try {
              if (await tempTorrentFile.exists()) {
                await tempTorrentFile.delete();
              }
            } catch (e, st) {
              Logger(
                'download_engine',
              ).warning('[download_engine] operation failed', e, st);
            }
          }
        } else {
          id = TorrentService.addTorrentFile(filePath, saveDir, sourceKey: url);
        }
      }
    }

    if (id < 0) {
      throw DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.unknown,
        error: 'Torrent engine rejected the torrent.',
      );
    }

    _activeTorrentIds.add(id);

    try {
      await _waitForMetadata(
        id,
        url,
        cancelToken,
        onProgress,
        initialFileSize: knownFileSize,
      );

      final currentTorrentFiles = getTorrentFiles?.call();
      _applyFilePriorities(id, currentTorrentFiles);

      final resumeData =
          await TorrentResumeStore.loadResumeDataForSource(url) ??
              await TorrentResumeStore.loadResumeData(id);
      final nativeResumeLoaded =
          resumeData != null && TorrentService.loadResumeData(id, resumeData);
      if (!nativeResumeLoaded) {
        TorrentService.recheckTorrent(id);

        await _waitForState(
          id,
          cancelToken,
          predicate: (label) =>
              !label.contains('checking') &&
              !label.contains('metadata') &&
              !label.contains('allocating'),
          timeout: const Duration(minutes: 5),
        );
      }

      if (cancelToken.isCancelled) {
        _activeCancelTokens.remove(cancelToken);
        return;
      }

      try {
        if (!cancelToken.isCancelled) {
          TorrentService.resumeTorrent(id);
        }

        await _listenForCompletion(
          id,
          url,
          cancelToken,
          onProgress,
          getTorrentFiles,
          knownFileSize,
        );
      } finally {
        _activeCancelTokens.remove(cancelToken);
      }
    } finally {
      _activeTorrentIds.remove(id);
      _lastConcurrentLimitApply.remove(id);
      _lastIncompleteSnapshot.remove(id);
    }
  }

  Future<void> _waitForMetadata(
    int id,
    String url,
    CancelToken cancelToken,
    ValueChangedProgress onProgress, {
    int initialDownloadedBytes = 0,
    int initialFileSize = 0,
  }) async {
    final completer = Completer<void>();
    StreamSubscription? sub;
    Timer? timer;

    sub = TorrentService.torrentUpdates.listen((torrents) {
      if (cancelToken.isCancelled) {
        sub?.cancel();
        return;
      }

      final torrent = torrents[id];
      if (torrent != null && torrent.hasMetadata) {
        sub?.cancel();
        if (!completer.isCompleted) completer.complete();
      }
    });

    cancelToken.whenCancel.then((_) async {
      await sub?.cancel();
      timer?.cancel();

      if (!completer.isCompleted) {
        try {
          TorrentService.removeTorrent(id, deleteFiles: false);
        } catch (e, st) {
          Logger(
            'download_engine',
          ).warning('[download_engine] operation failed', e, st);
        }

        completer.completeError(
          DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.cancel,
            error: 'cancelled',
          ),
        );
      }
    }).catchError((e, st) {
      Logger(
        'download_engine',
      ).warning('[download_engine] operation failed', e, st);
    });

    int metadataElapsed = 0;

    timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (completer.isCompleted) {
        timer?.cancel();
        return;
      }

      metadataElapsed += 30;

      onProgress(
        DownloadProgress(
          downloadedBytes: initialDownloadedBytes,
          fileSize: initialFileSize,
          speed: 0.0,
          eta: null,
          statusMessage: 'Fetching metadata… (${metadataElapsed}s elapsed)',
        ),
      );
    });

    final timeout = Timer(const Duration(seconds: 300), () {
      timer?.cancel();

      if (completer.isCompleted) return;

      sub?.cancel();

      if (!cancelToken.isCancelled) {
        try {
          TorrentService.removeTorrent(id, deleteFiles: false);
        } catch (e, st) {
          Logger(
            'download_engine',
          ).warning('[download_engine] operation failed', e, st);
        }
      }

      if (!completer.isCompleted) {
        completer.completeError(
          DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.receiveTimeout,
            error: 'Timed out waiting for torrent metadata.',
          ),
        );
      }
    });

    try {
      await completer.future;
    } finally {
      timer.cancel();
      timeout.cancel();
      await sub.cancel();
    }
  }

  void _applyFilePriorities(
    int id,
    List<Map<String, dynamic>>? currentTorrentFiles,
  ) {
    if (currentTorrentFiles == null || currentTorrentFiles.isEmpty) return;

    final engineFileCount = TorrentService.getFileCount(id);

    if (engineFileCount == currentTorrentFiles.length) {
      final priorities = currentTorrentFiles.map((f) {
        final selected = f['selected'] as bool? ?? true;
        if (!selected) return 0;
        return f['priority'] as int? ?? 4;
      }).toList();

      TorrentService.setFilePriorities(id, priorities);
    } else {
      debugPrint(
        '[DMX] Skipping file priorities: engine has $engineFileCount '
        'files but task has ${currentTorrentFiles.length}',
      );
    }
  }

  Future<void> _listenForCompletion(
    int id,
    String url,
    CancelToken cancelToken,
    ValueChangedProgress onProgress,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int knownFileSize,
  ) async {
    final completer = Completer<void>();
    StreamSubscription? sub;

    sub = TorrentService.torrentUpdates.listen((torrents) {
      final torrent = torrents[id];
      if (torrent == null) return;

      final stateLabel = torrent.stateLabel.toLowerCase();

      List<Map<String, dynamic>>? resolvedFiles;
      String? resolvedName;

      if (torrent.hasMetadata) {
        resolvedName = torrent.name;

        try {
          final files = TorrentService.getFiles(id);
          final existingFiles = getTorrentFiles?.call() ?? [];

          resolvedFiles = files.map((f) {
            final existing =
                existingFiles.cast<Map<String, dynamic>?>().firstWhere(
                      (e) => (e?['name'] as String?) == f.name,
                      orElse: () => null,
                    );

            int resolvedBytes;
            bool isEstimated;

            if (f.downloadedBytes >= 0) {
              // True per-file progress from libtorrent
              resolvedBytes = f.downloadedBytes;
              isEstimated = false;
            } else {
              // No true progress available, use stale bytes as fallback
              final staleBytes = (existing?['downloadedBytes'] as int?) ?? 0;
              resolvedBytes = staleBytes;
              isEstimated = true;
            }

            return <String, dynamic>{
              'name': f.name,
              'length': f.size,
              'selected': existing?['selected'] as bool? ?? f.selected,
              'priority': existing?['priority'] as int? ?? f.priority,
              'downloadedBytes': resolvedBytes,
              'speed': 0.0,
              'progressEstimated': isEstimated,
            };

          }).toList();
        } catch (e) {
          debugPrint('[DownloadEngine] TorrentService.getFiles failed: $e');
        }
      }

      final int calculatedTotalSize =
          (resolvedFiles != null && resolvedFiles.isNotEmpty)
              ? resolvedFiles.where((f) => f['selected'] == true).fold<int>(
                    0,
                    (sum, f) => sum + ((f['length'] as num?)?.toInt() ?? 0),
                  )
              : 0;

      final totalSize = torrent.totalWanted > 0
          ? torrent.totalWanted
          : (calculatedTotalSize > 0
              ? calculatedTotalSize
              : (knownFileSize > 0 ? knownFileSize : 0));

      final downloadedBytes = torrent.totalWantedDone > 0
          ? torrent.totalWantedDone
          : torrent.totalDone;

      // FIX(2): Only estimate when we don't have true per-file progress.
      // When progressEstimated is false from the file mapping, we have real data.
      final bool hasTruePerFileProgress = resolvedFiles != null &&
          resolvedFiles.isNotEmpty &&
          resolvedFiles.any(
            (f) => (f['progressEstimated'] as bool? ?? true) == false,
          );
      final bool needsEstimation = resolvedFiles != null &&
          resolvedFiles.isNotEmpty &&
          !hasTruePerFileProgress &&
          (!TorrentService.fileProgressSupported || downloadedBytes > 0);
      if (needsEstimation) {
        _distributeDownloadedBytesByPriority(resolvedFiles, downloadedBytes);
        for (final f in resolvedFiles) {
          f['progressEstimated'] = true;
        }
      }

      // FIX(4): Apply max concurrent files limit
      if (resolvedFiles != null && resolvedFiles.isNotEmpty) {
        final maxConcurrentFiles =
            SettingsProvider.instance.maxConcurrentFilesPerTorrent;
        if (maxConcurrentFiles > 0) {
          _applyMaxConcurrentFilesLimit(id, resolvedFiles, maxConcurrentFiles);
        }
      }

      final isCheckingOrMetadata = stateLabel.contains('checking') ||
          stateLabel.contains('metadata') ||
          stateLabel.contains('allocating');

      final isUserPaused = stateLabel == 'paused' || stateLabel == 'stopped';

      if (isUserPaused && !cancelToken.isCancelled && !isCheckingOrMetadata) {
        onProgress(
          DownloadProgress(
            downloadedBytes: downloadedBytes,
            fileSize: totalSize,
            speed: 0.0,
            eta: null,
            chunks: null,
            fileName: resolvedName,
            torrentFiles: resolvedFiles,
            supportsResume: true,
          ),
        );
        if (!completer.isCompleted) {
          completer.complete();
        }
        return;
      }

      final isFullyDownloaded = totalSize > 0 && downloadedBytes >= totalSize;

      final isStableFinished = stateLabel == 'seeding' ||
          stateLabel == 'completed' ||
          stateLabel == 'finished';

      // FIX(7): Require a stable finished/seeding/completed state instead of
      // accepting `progress >= 0.999`. The old shortcut could fire while
      // libtorrent was still running its final hash verification (a transient
      // `downloading` tick right before it flips to `checking`).
      final isCompleted =
          isFullyDownloaded && !isCheckingOrMetadata && isStableFinished;

      final speed = torrent.downloadRate.toDouble();

      final remaining =
          totalSize > downloadedBytes ? totalSize - downloadedBytes : 0;

      final eta = speed.isFinite && speed > 0 && remaining > 0
          ? (remaining / speed).round().clamp(0, 86400 * 365)
          : null;

      if (!isCheckingOrMetadata) {
        onProgress(
          DownloadProgress(
            downloadedBytes: downloadedBytes,
            fileSize: totalSize,
            speed: speed,
            eta: eta,
            chunks: null,
            fileName: resolvedName,
            torrentFiles: resolvedFiles,
          ),
        );
      }

      // FIX(5): Dynamic priority updates as files complete — promote next files
      if (resolvedFiles != null && resolvedFiles.isNotEmpty) {
        final maxConcurrentFiles =
            SettingsProvider.instance.maxConcurrentFilesPerTorrent;
        if (maxConcurrentFiles > 0) {
          final anyFileJustCompleted = resolvedFiles.any((f) {
            final length = (f['length'] as num?)?.toInt() ?? 0;
            final downloaded = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
            return length > 0 && downloaded >= length;
          });
          if (anyFileJustCompleted) {
            _applyMaxConcurrentFilesLimit(
              id,
              resolvedFiles,
              maxConcurrentFiles,
            );
          }
        }
      }

      if (isCompleted && !completer.isCompleted) {
        completer.complete();
      }
    });

    cancelToken.whenCancel.then((_) async {
      await sub?.cancel();
      TorrentService.pauseTorrent(id);

      if (!completer.isCompleted) {
        completer.completeError(
          DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.cancel,
            message: 'Torrent download cancelled by user.',
          ),
        );
      }
    }).catchError((e, st) {
      Logger(
        'download_engine',
      ).warning('[download_engine] operation failed', e, st);
    });

    try {
      await completer.future;
    } finally {
      await sub.cancel();
    }
  }

  Future<int> _probeOptimalThreads(
    Dio dio,
    String url,
    int requestedThreads,
    int fileSize, {
    CancelToken? cancelToken,
  }) async {
    if (requestedThreads <= 1) return 1;
    if (fileSize > 0 && fileSize < 512 * 1024) return 1;

    // FIX(16): cap the probe to a fraction of the file so we never download a
    // large share of a small-ish file just to estimate thread count. Probing
    // is pointless if the probe would consume most of the payload.
    // FIX-M2: Reduced minimum from 32 KB to 16 KB to limit unnecessary data transfer.
    var probeSize = 256 * 1024;
    if (fileSize > 0) {
      probeSize = fileSize ~/ 4;
      if (probeSize > 256 * 1024) probeSize = 256 * 1024;
      if (probeSize < 16 * 1024) probeSize = 16 * 1024; // FIX-M2: was 32 KB
    }

    try {
      final sw = Stopwatch()..start();

      final response = await dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(
          headers: {'Range': 'bytes=0-${probeSize - 1}'},
          responseType: ResponseType.stream,
        ),
      );

      if (response.statusCode == 200) {
        debugPrint(
          '[DownloadEngine] Server does not support Range requests. Using 1 thread.',
        );
        await response.data?.stream.listen((_) {}).cancel();
        return 1;
      }

      if (response.statusCode == 416) {
        debugPrint(
          '[DownloadEngine] Server returned 416 for probe. Using 1 thread.',
        );
        await response.data?.stream.listen((_) {}).cancel();
        return 1;
      }

      int received = 0;

      await for (final chunk in response.data!.stream) {
        received += chunk.length;
        if (received >= probeSize) break;
      }

      try {
        await response.data?.stream.listen((_) {}).cancel();
      } catch (e, st) {
        Logger(
          'download_engine',
        ).warning('[download_engine] operation failed', e, st);
      }

      sw.stop();

      if (sw.elapsedMilliseconds <= 0) return requestedThreads;

      final speedBps = received / (sw.elapsedMilliseconds / 1000.0);

      debugPrint(
        '[DownloadEngine] Thread probe: ${received ~/ 1024} KB in '
        '${sw.elapsedMilliseconds}ms = '
        '${(speedBps / 1024 / 1024).toStringAsFixed(1)} MB/s',
      );

      if (speedBps > 5 * 1024 * 1024) {
        return requestedThreads.clamp(1, 4);
      }

      if (speedBps < 512 * 1024) {
        return requestedThreads;
      }

      return (requestedThreads / 2).ceil().clamp(1, requestedThreads);
    } catch (e) {
      debugPrint('[DownloadEngine] Thread probe failed: $e');
      return requestedThreads;
    }
  }

  Future<void> _doHttpDownload({
    required String url,
    required String punyUrl,
    required String tempFilePath,
    required String localFilePath,
    required int knownFileSize,
    required bool supportsResume,
    required int threadCount,
    String? customUserAgent,
    String? referer,
    required bool enableProxy,
    String? proxyAddress,
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
    required bool bypassSSL,
    String? cookies,
    String? oauthToken,
    required bool isNameAutoGenerated,
    required CancelToken cancelToken,
    required ValueChangedProgress onProgress,
    required int Function() speedLimitBytesPerSecond,
    required int Function() activeDownloadCount,
    required String taskId,
    required bool adaptiveThreads,
    required int speedLimitKbps,
  }) async {
    late final _MutableDownloadTask task;
    int resolvedFileSize = knownFileSize;
    final bool resolvedSupportsResume = supportsResume;
    final String currentTempFilePath = tempFilePath;
    String currentLocalFilePath = localFilePath;

    String? resolvedFileName;

    if (isNameAutoGenerated) {
      resolvedFileName = fileNameFromUrl(url);
    }

    if (resolvedFileName != null && resolvedFileName.isNotEmpty) {
      final saveDir = File(currentLocalFilePath).parent.path;
      final newPath = p.join(saveDir, safeFileName(resolvedFileName));

      if (newPath != currentLocalFilePath) {
        debugPrint(
          '[DownloadEngine] Applying resolved file name: $resolvedFileName '
          '(was: ${p.basename(currentLocalFilePath)})',
        );
        currentLocalFilePath = newPath;
      }
    }

    final isolatedDio = _buildIsolatedClient(
      url: punyUrl,
      customUserAgent: customUserAgent,
      referer: referer,
      enableProxy: enableProxy,
      proxyAddress: proxyAddress,
      proxyHost: proxyHost,
      proxyPort: proxyPort,
      proxyUsername: proxyUsername,
      proxyPassword: proxyPassword,
      bypassSSL: bypassSSL,
      cookies: cookies,
      oauthToken: oauthToken,
    );

    _activeDownloadsPerClient[isolatedDio]?.add(tempFilePath);

    try {
      if (resolvedFileSize > 0 && resolvedFileSize < threadCount * 1024) {
        threadCount = 1;
      }

      final isMultiThread =
          threadCount > 1 && resolvedSupportsResume && resolvedFileSize > 0;

      if (!isMultiThread) {
        await _downloadSingleThreaded(
          url: url,
          punyUrl: punyUrl,
          tempFilePath: currentTempFilePath,
          localFilePath: currentLocalFilePath,
          knownFileSize: resolvedFileSize,
          supportsResume: resolvedSupportsResume,
          cancelToken: cancelToken,
          onProgress: onProgress,
          speedLimitBytesPerSecond: speedLimitBytesPerSecond,
          activeDownloadCount: activeDownloadCount,
          isolatedDio: isolatedDio,
          resolvedFileName: resolvedFileName,
        );
        return;
      }

      await ConnectionManager.prewarm(punyUrl);

      final isHttp2 = await ConnectionManager.detectHttp2(punyUrl);
      final effectiveThreads = isHttp2 ? threadCount.clamp(1, 2) : threadCount;

      if (isHttp2) {
        debugPrint(
          '[DownloadEngine] HTTP/2 detected for ${Uri.parse(punyUrl).host}. '
          'Capping threads: $threadCount → $effectiveThreads',
        );
      }

      threadCount = await _probeOptimalThreads(
        isolatedDio,
        punyUrl,
        effectiveThreads,
        resolvedFileSize,
        cancelToken: cancelToken,
      );
      threadCount = threadCount.clamp(1, PowerMonitor.maxAllowedThreads);

      debugPrint('[DownloadEngine] Final thread count: $threadCount');


      String? savedEtag;
      String? savedLastModified;

      try {
        final probeResponse = await isolatedDio.get<ResponseBody>(
          punyUrl,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: true,
            headers: {'Range': 'bytes=0-0'},
            validateStatus: (_) => true,
          ),
        );

        if (probeResponse.statusCode == 206 ||
            probeResponse.statusCode == 200) {
          savedEtag ??= probeResponse.headers.value('etag');
          savedLastModified ??= probeResponse.headers.value('last-modified');

          final contentRange = probeResponse.headers.value('content-range');
          if (contentRange != null) {
            final totalMatch = RegExp(r'/(\d+)').firstMatch(contentRange);
            if (totalMatch != null) {
              final serverTotal = int.tryParse(totalMatch.group(1)!) ?? 0;
              if (serverTotal > 0 && serverTotal != resolvedFileSize) {
                debugPrint(
                  '[DownloadEngine] Correcting estimated file size from '
                  '$resolvedFileSize to $serverTotal based on server probe.',
                );
                resolvedFileSize = serverTotal;
              }
            }
          }

          await probeResponse.data?.stream.listen((_) {}).cancel();
        }
      } catch (e) {
        debugPrint('[DownloadEngine] Pre-download size probe failed: $e');
      }

      if (threadCount <= 1 || resolvedFileSize <= 0) {
        await _downloadSingleThreaded(
          url: url,
          punyUrl: punyUrl,
          tempFilePath: currentTempFilePath,
          localFilePath: currentLocalFilePath,
          knownFileSize: resolvedFileSize,
          supportsResume: resolvedSupportsResume,
          cancelToken: cancelToken,
          onProgress: onProgress,
          speedLimitBytesPerSecond: speedLimitBytesPerSecond,
          activeDownloadCount: activeDownloadCount,
          isolatedDio: isolatedDio,
          resolvedFileName: resolvedFileName,
        );
        return;
      }

      final futures = <Future<void>>[];
      final chunkCancelTokens = List<CancelToken>.generate(
        threadCount,
        (_) => CancelToken(),
      );

      var chunkProgress = List<int>.filled(threadCount, 0);
      final chunkSizes = List<int>.filled(threadCount, 0);

      var totalSize = resolvedFileSize;
      final partSize = (totalSize / threadCount).floor();

      final targetFile = File(currentTempFilePath);
      await targetFile.parent.create(recursive: true);

      if (!await targetFile.exists()) {
        await targetFile.create();
      }

      final stateFile = File('$currentTempFilePath.dmxstate');
      final journalPath = '$currentTempFilePath.journal';

      List<int>? loadedState;
      bool canResume = false;
      List<int>? journalProgress;

      try {
        journalProgress = await DownloadJournal.recover(journalPath);
      } catch (e) {
        debugPrint('[DownloadEngine] Journal recovery failed: $e');
      }

      if (journalProgress != null && journalProgress.length == threadCount) {
        chunkProgress = journalProgress;
        canResume = true;
        loadedState = journalProgress;

        debugPrint(
          '[DownloadEngine] Recovered progress from journal: $chunkProgress',
        );
      } else if (await stateFile.exists()) {
        try {
          final content = await stateFile.readAsString();
          final decoded = jsonDecode(content);

          if (decoded is Map) {
            final savedTotalSize =
                (decoded['totalSize'] as num?)?.toInt() ?? -1;
            final savedThreadCount =
                (decoded['threadCount'] as num?)?.toInt() ?? -1;

            final progressList = decoded['progress'] as List?;

            savedEtag = decoded['etag'] as String?;
            savedLastModified = decoded['lastModified'] as String?;

            const sizeTolerance =
                2048; // 2 KB tolerance for CDN Content-Length jitter
            final isSizeWithinTolerance =
                (savedTotalSize - totalSize).abs() <= sizeTolerance;

            if (isSizeWithinTolerance && progressList != null) {
              if (savedTotalSize != totalSize) {
                debugPrint(
                  '[DownloadEngine] Size drift detected: saved=$savedTotalSize, '
                  'probed=$totalSize. Using saved value (tolerance=$sizeTolerance).',
                );
              }
              totalSize = savedTotalSize;
              if (savedThreadCount == threadCount &&
                  progressList.length == threadCount) {
                loadedState = progressList.cast<int>();
                canResume = true;
              } else if (savedThreadCount > 0 &&
                  progressList.length == savedThreadCount) {
                debugPrint(
                  '[DownloadEngine] Resuming state with saved thread count '
                  '$savedThreadCount (requested thread count was $threadCount)',
                );
                threadCount = savedThreadCount;
                loadedState = progressList.cast<int>();
                canResume = true;
              }
            }
          }
        } catch (e) {
          debugPrint('[DownloadEngine] State file decode failed: $e');
        }
      }

      if (!canResume) {
        await _deleteFileIfExists(stateFile);
        await _deleteFileIfExists(File(journalPath));

        chunkProgress = List<int>.filled(threadCount, 0);
      }

      final progressLock = Lock();
      final stateFileLock = Lock();
      final journalLock = Lock();

      final PositionalFileWriter writer;

      if (canResume && loadedState != null && loadedState.any((b) => b > 0)) {
        if (await File(currentTempFilePath).exists()) {
          writer = await PositionalFileWriter.openForResume(
            currentTempFilePath,
            threadCount: threadCount,
            totalSize: totalSize, // FIX-M12: needed for fresh-open fallback
          );
        } else {
          writer = await PositionalFileWriter.open(
            currentTempFilePath,
            totalSize: totalSize,
            threadCount: threadCount,
          );

          chunkProgress = List<int>.filled(threadCount, 0);
        }
      } else {
        writer = await PositionalFileWriter.open(
          currentTempFilePath,
          totalSize: totalSize,
          threadCount: threadCount,
        );
      }

      final journal = DownloadJournal(journalPath);

      await journalLock.synchronized(() async {
        await journal.open();

        final hasRecoveredJournal =
            journalProgress != null && journalProgress.length == threadCount;

        if (!hasRecoveredJournal) {
          await journal.writeInit(threadCount, totalSize);
        }
      });

      final governor = BandwidthGovernor(
        _perTaskSpeedLimit(speedLimitBytesPerSecond(), activeDownloadCount()),
      );

      governor.registerConsumer();
      if (speedLimitKbps > 0) {
        governor.setTaskLimit(taskId, speedLimitKbps * 125);
      }

      var governorUnregistered = false;
      var writerClosed = false;
      var journalClosed = false;

      Future<void> closeWriter() async {
        if (writerClosed) return;
        writerClosed = true;

        try {
          await writer.close();
        } catch (e, st) {
          Logger(
            'download_engine',
          ).warning('[download_engine] operation failed', e, st);
        }
      }

      Future<void> closeJournal() async {
        if (journalClosed) return;
        journalClosed = true;

        try {
          await journalLock.synchronized(() => journal.close());
        } catch (e, st) {
          Logger(
            'download_engine',
          ).warning('[download_engine] operation failed', e, st);
        }
      }

      void unregisterGovernor() {
        if (governorUnregistered) return;
        governorUnregistered = true;

        try {
          governor.unregisterConsumer();
        } catch (e, st) {
          Logger(
            'download_engine',
          ).warning('[download_engine] operation failed', e, st);
        }
      }

      for (int i = 0; i < threadCount; i++) {
        final start = i * partSize;
        final end =
            (i == threadCount - 1) ? (totalSize - 1) : (start + partSize - 1);
        final size = end - start + 1;

        chunkSizes[i] = size;

        if (chunkProgress[i] > size) {
          chunkProgress[i] = 0;
        }
      }

      // Spot-check resume integrity before spawning threads
      final bool checkEnabled = SettingsProvider.instance.resumeIntegrityCheck;
      final bool hasResumeBytes = chunkProgress.any((b) => b > 0);
      const int maxSpotCheckSize = 8 * 1024 * 1024 * 1024; // 8 GB

      if (checkEnabled &&
          resolvedSupportsResume &&
          totalSize > 0 &&
          hasResumeBytes) {
        if (totalSize > maxSpotCheckSize) {
          debugPrint(
            '[DownloadEngine] Skipping spot-check resume integrity for large file '
            '(${totalSize ~/ (1024 * 1024 * 1024)} GB > 8 GB).',
          );
        } else {
          for (int i = 0; i < threadCount; i++) {
            final downloadedInChunk = chunkProgress[i];
            if (downloadedInChunk <= 0) continue;

            final chunkStart = i * partSize;
            const int sampleSize = 64 * 1024; // 64 KB

            // Check start, middle, and end of each chunk
            final samplesToCheck = <_RangeSample>[
              _RangeSample(chunkStart, min(sampleSize, downloadedInChunk)),
            ];

            if (downloadedInChunk > 128 * 1024) {
              final midOffset = downloadedInChunk ~/ 2;
              samplesToCheck.add(
                _RangeSample(
                  chunkStart + midOffset,
                  min(sampleSize, downloadedInChunk - midOffset),
                ),
              );
            }

            if (downloadedInChunk > sampleSize) {
              final endOffset = downloadedInChunk - sampleSize;
              samplesToCheck.add(_RangeSample(chunkStart + endOffset, sampleSize));
            }


            bool chunkValid = true;

            for (final sample in samplesToCheck) {
              if (cancelToken.isCancelled) break;
              try {
                final diskBytes = await writer.readRange(
                  sample.start,
                  sample.length,
                );
                if (diskBytes.length != sample.length) {
                  chunkValid = false;
                  break;
                }

                final ifRange = _firstNonEmpty(savedEtag, savedLastModified);
                final response = await isolatedDio.get<ResponseBody>(
                  punyUrl,
                  cancelToken: cancelToken,
                  options: Options(
                    responseType: ResponseType.stream,
                    headers: {
                      'Range':
                          'bytes=${sample.start}-${sample.start + sample.length - 1}',
                      if (ifRange != null) 'If-Range': ifRange,
                    },
                    validateStatus: (_) => true,
                  ),
                );

                if (response.statusCode != 206 || response.data == null) {
                  chunkValid = false;
                  break;
                }

                final builder = BytesBuilder(copy: false);
                await for (final b in response.data!.stream) {
                  builder.add(b);
                }
                final netBytes = builder.takeBytes();

                if (netBytes.length != sample.length ||
                    !listEquals(diskBytes, netBytes)) {
                  chunkValid = false;
                  break;
                }
              } catch (e) {
                debugPrint(
                  '[DownloadEngine] Spot-check I/O error for chunk $i sample at ${sample.start}: $e',
                );
                chunkValid = false;
                break;
              }
            }

            if (!chunkValid) {
              debugPrint(
                '[DownloadEngine] Spot-check resume integrity mismatch for chunk $i. '
                'Resetting chunk progress to 0.',
              );
              chunkProgress[i] = 0;
              try {
                DiagnosticService.instance.record(
                  'resume_integrity',
                  'Spot-check mismatch for task $taskId chunk $i, chunk progress reset to 0.',
                  error: 'byte_mismatch',
                );
              } catch (_) {}
            }
          }
        }
      }

      final stopwatch = Stopwatch()..start();
      final speedSamples = Queue<_SpeedSample>();

      int lastReportTime = 0;
      int lastStateSaveTime = 0;

      DateTime lastCheckpointTime = DateTime.now();
      int bytesSinceLastCheckpoint = 0;

      Object? chunkError;

      Future<void> saveState() async {
        try {
          final snapshot = await progressLock.synchronized(
            () => List<int>.from(chunkProgress),
          );

          final etagSnapshot = await progressLock.synchronized(() => savedEtag);

          final lastModifiedSnapshot = await progressLock.synchronized(
            () => savedLastModified,
          );

          await stateFileLock.synchronized(() async {
            final tempStateFile = File('${stateFile.path}.tmp');

            final stateData = {
              'totalSize': totalSize,
              'threadCount': threadCount,
              'progress': snapshot,
              'etag': etagSnapshot,
              'lastModified': lastModifiedSnapshot,
            };

            await tempStateFile.writeAsString(jsonEncode(stateData));
            await tempStateFile.rename(stateFile.path);
          });
        } catch (e) {
          debugPrint('Failed to save state: $e');
        }
      }

      Future<void> reportProgress() async {
        final nowMs = stopwatch.elapsedMilliseconds;

        final result = await progressLock.synchronized<_ProgressReport?>(() {
          final snapshot = List<int>.from(chunkProgress);

          final downloadedTotal = snapshot.fold<int>(
            0,
            (sum, value) => sum + value,
          );

          final isCompleted = totalSize > 0 && downloadedTotal >= totalSize;

          final shouldReport = isCompleted ||
              nowMs - lastReportTime >= effectiveProgressReportIntervalMs;


          final shouldSave =
              isCompleted || nowMs - lastStateSaveTime >= _stateSaveIntervalMs;

          if (!shouldReport && !shouldSave) return null;

          speedSamples.add(_SpeedSample(nowMs, downloadedTotal));

          while (speedSamples.isNotEmpty &&
              nowMs - speedSamples.first.timestampMs > 3000) {
            speedSamples.removeFirst();
          }

          var speed = 0.0;

          if (speedSamples.length > 1) {
            final first = speedSamples.first;
            final elapsedSeconds = (nowMs - first.timestampMs) / 1000.0;

            if (elapsedSeconds > 0) {
              speed = (downloadedTotal - first.bytes) / elapsedSeconds;
            }
          }

          final remaining =
              totalSize > downloadedTotal ? totalSize - downloadedTotal : 0;

          final rawEta = speed.isFinite && speed > 0 && remaining > 0
              ? (remaining / speed).round().clamp(0, 86400 * 365)
              : null;

          final eta = _applyEtaSmoothing(rawEta);

          if (shouldReport) lastReportTime = nowMs;
          if (shouldSave) lastStateSaveTime = nowMs;

          return _ProgressReport(
            shouldReport: shouldReport,
            shouldSave: shouldSave,
            snapshot: snapshot,
            downloadedTotal: downloadedTotal,
            speed: speed,
            eta: eta,
          );
        });

        if (result == null) return;
        task.speed = result.speed;

        if (result.shouldReport) {
          final chunksList = List<double>.generate(threadCount, (idx) {
            return chunkSizes[idx] > 0
                ? (result.snapshot[idx] / chunkSizes[idx]).clamp(0.0, 1.0)
                : 1.0;
          });

          Future.microtask(() {
            try {
              onProgress(
                DownloadProgress(
                  downloadedBytes: result.downloadedTotal,
                  fileSize: totalSize,
                  speed: result.speed,
                  eta: result.eta,
                  chunks: chunksList,
                  fileName: resolvedFileName,
                  supportsResume: true,
                ),
              );
            } catch (e) {
              debugPrint('[DownloadEngine] onProgress callback failed: $e');
            }
          });
        }

        if (result.shouldSave) {
          await saveState();
        }
      }

      cancelToken.whenCancel.then((_) {
        for (final ct in chunkCancelTokens) {
          if (!ct.isCancelled) ct.cancel();
        }
      });

      final settingsProvider = _SettingsProviderWrapper(adaptiveThreads);
      task = _MutableDownloadTask(
        id: taskId,
        fileName: resolvedFileName ?? '',
        url: url,
        fileSize: totalSize,
        downloadedBytes: 0,
        category: '',
        status: DownloadStatus.downloading,
        savePath: '',
        localFilePath: currentLocalFilePath,
        tempFilePath: currentTempFilePath,
        threadCount: threadCount,
        chunks: [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        supportsResume: resolvedSupportsResume,
      );

      if (settingsProvider.adaptiveThreads) {
        _httpEngine.startAdaptiveMonitorIfEnabled(task, true);
      }

      try {
        for (int i = 0; i < threadCount; i++) {
          final idx = i;
          final start = idx * partSize;
          final end = (idx == threadCount - 1)
              ? (totalSize - 1)
              : (start + partSize - 1);

          futures.add(() async {
            var resumeFrom = chunkProgress[idx];
            if (resumeFrom >= chunkSizes[idx]) return;

            int attempts = 0;
            const maxAttempts = 3;

            while (attempts < maxAttempts) {
              attempts++;

              try {
                resumeFrom = chunkProgress[idx];
                if (resumeFrom >= chunkSizes[idx]) break;

                final headers = <String, dynamic>{};
                headers['Range'] = 'bytes=${start + resumeFrom}-$end';

                if (resumeFrom > 0) {
                  final ifRange = await progressLock.synchronized<String?>(
                    () => _firstNonEmpty(savedEtag, savedLastModified),
                  );

                  if (ifRange != null) {
                    headers['If-Range'] = ifRange;
                  }
                }

                final chunkResponse = await isolatedDio.get<ResponseBody>(
                  punyUrl,
                  cancelToken: chunkCancelTokens[idx],
                  options: Options(
                    responseType: ResponseType.stream,
                    followRedirects: true,
                    headers: headers,
                    validateStatus: (_) => true,
                  ),
                );

                if (chunkResponse.statusCode == 200 && resumeFrom > 0) {
                  debugPrint(
                    '[DownloadEngine] File changed on server during resume. '
                    'Restarting download from scratch.',
                  );
                  throw _FileChangedOnServerException();
                }

                if (chunkResponse.statusCode != 206) {
                  if (chunkResponse.statusCode == 200 && idx == 0) {
                    debugPrint(
                      '[DownloadEngine] Server returned 200 for first chunk; '
                      'falling back to single-threaded download.',
                    );

                    throw DioException(
                      requestOptions: RequestOptions(path: punyUrl),
                      type: DioExceptionType.badResponse,
                      response: chunkResponse,
                      message:
                          'Server returned 200 for first chunk; fallback to single-threaded mode.',
                    );
                  }

                  throw DioException(
                    requestOptions: RequestOptions(path: punyUrl),
                    type: DioExceptionType.badResponse,
                    response: chunkResponse,
                    message:
                        'Server returned ${chunkResponse.statusCode} instead of 206.',
                  );
                }

                // reject HTML responses (expired YouTube stream → error page)
                final chunkContentType = chunkResponse.headers
                        .value('content-type')
                        ?.toLowerCase() ??
                    '';
                if (chunkContentType.contains('text/html') ||
                    chunkContentType.contains('application/xhtml')) {
                  throw DioException(
                    requestOptions: chunkResponse.requestOptions,
                    type: DioExceptionType.badResponse,
                    response: chunkResponse,
                    message: 'HTML_INSTEAD_OF_MEDIA',
                  );
                }

                await progressLock.synchronized(() {
                  savedEtag ??= chunkResponse.headers.value('etag');
                  savedLastModified ??= chunkResponse.headers.value(
                    'last-modified',
                  );
                });

                _validateContentRange(
                  chunkResponse.headers.value('content-range'),
                  expectedStart: start + resumeFrom,
                  expectedEnd: end,
                  expectedTotal: totalSize,
                  punyUrl: punyUrl,
                );

                final stream = chunkResponse.data?.stream;
                if (stream == null) {
                  throw DioException(
                    requestOptions: RequestOptions(path: punyUrl),
                    type: DioExceptionType.badResponse,
                    message: 'Server returned empty response body.',
                  );
                }

                var chunkDownloadedThisSession = 0;

                try {
                  await for (final chunk in stream) {
                    if (cancelToken.isCancelled ||
                        chunkCancelTokens[idx].isCancelled) {
                      throw DioException(
                        requestOptions: RequestOptions(path: punyUrl),
                        type: DioExceptionType.cancel,
                        message: 'Download cancelled.',
                      );
                    }

                    _tryUpdateBandwidthGovernor(
                      governor,
                      _perTaskSpeedLimit(
                        speedLimitBytesPerSecond(),
                        activeDownloadCount(),
                      ),
                    );

                    final sleepMs = await governor.acquire(chunk.length, taskId: taskId);
                    if (sleepMs > 0) {
                      await _cancellableDelay(
                        Duration(milliseconds: sleepMs),
                        cancelToken: chunkCancelTokens[idx],
                      );
                      if (chunkCancelTokens[idx].isCancelled) {
                        throw DioException(
                          requestOptions: RequestOptions(path: punyUrl),
                          type: DioExceptionType.cancel,
                          message: 'Download cancelled.',
                        );
                      }
                    }

                    final absolutePosition =
                        start + resumeFrom + chunkDownloadedThisSession;

                    final Uint8List chunkData = chunk;

                    await writer.write(idx, absolutePosition, chunkData);

                    chunkDownloadedThisSession += chunk.length;

                    final updatedProgress = await progressLock.synchronized(() {
                      chunkProgress[idx] =
                          resumeFrom + chunkDownloadedThisSession;
                      bytesSinceLastCheckpoint += chunk.length;
                      return chunkProgress[idx];
                    });

                    await journalLock.synchronized(
                      () => journal.recordChunkProgress(idx, updatedProgress),
                    );

                    final checkpointSnapshot =
                        await progressLock.synchronized<List<int>?>(() {
                      final now = DateTime.now();

                      if (now.difference(lastCheckpointTime).inSeconds >= 5 ||
                          bytesSinceLastCheckpoint >= 1024 * 1024) {
                        lastCheckpointTime = now;
                        bytesSinceLastCheckpoint = 0;
                        return List<int>.from(chunkProgress);
                      }

                      return null;
                    });

                    if (checkpointSnapshot != null) {
                      await journalLock.synchronized(
                        () => journal.writeCheckpoint(
                          checkpointSnapshot,
                          totalSize,
                        ),
                      );
                    }

                    await reportProgress();
                  }
                } catch (e) {
                  try {
                    await writer.flush(idx);
                  } catch (e, st) {
                    Logger(
                      'download_engine',
                    ).warning('[download_engine] operation failed', e, st);
                  }

                  rethrow;
                }

                break;
              } catch (e) {
                if (e is _FileChangedOnServerException) rethrow;

                if (cancelToken.isCancelled ||
                    chunkCancelTokens[idx].isCancelled) {
                  rethrow;
                }

                if (attempts >= maxAttempts) {
                  for (final ct in chunkCancelTokens) {
                    if (!ct.isCancelled) ct.cancel();
                  }

                  await progressLock.synchronized(() {
                    chunkError ??= e;
                  });

                  rethrow;
                }

                debugPrint(
                  'Thread $idx failed attempt $attempts: $e. Retrying...',
                );
                final delay = (attempts * attempts * 2) + Random().nextInt(3);
                await _cancellableDelay(
                  Duration(seconds: delay),
                  cancelToken: chunkCancelTokens[idx],
                );
                if (chunkCancelTokens[idx].isCancelled ||
                    cancelToken.isCancelled) {
                  throw DioException(
                    requestOptions: RequestOptions(path: punyUrl),
                    type: DioExceptionType.cancel,
                    message: 'Download cancelled.',
                  );
                }
              }
            }
          }());
        }

        try {
          await Future.wait(futures);
        } finally {
          governor.removeTaskLimit(taskId);
          _httpEngine.stopAdaptiveThreadMonitor();
          try {
            await writer.flushAll();
          } catch (_) {}
          await closeWriter();
          if (!journalClosed) {
            try {
              await journalLock.synchronized(() => journal.delete());
            } catch (e, st) {
              Logger(
                'download_engine',
              ).warning('[download_engine] operation failed', e, st);
            }
            journalClosed = true;
          }
          unregisterGovernor();
        }

        await saveState();
        await _deleteFileIfExists(stateFile);

        if (currentTempFilePath != currentLocalFilePath) {
          final finalFile = File(currentLocalFilePath);
          await finalFile.parent.create(recursive: true);

          if (await finalFile.exists()) {
            await finalFile.delete();
          }

          try {
            await File(currentTempFilePath).rename(currentLocalFilePath);
          } catch (e) {
            await File(currentTempFilePath).copy(currentLocalFilePath);

            final copiedLen = await File(currentLocalFilePath).length();
            final origLen = await File(currentTempFilePath).length();

            if (copiedLen == origLen) {
              await File(currentTempFilePath).delete();
            } else {
              throw Exception('File copy failed on rename fallback.');
            }
          }
        }
      } catch (e) {
        await _cancelAndAwaitFutures(chunkCancelTokens, futures);

        if (e is _FileChangedOnServerException) {
          await closeWriter();
          await closeJournal();
          unregisterGovernor();

          await _deleteFileIfExists(File(currentTempFilePath));
          await _deleteFileIfExists(stateFile);
          await _deleteFileIfExists(File(journalPath));

          rethrow;
        }

        if (cancelToken.isCancelled) {
          await closeWriter();
          await closeJournal();
          await saveState();
          unregisterGovernor();

          rethrow;
        }

        final errorToCheck =
            await progressLock.synchronized<Object?>(() => chunkError) ?? e;

        bool isRangeRejection = false;

        if (errorToCheck is DioException &&
            errorToCheck.type == DioExceptionType.badResponse) {
          final status = errorToCheck.response?.statusCode;

          if (status == 200 || status == 416) {
            isRangeRejection = true;
          }

          if (errorToCheck.message?.startsWith('Invalid Content-Range') ==
              true) {
            isRangeRejection = true;
          }
        }

        if (!isRangeRejection) {
          await closeWriter();
          await closeJournal();
          await saveState();
          unregisterGovernor();

          rethrow;
        }

        debugPrint(
          'Multi-threaded range request failed (Range Rejection): $e. '
          'Falling back to single-threaded safe restart.',
        );

        await closeWriter();
        await closeJournal();
        unregisterGovernor();

        await _deleteFileIfExists(File(currentTempFilePath));
        await _deleteFileIfExists(stateFile);
        await _deleteFileIfExists(File(journalPath));

        await _downloadSingleThreaded(
          url: url,
          punyUrl: punyUrl,
          tempFilePath: currentTempFilePath,
          localFilePath: currentLocalFilePath,
          knownFileSize: resolvedFileSize,
          supportsResume: false,
          cancelToken: cancelToken,
          onProgress: onProgress,
          speedLimitBytesPerSecond: speedLimitBytesPerSecond,
          activeDownloadCount: activeDownloadCount,
          isolatedDio: isolatedDio,
          resolvedFileName: resolvedFileName,
        );
      } finally {
        governor.removeTaskLimit(taskId);
        _httpEngine.stopAdaptiveThreadMonitor();
        await closeWriter();
        await closeJournal();
        unregisterGovernor();
      }
    } finally {
      _httpEngine.stopAdaptiveThreadMonitor();
      _activeDownloadsPerClient[isolatedDio]?.remove(tempFilePath);

      _reservedDioClients.remove(isolatedDio);
      _activeDioClients.remove(isolatedDio);
      _dioClientCreationTimes.remove(isolatedDio);

      isolatedDio.close(force: true);
    }
  }

  Future<void> _downloadSingleThreaded({
    required String url,
    required String punyUrl,
    required String tempFilePath,
    required String localFilePath,
    required int knownFileSize,
    required bool supportsResume,
    required CancelToken cancelToken,
    required ValueChangedProgress onProgress,
    required int Function() speedLimitBytesPerSecond,
    required int Function() activeDownloadCount,
    required Dio isolatedDio,
    String? resolvedFileName,
  }) async {
    final tempFile = File(tempFilePath);
    await tempFile.parent.create(recursive: true);

    var resumeFrom = 0;

    if (await tempFile.exists()) {
      final partSize = await tempFile.length();

      if (knownFileSize > 0 && partSize >= knownFileSize) {
        debugPrint(
          '[DownloadEngine] Single-threaded file already fully downloaded '
          '($partSize >= $knownFileSize bytes). Skipping download.',
        );
        onProgress(DownloadProgress(
          downloadedBytes: partSize,
          fileSize: knownFileSize,
          speed: 0.0,
          eta: 0,
          statusMessage: 'Completed',
          chunks: null,
          supportsResume: true,
          torrentFiles: null,
          fileName: resolvedFileName,
        ));
        return;
      }

      if (supportsResume) {
        if (knownFileSize > 0 && partSize < knownFileSize) {
          resumeFrom = partSize;
        } else if (knownFileSize == 0) {
          resumeFrom = partSize;
        } else {
          debugPrint(
            '[DownloadEngine] Single-threaded resume validation failed: '
            'file size $partSize exceeds expected $knownFileSize. Restarting from 0.',
          );
          await tempFile.delete();
        }
      }
    }

    final headers = <String, dynamic>{};

    if (resumeFrom > 0) {
      headers['Range'] = 'bytes=$resumeFrom-';
    }

    var response = await isolatedDio.get<ResponseBody>(
      punyUrl,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: true,
        headers: headers,
        validateStatus: (_) => true,
      ),
    );

    if (response.statusCode == 403 || response.statusCode == 410) {
      throw DioException(
        requestOptions: RequestOptions(path: punyUrl),
        type: DioExceptionType.badResponse,
        response: response,
        message: 'Server returned status code ${response.statusCode}',
      );
    }

    var actualResumeFrom = resumeFrom;

    if (response.statusCode == 416) {
      if (await tempFile.exists()) {
        final partLen = await tempFile.length();
        if (knownFileSize > 0 && partLen >= knownFileSize) {
          debugPrint(
            '[DownloadEngine] 416 returned because file is complete ($partLen >= $knownFileSize).',
          );
          onProgress(DownloadProgress(
            downloadedBytes: partLen,
            fileSize: knownFileSize,
            speed: 0.0,
            eta: 0,
            statusMessage: 'Completed',
            chunks: null,
            supportsResume: true,
            torrentFiles: null,
            fileName: resolvedFileName,
          ));
          return;
        }
        await tempFile.delete();
      }

      actualResumeFrom = 0;
      headers.remove('Range');

      response = await isolatedDio.get<ResponseBody>(
        punyUrl,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          headers: headers,
          validateStatus: (_) => true,
        ),
      );
    }

    if (response.statusCode != 200 && response.statusCode != 206) {
      throw DioException(
        requestOptions: RequestOptions(path: punyUrl),
        type: DioExceptionType.badResponse,
        response: response,
        message: 'Server returned status code ${response.statusCode}',
      );
    }

    // reject HTML responses (expired YouTube stream → error page)
    final contentType =
        response.headers.value('content-type')?.toLowerCase() ?? '';
    if (contentType.contains('text/html') ||
        contentType.contains('application/xhtml')) {
      throw DioException(
        requestOptions: response.requestOptions,
        type: DioExceptionType.badResponse,
        response: response,
        message: 'HTML_INSTEAD_OF_MEDIA',
      );
    }

    final isPartialResponse = response.statusCode == 206;

    if (actualResumeFrom > 0 && !isPartialResponse) {
      actualResumeFrom = 0;

      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }

    if (isPartialResponse) {
      final contentRange = response.headers.value('content-range');

      // FIX(16): validate on *every* 206, including a fresh start (start 0).
      // A buggy server answering a no-Range request with a 206 body starting
      // at a non-zero offset would otherwise corrupt the file silently.
      // `allowUnknown` skips `bytes */size` / missing headers on fresh starts,
      // but a resuming download still validates strictly.
      if (contentRange != null) {
        _validateContentRange(
          contentRange,
          expectedStart: actualResumeFrom,
          expectedEnd: knownFileSize > 0 ? knownFileSize - 1 : -1,
          expectedTotal: knownFileSize,
          punyUrl: punyUrl,
          allowUnknown: actualResumeFrom == 0,
        );
      }
    }

    final acceptRanges = response.headers.value('accept-ranges')?.toLowerCase();

    final serverSupportsResume = isPartialResponse || (acceptRanges == 'bytes');

    final finalUrlName = resolvedFileName ?? p.basename(localFilePath);

    var totalSize = knownFileSize;

    final contentLength = int.tryParse(
          response.headers.value(Headers.contentLengthHeader) ?? '',
        ) ??
        0;

    if (contentLength > 0) {
      final actualSize =
          (isPartialResponse ? actualResumeFrom : 0) + contentLength;

      if (actualSize != totalSize) {
        totalSize = actualSize;
      }
    }

    final sink = tempFile.openWrite(
      mode: actualResumeFrom > 0 ? FileMode.append : FileMode.write,
    );

    final stopwatch = Stopwatch()..start();

    var downloadedThisSession = 0;
    var downloadedTotal = actualResumeFrom;

    final speedSamples = Queue<_SpeedSample>();

    int lastReportTime = 0;
    int throttleBaseMs = -1;
    int? prevSpeedLimit;

    try {
      final stream = response.data?.stream;

      if (stream == null) {
        throw DioException(
          requestOptions: RequestOptions(path: punyUrl),
          type: DioExceptionType.badResponse,
          message: 'Server returned empty response body.',
        );
      }

      await for (final chunk in stream) {
        if (cancelToken.isCancelled) {
          throw DioException(
            requestOptions: RequestOptions(path: punyUrl),
            type: DioExceptionType.cancel,
            message: 'Download cancelled.',
          );
        }

        try {
          sink.add(chunk);
        } catch (e) {
          debugPrint('[DownloadEngine] Failed to write chunk to sink: $e');

          if (cancelToken.isCancelled) {
            throw DioException(
              requestOptions: RequestOptions(path: punyUrl),
              type: DioExceptionType.cancel,
              message: 'Download cancelled.',
            );
          }

          rethrow;
        }

        downloadedThisSession += chunk.length;
        downloadedTotal += chunk.length;

        final nowMs = stopwatch.elapsedMilliseconds;

        speedSamples.add(_SpeedSample(nowMs, downloadedTotal));

        while (speedSamples.isNotEmpty &&
            nowMs - speedSamples.first.timestampMs > 3000) {
          speedSamples.removeFirst();
        }

        var speed = 0.0;

        if (speedSamples.length > 1) {
          final first = speedSamples.first;
          final elapsedSeconds = (nowMs - first.timestampMs) / 1000.0;

          if (elapsedSeconds > 0) {
            speed = (downloadedTotal - first.bytes) / elapsedSeconds;
          }
        }

        final remaining = totalSize > 0 ? totalSize - downloadedTotal : 0;

        final rawEta = speed.isFinite && speed > 0 && remaining > 0
            ? (remaining / speed).round().clamp(0, 86400 * 365)
            : null;

        final eta = _applyEtaSmoothing(rawEta);

        final isCompleted = totalSize > 0 && downloadedTotal >= totalSize;

        if (nowMs - lastReportTime >= effectiveProgressReportIntervalMs ||
            isCompleted) {

          lastReportTime = nowMs;

          Future.microtask(() {
            try {
              onProgress(
                DownloadProgress(
                  downloadedBytes: downloadedTotal,
                  fileSize: totalSize,
                  speed: speed,
                  eta: eta,
                  supportsResume: serverSupportsResume,
                  fileName: finalUrlName,
                ),
              );
            } catch (e) {
              debugPrint('[DownloadEngine] onProgress callback failed: $e');
            }
          });
        }

        final limit = speedLimitBytesPerSecond();

        if (prevSpeedLimit != limit) {
          throttleBaseMs = stopwatch.elapsedMilliseconds;
          downloadedThisSession = 0;
          prevSpeedLimit = limit;
        }

        if (limit > 0) {
          final activeCount = activeDownloadCount().clamp(1, 1000);
          final perTaskLimit = limit / activeCount.toDouble();

          final expectedElapsedMs =
              (downloadedThisSession / perTaskLimit * 1000.0).round();

          final actualElapsedMs =
              stopwatch.elapsedMilliseconds - throttleBaseMs;

          if (expectedElapsedMs > actualElapsedMs) {
            final sleepTimeMs = (expectedElapsedMs - actualElapsedMs).clamp(
              0,
              30000,
            );

            if (sleepTimeMs > 0) {
              await Future<void>.delayed(Duration(milliseconds: sleepTimeMs));
            }
          }
        }
      }
    } finally {
      try {
        await sink.flush();
      } catch (e) {
        debugPrint('Single-thread sink flush failed: $e');
      }

      try {
        await sink.close();
      } catch (e) {
        debugPrint('Single-thread sink close failed: $e');
      }
    }

    final actualFileSize = await tempFile.length();

    Future.microtask(() {
      try {
        onProgress(
          DownloadProgress(
            downloadedBytes: actualFileSize,
            fileSize: totalSize > 0 ? totalSize : actualFileSize,
            speed: 0.0,
            eta: null,
            supportsResume: serverSupportsResume,
            fileName: finalUrlName,
          ),
        );
      } catch (e) {
        debugPrint('[DownloadEngine] onProgress callback failed: $e');
      }
    });

    if (totalSize > 0 && actualFileSize != totalSize) {
      if (actualFileSize > totalSize) {
        debugPrint(
          '[DownloadEngine] File is ${actualFileSize - totalSize} bytes larger '
          'than expected ($totalSize). Truncating.',
        );

        final raf = await tempFile.open(mode: FileMode.writeOnly);
        await raf.truncate(totalSize);
        await raf.close();
      } else {
        throw DownloadIntegrityException(
          'Download integrity check failed: expected $totalSize bytes, '
          'got $actualFileSize bytes.',
        );
      }
    }

    await File(localFilePath).parent.create(recursive: true);

    if (tempFilePath != localFilePath) {
      if (await File(localFilePath).exists()) {
        await File(localFilePath).delete();
      }

      try {
        await tempFile.rename(localFilePath);
      } catch (e) {
        debugPrint(
          'File rename failed (cross-device?), using copy fallback: $e',
        );

        await tempFile.copy(localFilePath);

        final copiedLen = await File(localFilePath).length();
        final origLen = await tempFile.length();

        if (copiedLen == origLen) {
          await tempFile.delete();
        } else {
          try {
            await File(localFilePath).delete();
          } catch (e, st) {
            Logger(
              'download_engine',
            ).warning('[download_engine] operation failed', e, st);
          }

          throw Exception('File copy verification failed on fallback rename.');
        }
      }
    }

    if (tempFilePath.isNotEmpty) {
      final stateFile = File('$tempFilePath.dmxstate');
      await _deleteFileIfExists(stateFile);
    }
  }

  String buildLocalFilePath(String directory, String fileName) {
    final safeName = safeFileName(fileName);
    final fullPath = p.join(directory, safeName);
    // Verify resolved path is still within target directory
    if (!p.isWithin(directory, fullPath)) {
      throw ArgumentError('Invalid file name: path traversal detected');
    }
    return fullPath;
  }

  String buildTempFilePath(String directory, String fileName) {
    return p.join(directory, '${safeFileName(fileName)}.dmxpart');
  }

  Future<void> _waitForState(
    int id,
    CancelToken cancelToken, {
    required bool Function(String stateLabel) predicate,
    required Duration timeout,
  }) async {
    final completer = Completer<void>();
    StreamSubscription? sub;
    Timer? t;
    String? lastSeenState;

    sub = TorrentService.torrentUpdates.listen((torrents) {
      final tor = torrents[id];
      if (tor != null) {
        lastSeenState = tor.stateLabel;
        if (predicate(tor.stateLabel.toLowerCase())) {
          if (!completer.isCompleted) completer.complete();
        }
      }
    });

    t = Timer(timeout, () {
      if (!completer.isCompleted) {
        debugPrint(
          '[DMX] _waitForState timed out after ${timeout.inSeconds}s. '
          'Last seen state: "$lastSeenState".',
        );
        // FIX(8): Do NOT proceed with incomplete verification. Pause the
        // torrent so later file-priority changes / resumes cannot corrupt
        // state, and surface a user-visible error.
        try {
          TorrentService.pauseTorrent(id);
        } catch (e, st) {
          Logger('download_engine').warning(
            '[download_engine] operation failed',
            e,
            st,
          );
        }
        completer.completeError(
          DioException(
            requestOptions: RequestOptions(path: 'torrent:$id'),
            type: DioExceptionType.receiveTimeout,
            message:
                'Torrent state check timed out. Download paused for safety.',
          ),
        );
      }
    });

    cancelToken.whenCancel.then((_) {
      if (!completer.isCompleted) {
        completer.completeError(
          DioException(
            requestOptions: RequestOptions(path: 'torrent:$id'),
            type: DioExceptionType.cancel,
            error: 'cancelled',
          ),
        );
      }
    });

    try {
      await completer.future;
    } finally {
      t.cancel();
      await sub.cancel();
    }
  }

  void _validateContentRange(
    String? value, {
    required int expectedStart,
    required int expectedEnd,
    required int expectedTotal,
    required String punyUrl,
    bool allowUnknown = false,
  }) {
    if (value == null || value.trim().isEmpty) {
      // FIX(16): on a fresh (non-resume) start a missing header is fine —
      // there is nothing to verify against.
      if (allowUnknown) return;
      debugPrint(
        '[DownloadEngine] No Content-Range header; skipping validation.',
      );
      return;
    }

    final match = RegExp(
      r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
      caseSensitive: false,
    ).firstMatch(value.trim());

    if (match == null) {
      // `bytes */size` or a malformed header: nothing to verify.
      if (allowUnknown) return;
      throw DioException(
        requestOptions: RequestOptions(path: punyUrl),
        type: DioExceptionType.badResponse,
        message: 'Malformed Content-Range response during resume: $value. '
            'Expected start: $expectedStart, expected end: $expectedEnd.',
      );
    }

    final start = int.tryParse(match.group(1) ?? '');
    final end = int.tryParse(match.group(2) ?? '');

    final totalText = match.group(3);
    final total =
        totalText == null || totalText == '*' ? null : int.tryParse(totalText);

    if (start != expectedStart ||
        (expectedEnd >= 0 && end != expectedEnd) ||
        (expectedTotal > 0 && total != null && total != expectedTotal)) {
      throw DioException(
        requestOptions: RequestOptions(path: punyUrl),
        type: DioExceptionType.badResponse,
        message: 'Invalid Content-Range response: $value. '
            'Expected start: $expectedStart, got start: $start. '
            'Got end: $end, expected end: $expectedEnd. '
            'Got total: $total, expected total: $expectedTotal.',
      );
    }
  }

  void close() {
    _closed = true;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;

    for (final token in List<CancelToken>.from(_activeCancelTokens)) {
      try {
        token.cancel('Engine closing');
      } catch (e) {
        debugPrint('[DMX] Failed to cancel token on engine close: $e');
      }
    }

    _activeCancelTokens.clear();

    _sharedDio.close(force: true);

    for (final client in _activeDioClients) {
      try {
        client.close(force: true);
      } catch (e) {
        debugPrint('[DMX] Failed to close Dio client on engine close: $e');
      }
    }

    _activeDioClients.clear();
    _reservedDioClients.clear();
    _dioClientCreationTimes.clear();
    _activeDownloadsPerClient.clear();

    final poolToClose = _pool;
    _pool = null;
    _poolInit = null;

    if (poolToClose != null) {
      unawaited(
        poolToClose.shutdown().catchError((e) {
          debugPrint('[DMX] Pool shutdown failed: $e');
        }),
      );
    }

    for (final id in List<int>.from(_activeTorrentIds)) {
      try {
        TorrentService.pauseTorrent(id);
      } catch (e, st) {
        Logger(
          'download_engine',
        ).warning('[download_engine] operation failed', e, st);
      }
    }

    _activeTorrentIds.clear();
  }

  /// FIX(4): Dynamically updates file priorities to enforce max concurrent files limit.
  /// Only the top N incomplete selected files get priority > 0 (actively download).
  ///
  /// FIX(12): throttled — the native `setFilePriorities` call is expensive and
  /// was previously issued on *every* torrent tick. Priorities are now only
  /// re-applied when a file just completed (so the next file in the queue
  /// starts immediately) or after a short interval.
  static const Duration _concurrentLimitThrottle = Duration(seconds: 2);
  static final Map<int, DateTime> _lastConcurrentLimitApply = {};
  static final Map<int, Set<int>> _lastIncompleteSnapshot = {};

  static void _applyMaxConcurrentFilesLimit(
    int torrentId,
    List<Map<String, dynamic>> files,
    int maxConcurrentFiles,
  ) {
    if (maxConcurrentFiles <= 0) return; // 0 = unlimited

    // Sort files by priority (descending), then by index
    final sortedIndices = List.generate(files.length, (i) => i)
      ..sort((a, b) {
        final prioA = (files[a]['priority'] as int?) ?? 4;
        final prioB = (files[b]['priority'] as int?) ?? 4;
        if (prioA != prioB) return prioB.compareTo(prioA);
        return a.compareTo(b);
      });

    // Collect indices of incomplete selected files
    final incompleteSelected = <int>[];
    final incompleteSet = <int>{};
    for (final idx in sortedIndices) {
      final f = files[idx];
      final selected = f['selected'] as bool? ?? true;
      final length = (f['length'] as num?)?.toInt() ?? 0;
      final downloaded = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      if (selected && downloaded < length) {
        incompleteSelected.add(idx);
        incompleteSet.add(idx);
      }
    }

    final now = DateTime.now();
    final lastApply = _lastConcurrentLimitApply[torrentId];
    final prevSnapshot = _lastIncompleteSnapshot[torrentId];

    // A file "just completed" if it was incomplete on the last application
    // but is now complete — that unblocks the next file in the queue.
    var fileCompleted = false;
    if (prevSnapshot != null) {
      for (final idx in prevSnapshot) {
        if (!incompleteSet.contains(idx)) {
          fileCompleted = true;
          break;
        }
      }
    }

    // FIX(12): skip the native call unless a file completed or the throttle
    // interval has elapsed.
    if (!fileCompleted &&
        lastApply != null &&
        now.difference(lastApply) < _concurrentLimitThrottle) {
      return;
    }

    // Build priority list: top N incomplete files get their priority, others get 0
    final priorities = List.filled(files.length, 0);
    for (var i = 0; i < incompleteSelected.length; i++) {
      final idx = incompleteSelected[i];
      if (i < maxConcurrentFiles) {
        priorities[idx] = (files[idx]['priority'] as int?) ?? 4;
      } else {
        priorities[idx] = 0; // Don't download yet
      }
    }

    _lastConcurrentLimitApply[torrentId] = now;
    _lastIncompleteSnapshot[torrentId] = incompleteSet;
    TorrentService.setFilePriorities(torrentId, priorities);
  }

  static void _distributeDownloadedBytesByPriority(
    List<Map<String, dynamic>> files,
    int totalDownloaded,
  ) {
    for (final f in files) {
      if (f['selected'] != true) {
        f['downloadedBytes'] = 0;
      }
    }

    final selected = files.where((f) => f['selected'] == true).toList();

    if (selected.isEmpty || totalDownloaded <= 0) return;

    // FIX-7: Clamp totalDownloaded to sum of selected file lengths
    final totalSelectedSize = selected.fold<int>(
      0,
      (sum, f) => sum + ((f['length'] as num?)?.toInt() ?? 0),
    );
    final clampedTotal = totalDownloaded.clamp(0, totalSelectedSize);

    final groups = <int, List<Map<String, dynamic>>>{};

    for (final f in selected) {
      final priority = (f['priority'] as int?) ?? 4;
      (groups[priority] ??= []).add(f);
    }

    final sortedKeys = groups.keys.toList()..sort((a, b) => b.compareTo(a));

    int remaining = clampedTotal;


    for (final priority in sortedKeys) {
      if (remaining <= 0) {
        for (final f in groups[priority]!) {
          f['downloadedBytes'] = 0;
        }
        continue;
      }

      final group = groups[priority]!;

      final groupSize = group.fold<int>(
        0,
        (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0),
      );

      if (groupSize <= 0) continue;

      if (remaining >= groupSize) {
        for (final f in group) {
          f['downloadedBytes'] = (f['length'] as num?)?.toInt() ?? 0;
        }
        remaining -= groupSize;
      } else {
        for (final f in group) {
          final length = (f['length'] as num?)?.toInt() ?? 0;

          if (length <= 0) {
            f['downloadedBytes'] = 0;
            continue;
          }

          if (remaining >= length) {
            f['downloadedBytes'] = length;
            remaining -= length;
          } else {
            f['downloadedBytes'] = remaining;
            remaining = 0;
          }
        }
      }
    }
  }

  int? _lastEta;

  int? _applyEtaSmoothing(int? rawEta) {
    if (rawEta == null) {
      _lastEta = null;
      return null;
    }
    final clamped = rawEta.clamp(0, 86400 * 365);
    if (_lastEta == null) {
      _lastEta = clamped;
      return clamped;
    }
    final smoothed = ((_lastEta! * 0.7) + (clamped * 0.3)).round();
    _lastEta = smoothed;
    return smoothed;
  }
}

typedef ValueChangedProgress = void Function(DownloadProgress progress);

class _SpeedSample {
  final int timestampMs;
  final int bytes;

  _SpeedSample(this.timestampMs, this.bytes);
}

class _ProgressReport {
  final bool shouldReport;
  final bool shouldSave;
  final List<int> snapshot;
  final int downloadedTotal;
  final double speed;
  final int? eta;

  _ProgressReport({
    required this.shouldReport,
    required this.shouldSave,
    required this.snapshot,
    required this.downloadedTotal,
    required this.speed,
    required this.eta,
  });
}

class _FileChangedOnServerException implements Exception {
  @override
  String toString() => 'FileChangedOnServerException: '
      'Server file changed during resume. Restart required.';
}

class DownloadIntegrityException implements Exception {
  final String message;

  const DownloadIntegrityException(this.message);

  @override
  String toString() => 'DownloadIntegrityException: $message';
}

String _redactUrl(String? url) {
  if (url == null || url.isEmpty) return '<empty>';

  final uri = Uri.tryParse(url);
  if (uri == null) return '<invalid-url>';

  final scheme = uri.scheme.isEmpty ? 'https' : uri.scheme;
  final host = uri.host.isEmpty ? '<host>' : uri.host;
  final port = uri.hasPort ? ':${uri.port}' : '';

  // FIX(16): redact path segments that look like embedded signatures / signed
  // tokens (long, token-like, containing digits). Query params are already
  // redacted wholesale; some CDNs also place credentials in the path.
  final redactedPath = uri.path
      .split('/')
      .map((s) => _looksLikePathToken(s) ? '<redacted>' : s)
      .join('/');

  return '$scheme://$host$port$redactedPath${uri.hasQuery ? '?<redacted>' : ''}';
}

bool _looksLikePathToken(String segment) {
  if (segment.isEmpty || segment.length < 24) return false;
  if (!RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(segment)) return false;
  return segment.contains(RegExp(r'[0-9]'));
}

int _perTaskSpeedLimit(int globalLimit, int activeCount) {
  if (globalLimit <= 0) return 0;

  final count = activeCount <= 0 ? 1 : activeCount;
  return (globalLimit / count).floor();
}

void _tryUpdateBandwidthGovernor(BandwidthGovernor governor, int limit) {
  governor.updateLimit(limit);
}

Future<void> _cancelAndAwaitFutures(
  List<CancelToken> tokens,
  List<Future<void>> futures, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  for (final token in tokens) {
    if (!token.isCancelled) {
      try {
        token.cancel();
      } catch (e, st) {
        Logger(
          'download_engine',
        ).warning('[download_engine] operation failed', e, st);
      }
    }
  }

  if (futures.isEmpty) return;

  try {
    await Future.any([
      Future.wait(
        futures.map(
          (f) => f.catchError((e, st) {
            Logger(
              'download_engine',
            ).warning('[download_engine] operation failed', e, st);
          }),
        ),
      ),
      Future.delayed(timeout),
    ]);
  } catch (e, st) {
    Logger('download_engine')
        .warning('[DMX] _cancelAndAwaitFutures timed out', e, st);
  }
}

Future<void> _deleteFileIfExists(File file) async {
  try {
    if (await file.exists()) {
      await file.delete();
    }
  } catch (e, st) {
    Logger(
      'download_engine',
    ).warning('[download_engine] operation failed', e, st);
  }
}

String? _firstNonEmpty(String? a, String? b) {
  if (a != null && a.trim().isNotEmpty) return a;
  if (b != null && b.trim().isNotEmpty) return b;
  return null;
}

class _DiskSpaceInfo {
  final int freeBytes;
  const _DiskSpaceInfo({required this.freeBytes});
}

class _SettingsProviderWrapper {
  final bool adaptiveThreads;
  _SettingsProviderWrapper(this.adaptiveThreads);
}

class _MutableDownloadTask extends DownloadTask {
  double _speed = 0.0;

  @override
  double get speed => _speed;

  set speed(double val) => _speed = val;

  _MutableDownloadTask({
    required super.id,
    required super.fileName,
    required super.url,
    required super.fileSize,
    required super.downloadedBytes,
    required super.category,
    required super.status,
    required super.savePath,
    required super.localFilePath,
    required super.tempFilePath,
    required super.threadCount,
    required super.chunks,
    required super.createdAt,
    required super.updatedAt,
    super.supportsResume,
  });
}

class _RangeSample {
  final int start;
  final int length;
  const _RangeSample(this.start, this.length);
}
