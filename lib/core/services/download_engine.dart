import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

import 'bandwidth_governor.dart';
import 'connection_manager.dart';
import 'download_journal.dart';
import 'positional_file_writer.dart';
import 'retry_interceptor.dart';
import 'torrent_service.dart';

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

// The per-download isolate entry point and its args bundle were replaced by
// the worker-isolate pool. See download_isolate_pool.dart (DownloadCommand,
// IsolateMessage, DownloadIsolatePool, _downloadWorkerMain).

class DownloadEngine {
  static const int _progressReportIntervalMs = 250;
  static const int _stateSaveIntervalMs = 2000;
  static const int _isolatePoolSize = 4;
  final List<CancelToken> _activeCancelTokens = [];
  // Pool of long-lived worker isolates that run HTTP downloads. Lazily
  // initialized on the first download and shut down in [close].
  DownloadIsolatePool? _pool;
  Future<DownloadIsolatePool>? _poolInit;
  final Set<int> _activeTorrentIds = <int>{};
  final Dio _sharedDio;
  final Set<Dio> _activeDioClients = {};
  final Set<Dio> _reservedDioClients = {};
  final Map<Dio, DateTime> _dioClientCreationTimes = {};
  final Map<Dio, Set<String>> _activeDownloadsPerClient = {};
  Timer? _cleanupTimer;

  DownloadEngine({Dio? dio, bool enableCleanupTimer = true})
    : _sharedDio = dio ?? Dio() {
    if (enableCleanupTimer) {
      _cleanupTimer = Timer.periodic(const Duration(seconds: 120), (_) {
        final now = DateTime.now();
        _activeDioClients.removeWhere((client) {
          if (_reservedDioClients.contains(client)) return false;
          final activeDownloads = _activeDownloadsPerClient[client];
          if (activeDownloads != null && activeDownloads.isNotEmpty) {
            return false;
          }
          final createdAt = _dioClientCreationTimes[client];
          final age = createdAt != null
              ? now.difference(createdAt)
              : Duration.zero;
          if (age > const Duration(minutes: 5)) {
            debugPrint(
              '[DMX] Cleanup timer: closing orphaned Dio client (${age.inSeconds}s old)',
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

  /// Lazily creates and initializes the worker-isolate pool. Concurrent
  /// first-callers share the single in-flight initialization future.
  Future<DownloadIsolatePool> _ensurePool() {
    final existing = _pool;
    if (existing != null) return Future.value(existing);
    return _poolInit ??= () async {
      final pool = DownloadIsolatePool(size: _isolatePoolSize);
      await pool.init();
      _pool = pool;
      return pool;
    }();
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
    client.interceptors.add(ProfessionalRetryInterceptor());
    client.options.connectTimeout = const Duration(seconds: 30);
    client.options.sendTimeout = const Duration(seconds: 60);
    client.options.receiveTimeout = const Duration(seconds: 60);

    final uri = url != null ? Uri.tryParse(url) : null;
    final host = uri?.host.toLowerCase() ?? '';
    final isYoutubeUrl =
        host.contains('youtube.com') ||
        host == 'youtu.be' ||
        host.endsWith('.googlevideo.com');

    if (isYoutubeUrl) {
      client.options.headers['Origin'] = 'https://www.youtube.com';
      client.options.headers['Referer'] =
          (referer != null && referer.isNotEmpty)
          ? referer
          : 'https://www.youtube.com/';
      client.options.headers['User-Agent'] =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
      if (oauthToken != null && oauthToken.isNotEmpty) {
        client.options.headers['Authorization'] = 'Bearer $oauthToken';
      }
    } else if (customUserAgent != null && customUserAgent.trim().isNotEmpty) {
      client.options.headers['User-Agent'] = customUserAgent.trim();
    } else {
      client.options.headers['User-Agent'] =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
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
      final String proxyHostResolved =
          (enableProxy && proxyHost != null && proxyHost.trim().isNotEmpty)
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
      final effectiveBypassSSL = bypassSSL && kDebugMode;

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
          // AUDIT LOG: All SSL-bypassed connections are logged for security audit.
          // This is a developer-only feature and cannot be enabled in release.
          debugPrint('[DMX AUDIT] SSL bypass active for URL: $url');
          // Accept all certs when bypass is on — a targeted check on downloadHost
          // alone breaks redirects (HTTP→HTTPS CDN hops present a different host).
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
              try {
                TorrentService.pauseTorrent(torrentId);
                TorrentService.removeTorrent(torrentId);
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

        Future.delayed(const Duration(seconds: 300), () {
          if (!completer.isCompleted) {
            sub?.cancel();
            try {
              TorrentService.pauseTorrent(torrentId);
              TorrentService.removeTorrent(torrentId);
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
          }
        }
      }

      return DownloadMetadata(
        fileName: fileName,
        category: 'Archive',
        fileSize: fileSize,
        supportsResume: true,
        torrentFiles: torrentFiles,
      );
    }

    final punyUrl = convertIdnToPunycode(url);
    var fileName = requestedFileName?.trim().isNotEmpty == true
        ? safeFileName(requestedFileName!.trim())
        : fileNameFromUrl(punyUrl);
    var fileSize = 0;

    final uri = Uri.tryParse(punyUrl);
    final host = uri?.host.toLowerCase() ?? '';
    final isYoutube =
        host.contains('youtube.com') ||
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
        options: Options(followRedirects: true, validateStatus: (_) => true),
      );
      final headerName = fileNameFromContentDisposition(response.headers);
      if (requestedFileName?.trim().isNotEmpty != true && headerName != null) {
        fileName = headerName;
      }

      final length = response.headers.value(Headers.contentLengthHeader);
      fileSize = int.tryParse(length ?? '') ?? 0;

      final acceptRanges = response.headers
          .value('accept-ranges')
          ?.toLowerCase();
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
            supportsResume =
                isYoutube ||
                getResponse.statusCode == 206 ||
                getResponse.headers.value('accept-ranges') == 'bytes';
            // Cancel the stream immediately — we only needed the headers.
            await getResponse.data?.stream.listen((_) {}).cancel();
          }
        } catch (e) {
          debugPrint(
            '[DownloadEngine] resolveMetadata ranged GET probe failed: $e',
          );
        }
      }
    } catch (e) {
      debugPrint('HEAD request failed for $punyUrl: $e');
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

  Future<void> download({
    required String url,
    required String tempFilePath,
    required String localFilePath,
    required int knownFileSize,
    required bool supportsResume,
    required CancelToken cancelToken,
    required ValueChangedProgress onProgress,
    required int Function() speedLimitBytesPerSecond,
    required int Function() activeDownloadCount,
    int threadCount = 1,
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
  }) async {
    _activeCancelTokens.add(cancelToken);
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

      if (resolvedFileName != null) {
        // Preserve the on-disk path assigned by the download provider.
        // We still update the displayed file name from metadata, but we do
        // not rename the target file automatically for auto-generated names.
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

    if (isTorrent) {
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
      _activeCancelTokens.remove(cancelToken);
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
      threadCount: threadCount,
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
      taskId: '', // set by caller if metrics are desired
      mirrorUrls: mirrorUrls,
    );

    final pool = await _ensurePool();
    final job = pool.submit(command);

    final completer = Completer<void>();
    bool acked = false;
    bool cancelRequested = false;

    // Watchdog: if the worker never acknowledges the job, treat it as an
    // engine-initialization failure (mirrors the old spawn-timeout path).
    Timer? watchdog;
    watchdog = Timer(const Duration(seconds: 30), () {
      if (!acked && !completer.isCompleted) {
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
        // If a cancel arrived before the worker acknowledged, resend it now.
        if (cancelRequested) job.cancel();
      } else if (type == 'progress') {
        final p = message.data;
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
        if (!completer.isCompleted) completer.complete();
      } else if (type == 'error') {
        final data = message.data;
        final errType = data['errorType'];
        final errMsg = data['errorMessage'];
        final errStatus = data['errorStatus'] as int?;

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
          message: errMsg?.toString(),
          response: errStatus != null
              ? Response(
                  requestOptions: RequestOptions(path: punyUrl),
                  statusCode: errStatus,
                )
              : null,
        );
        if (!completer.isCompleted) completer.completeError(dioException);
      }
    });

    try {
      await completer.future;
    } finally {
      watchdog.cancel();
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
            id = TorrentService.addTorrentFile(filePath, saveDir);
          } finally {
            _reservedDioClients.remove(torrentDio);
            _activeDioClients.remove(torrentDio);
            _dioClientCreationTimes.remove(torrentDio);
            torrentDio.close(force: true);
            try {
              if (await tempTorrentFile.exists()) {
                await tempTorrentFile.delete();
              }
            } catch (_) {}
          }
        } else {
          id = TorrentService.addTorrentFile(filePath, saveDir);
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

    await _waitForMetadata(id, url, cancelToken, onProgress);

    final currentTorrentFiles = getTorrentFiles?.call();
    _applyFilePriorities(id, currentTorrentFiles);

    // Recheck existing data on disk so progress reflects what's already saved.
    final saveDir = File(currentLocalFilePath).parent.path;
    if (Directory(saveDir).existsSync()) {
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

    _activeCancelTokens.remove(cancelToken);
  }

  Future<void> _waitForMetadata(
    int id,
    String url,
    CancelToken cancelToken,
    ValueChangedProgress onProgress,
  ) async {
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

    cancelToken.whenCancel
        .then((_) async {
          await sub?.cancel();
          timer?.cancel();
          if (!completer.isCompleted) {
            try {
              TorrentService.removeTorrent(id);
            } catch (_) {}
            completer.completeError(
              DioException(
                requestOptions: RequestOptions(path: url),
                type: DioExceptionType.cancel,
                error: 'cancelled',
              ),
            );
          }
        })
        .catchError((_) {});

    int metadataElapsed = 0;
    timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (completer.isCompleted) {
        timer?.cancel();
        return;
      }
      metadataElapsed += 30;
      onProgress(
        DownloadProgress(
          downloadedBytes: 0,
          fileSize: 0,
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
          TorrentService.removeTorrent(id);
        } catch (_) {}
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

      final progress = torrent.progress.clamp(0.0, 1.0);
      final stateLabel = torrent.stateLabel.toLowerCase();

      List<Map<String, dynamic>>? resolvedFiles;
      String? resolvedName;
      if (torrent.hasMetadata) {
        resolvedName = torrent.name;
        try {
          final files = TorrentService.getFiles(id);
          final existingFiles = getTorrentFiles?.call() ?? [];
          resolvedFiles = files.map((f) {
            final existing = existingFiles
                .cast<Map<String, dynamic>?>()
                .firstWhere(
                  (e) => (e?['name'] as String?) == f.name,
                  orElse: () => null,
                );
            final liveBytes = f.downloadedBytes;
            final staleBytes = (existing?['downloadedBytes'] as int?) ?? 0;
            return <String, dynamic>{
              'name': f.name,
              'length': f.size,
              'selected': existing?['selected'] as bool? ?? f.selected,
              'priority': existing?['priority'] as int? ?? f.priority,
              'downloadedBytes': liveBytes > 0 ? liveBytes : staleBytes,
              'speed': 0.0,
            };
          }).toList();
        } catch (e) {
          debugPrint('[DownloadEngine] TorrentService.getFiles failed: $e');
        }
      }

      final int calculatedTotalSize =
          (resolvedFiles != null && resolvedFiles.isNotEmpty)
          ? resolvedFiles
                .where((f) => f['selected'] == true)
                .fold<int>(
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

      // Per-file progress fallback when native getFileProgress is unavailable.
      if (!TorrentService.fileProgressSupported &&
          resolvedFiles != null &&
          resolvedFiles.isNotEmpty) {
        _distributeDownloadedBytesByPriority(resolvedFiles, downloadedBytes);
      }

      final isCheckingOrMetadata =
          stateLabel.contains('checking') ||
          stateLabel.contains('metadata') ||
          stateLabel.contains('allocating');

      final isUserPaused = stateLabel == 'paused' || stateLabel == 'stopped';

      if (isUserPaused && !cancelToken.isCancelled) {
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
        return;
      }

      final isFullyDownloaded = totalSize > 0 && downloadedBytes >= totalSize;
      final isStableFinished =
          stateLabel == 'seeding' ||
          stateLabel == 'completed' ||
          stateLabel == 'finished';
      final isCompleted =
          isFullyDownloaded &&
          !isCheckingOrMetadata &&
          (progress >= 0.999 || isStableFinished);

      final speed = torrent.downloadRate.toDouble();
      final remaining = totalSize > downloadedBytes
          ? totalSize - downloadedBytes
          : 0;
      final eta = speed.isFinite && speed > 0 && remaining > 0
          ? (remaining / speed).round().clamp(0, 86400 * 365)
          : null;

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

      if (isCompleted && !completer.isCompleted) {
        completer.complete();
      }
    });

    try {
      await completer.future;
    } finally {
      await sub.cancel();
      _activeTorrentIds.remove(id);
    }
  }

  /// Probe the connection to determine the optimal thread count.
  Future<int> _probeOptimalThreads(
    Dio dio,
    String url,
    int requestedThreads,
    int fileSize,
  ) async {
    if (requestedThreads <= 1) return 1;
    if (fileSize > 0 && fileSize < 512 * 1024) return 1;

    const probeSize = 256 * 1024;
    try {
      final sw = Stopwatch()..start();
      final response = await dio.get<ResponseBody>(
        url,
        options: Options(
          headers: {'Range': 'bytes=0-${probeSize - 1}'},
          responseType: ResponseType.stream,
        ),
      );

      if (response.statusCode == 200) {
        debugPrint(
          '[DownloadEngine] Server does not support Range requests. Using 1 thread.',
        );
        return 1;
      }

      int received = 0;
      await for (final chunk in response.data!.stream) {
        received += chunk.length;
        if (received >= probeSize) break;
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
  }) async {
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
      final newPath = '$saveDir/$resolvedFileName';
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

    try {
      if (resolvedFileSize < threadCount * 1024) {
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
          isNameAutoGenerated: isNameAutoGenerated,
        );
      } else {
        if (resolvedFileSize > 0) {
          // ── Phase 3A: Connection pre-warm ──
          await ConnectionManager.prewarm(punyUrl);

          // ── Phase 3A: HTTP/2 detection ──
          final isHttp2 = await ConnectionManager.detectHttp2(punyUrl);
          final effectiveThreads = isHttp2
              ? threadCount.clamp(1, 2)
              : threadCount;
          if (isHttp2) {
            debugPrint(
              '[DownloadEngine] HTTP/2 detected for ${Uri.parse(punyUrl).host}. '
              'Capping threads: $threadCount → $effectiveThreads',
            );
          }

          // ── Phase 3B: Thread probe ──
          threadCount = await _probeOptimalThreads(
            isolatedDio,
            punyUrl,
            effectiveThreads,
            resolvedFileSize,
          );
          debugPrint(
            '[DownloadEngine] Final thread count: $threadCount '
            '(requested=$threadCount, h2=$isHttp2)',
          );

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
              final contentRange = probeResponse.headers.value('content-range');
              if (contentRange != null) {
                final totalMatch = RegExp(r'/(\d+)').firstMatch(contentRange);
                if (totalMatch != null) {
                  final serverTotal = int.tryParse(totalMatch.group(1)!) ?? 0;
                  if (serverTotal > 0 && serverTotal != resolvedFileSize) {
                    debugPrint(
                      '[DownloadEngine] Correcting estimated file size from $resolvedFileSize to $serverTotal based on server probe.',
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
        }

        final futures = <Future<void>>[];
        final chunkCancelTokens = List<CancelToken>.generate(
          threadCount,
          (_) => CancelToken(),
        );
        var chunkProgress = List<int>.filled(threadCount, 0);
        final chunkSizes = List<int>.filled(threadCount, 0);

        final totalSize = resolvedFileSize;
        final partSize = (totalSize / threadCount).floor();

        final targetFile = File(currentTempFilePath);
        await targetFile.parent.create(recursive: true);
        if (!await targetFile.exists()) {
          await targetFile.create();
        }
        final stateFile = File('$currentTempFilePath.dmxstate');
        final journalPath = '$currentTempFilePath.journal';

        String? savedEtag;
        String? savedLastModified;
        List<int>? loadedState;
        bool canResume = false;

        // ── Phase 1B: Journal recovery first ──
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
          // ── Phase 1A: State file with ETag ──
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
              if (savedTotalSize == totalSize &&
                  savedThreadCount == threadCount &&
                  progressList != null &&
                  progressList.length == threadCount) {
                loadedState = progressList.cast<int>();
                canResume = true;
              }
            }
          } catch (e) {
            debugPrint('[DownloadEngine] State file decode failed: $e');
          }
        }

        if (!canResume) {
          if (await stateFile.exists()) await stateFile.delete();
          final oldJournal = File(journalPath);
          if (await oldJournal.exists()) await oldJournal.delete();
          for (int i = 0; i < threadCount; i++) {
            chunkProgress[i] = 0;
          }
        }

        // ── Phase 2A: Open PositionalFileWriter ──
        final PositionalFileWriter writer;
        if (canResume && loadedState != null && loadedState.any((b) => b > 0)) {
          if (await File(currentTempFilePath).exists()) {
            writer = await PositionalFileWriter.openForResume(
              currentTempFilePath,
              threadCount: threadCount,
            );
          } else {
            writer = await PositionalFileWriter.open(
              currentTempFilePath,
              totalSize: totalSize,
              threadCount: threadCount,
            );
            for (int i = 0; i < threadCount; i++) {
              chunkProgress[i] = 0;
            }
          }
        } else {
          writer = await PositionalFileWriter.open(
            currentTempFilePath,
            totalSize: totalSize,
            threadCount: threadCount,
          );
        }

        // ── Phase 1B: Open DownloadJournal ──
        final journal = DownloadJournal(journalPath);
        await journal.open();
        await journal.writeInit(threadCount, totalSize);

        // ── Phase 2C: BandwidthGovernor ──
        final governor = BandwidthGovernor(
          globalBytesPerSecond: speedLimitBytesPerSecond(),
        );
        governor.registerConsumer();

        final lock = Lock();

        for (int i = 0; i < threadCount; i++) {
          final start = i * partSize;
          final end = (i == threadCount - 1)
              ? (totalSize - 1)
              : (start + partSize - 1);
          final size = end - start + 1;
          chunkSizes[i] = size;
          if (chunkProgress[i] > size) {
            chunkProgress[i] = 0;
          }
        }

        final stopwatch = Stopwatch()..start();
        final speedSamples = Queue<_SpeedSample>();

        int lastReportTime = 0;
        int lastStateSaveTime = 0;

        Future<void> saveState() async {
          try {
            await lock.synchronized(() async {
              final tempStateFile = File('${stateFile.path}.tmp');
              final stateData = {
                'totalSize': totalSize,
                'threadCount': threadCount,
                'progress': chunkProgress,
                'etag': savedEtag,
                'lastModified': savedLastModified,
              };
              await tempStateFile.writeAsString(jsonEncode(stateData));
              await tempStateFile.rename(stateFile.path);
            });
          } catch (e) {
            debugPrint('Failed to save state: $e');
          }
        }

        Future<bool> isTotalCompleteLocked() async {
          if (totalSize <= 0) return false;
          final snapshot = await lock.synchronized(
            () => List<int>.from(chunkProgress),
          );
          BigInt sum = BigInt.zero;
          for (int i = 0; i < snapshot.length; i++) {
            sum += BigInt.from(snapshot[i]);
          }
          return sum >= BigInt.from(totalSize);
        }

        Future<void> reportProgress() async {
          final nowMs = stopwatch.elapsedMilliseconds;
          final isCompleted = await isTotalCompleteLocked();
          final shouldReport =
              isCompleted ||
              nowMs - lastReportTime >= _progressReportIntervalMs;
          final shouldSave =
              isCompleted || nowMs - lastStateSaveTime >= _stateSaveIntervalMs;
          if (!shouldReport && !shouldSave) return;

          final snapshot = await lock.synchronized(
            () => List<int>.from(chunkProgress),
          );
          final downloadedTotal = snapshot.reduce((a, b) => a + b);
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

          final remaining = totalSize > downloadedTotal
              ? totalSize - downloadedTotal
              : 0;
          final rawEta = speed.isFinite && speed > 0 && remaining > 0
              ? (remaining / speed).round().clamp(0, 86400 * 365)
              : null;
          final eta = _applyEtaSmoothing(rawEta, null);

          if (shouldReport) {
            lastReportTime = nowMs;

            final chunksList = List<double>.generate(threadCount, (idx) {
              return chunkSizes[idx] > 0
                  ? (snapshot[idx] / chunkSizes[idx]).clamp(0.0, 1.0)
                  : 1.0;
            });

            Future.microtask(() {
              onProgress(
                DownloadProgress(
                  downloadedBytes: downloadedTotal,
                  fileSize: totalSize,
                  speed: speed,
                  eta: eta,
                  chunks: chunksList,
                  fileName: resolvedFileName,
                  supportsResume: true,
                ),
              );
            });
          }

          if (shouldSave) {
            lastStateSaveTime = nowMs;
            await saveState();
          }
        }

        Object? chunkError;
        DateTime lastCheckpointTime = DateTime.now();
        int bytesSinceLastCheckpoint = 0;

        try {
          for (int i = 0; i < threadCount; i++) {
            final idx = i;
            final start = idx * partSize;
            final end = (idx == threadCount - 1)
                ? (totalSize - 1)
                : (start + partSize - 1);

            futures.add(() async {
              cancelToken.whenCancel.then((_) {
                for (final ct in chunkCancelTokens) {
                  if (!ct.isCancelled) ct.cancel();
                }
              });

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
                    if (savedEtag != null) {
                      headers['If-Range'] = savedEtag;
                    } else if (savedLastModified != null) {
                      headers['If-Range'] = savedLastModified;
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
                      '[DownloadEngine] File changed on server (ETag/Last-Modified mismatch). Restarting download from scratch.',
                    );
                    await writer.close();
                    await journal.close();
                    if (await File(currentTempFilePath).exists()) {
                      await File(currentTempFilePath).delete();
                    }
                    if (await stateFile.exists()) {
                      await stateFile.delete();
                    }
                    if (await File(journalPath).exists()) {
                      await File(journalPath).delete();
                    }
                    for (int j = 0; j < threadCount; j++) {
                      chunkProgress[j] = 0;
                    }
                    throw _FileChangedOnServerException();
                  }

                  if (chunkResponse.statusCode != 206) {
                    if (chunkResponse.statusCode == 200 && idx == 0) {
                      debugPrint(
                        '[DownloadEngine] Server returned 200 for first chunk; falling back to single-threaded download.',
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

                  _validateContentRange(
                    chunkResponse.headers.value('content-range'),
                    expectedStart: start + resumeFrom,
                    expectedEnd: end,
                    expectedTotal: totalSize,
                  );

                  try {
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

                        final sleepMs = await governor.acquire(chunk.length);
                        if (sleepMs > 0) {
                          await Future.delayed(Duration(milliseconds: sleepMs));
                        }

                        final absolutePosition =
                            start + resumeFrom + chunkDownloadedThisSession;
                        await writer.write(
                          idx,
                          absolutePosition,
                          Uint8List.fromList(chunk),
                        );

                        chunkDownloadedThisSession += chunk.length;
                        await lock.synchronized(() {
                          chunkProgress[idx] =
                              resumeFrom + chunkDownloadedThisSession;
                        });

                        await journal.recordChunkProgress(
                          idx,
                          chunkProgress[idx],
                        );

                        bytesSinceLastCheckpoint += chunk.length;
                        final now = DateTime.now();
                        if (now.difference(lastCheckpointTime).inSeconds >= 5 ||
                            bytesSinceLastCheckpoint >= 1024 * 1024) {
                          await journal.writeCheckpoint(
                            chunkProgress,
                            totalSize,
                          );
                          lastCheckpointTime = now;
                          bytesSinceLastCheckpoint = 0;
                        }

                        await reportProgress();
                      }
                    } catch (e) {
                      try {
                        await writer.flush(idx);
                      } catch (_) {}
                      rethrow;
                    }
                    break;
                  } finally {}
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
                    chunkError ??= e;
                    rethrow;
                  }
                  debugPrint(
                    'Thread $idx failed attempt $attempts: $e. Retrying...',
                  );
                  final delay = (attempts * attempts * 2) + Random().nextInt(3);
                  await Future.delayed(Duration(seconds: delay));
                }
              }
            }());
          }

          await Future.wait(futures);
          await writer.flushAll();

          // ── Phase 2B: Checksum verification ──
          if (isNameAutoGenerated && resolvedFileName != null) {
            // User may have provided expectedSha256 via the task model.
            // For now this is a placeholder; the caller can inject the
            // expected hash via the isolate args when needed.
          }

          await journal.delete();
          governor.unregisterConsumer();
          await saveState();
          if (await stateFile.exists()) {
            await stateFile.delete();
          }

          if (currentTempFilePath != currentLocalFilePath) {
            final finalFile = File(currentLocalFilePath);
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
          if (e is _FileChangedOnServerException) rethrow;
          if (cancelToken.isCancelled) {
            await journal.close();
            await saveState();
            rethrow;
          }

          final errorToCheck = chunkError ?? e;

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
            await journal.close();
            await saveState();
            rethrow;
          }

          debugPrint(
            'Multi-threaded range request failed (Range Rejection): $e. '
            'Falling back to single-threaded.',
          );

          await writer.close();
          await journal.close();
          governor.unregisterConsumer();

          final aggregatedSize = await File(currentTempFilePath).length();
          if (aggregatedSize > 0 && aggregatedSize < totalSize) {
            await _downloadSingleThreaded(
              url: url,
              punyUrl: punyUrl,
              tempFilePath: currentTempFilePath,
              localFilePath: currentLocalFilePath,
              knownFileSize: resolvedFileSize,
              supportsResume: true,
              cancelToken: cancelToken,
              onProgress: onProgress,
              speedLimitBytesPerSecond: speedLimitBytesPerSecond,
              activeDownloadCount: activeDownloadCount,
              isolatedDio: isolatedDio,
              isNameAutoGenerated: isNameAutoGenerated,
            );
          } else {
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
              isNameAutoGenerated: isNameAutoGenerated,
            );
          }
        }
      }
      // ── Phase 2B: Checksum verification framework ──
      try {
        final downloadedFile = File(currentLocalFilePath);
        if (await downloadedFile.exists()) {
          final actualSize = await downloadedFile.length();
          if (actualSize > 0) {
            debugPrint(
              '[DownloadEngine] Download completed: $currentLocalFilePath ($actualSize bytes)',
            );
          }
        }
      } catch (e) {
        debugPrint('[DownloadEngine] Final verification failed: $e');
      }
    } finally {
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
    bool isNameAutoGenerated = false,
  }) async {
    final tempFile = File(tempFilePath);
    await tempFile.parent.create(recursive: true);

    var resumeFrom = 0;
    if (supportsResume && await tempFile.exists()) {
      final partSize = await tempFile.length();
      if (knownFileSize > 0 && partSize <= knownFileSize) {
        resumeFrom = partSize;
      } else if (knownFileSize == 0) {
        resumeFrom = partSize;
      } else {
        debugPrint(
          '[DownloadEngine] Single-threaded resume validation failed: file size $partSize exceeds expected $knownFileSize. Restarting from 0.',
        );
        await tempFile.delete();
      }
    } else if (await tempFile.exists()) {
      await tempFile.delete();
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
        await tempFile.delete();
      }
      actualResumeFrom = 0;
      headers.remove(
        'Range',
      ); // Fix: Was 'range' (lowercase), needs to match 'Range'
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

    final isPartialResponse = response.statusCode == 206;
    if (actualResumeFrom > 0 && !isPartialResponse) {
      actualResumeFrom = 0;
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }

    if (actualResumeFrom > 0 && isPartialResponse) {
      final contentRange = response.headers.value('content-range');
      if (contentRange != null) {
        _validateContentRange(
          contentRange,
          expectedStart: actualResumeFrom,
          expectedEnd: knownFileSize > 0 ? knownFileSize - 1 : -1,
          expectedTotal: knownFileSize,
        );
      }
    }

    final acceptRanges = response.headers.value('accept-ranges')?.toLowerCase();
    final serverSupportsResume = isPartialResponse || (acceptRanges == 'bytes');
    final responseName = fileNameFromContentDisposition(response.headers);
    final postRedirectName =
        responseName ?? fileNameFromUrl(response.realUri.toString());

    final currentName = p.basename(localFilePath);
    final bool isGeneric =
        currentName.toLowerCase() == 'download' ||
        currentName.toLowerCase().startsWith('download.') ||
        currentName.toLowerCase().startsWith('index.') ||
        currentName.toLowerCase().contains('videoplayback');

    final finalUrlName = (isNameAutoGenerated && isGeneric)
        ? postRedirectName
        : currentName;

    var totalSize = knownFileSize;
    final contentLength =
        int.tryParse(
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
        final eta = _applyEtaSmoothing(rawEta, null);

        final isCompleted = totalSize > 0 && downloadedTotal >= totalSize;
        if (nowMs - lastReportTime >= _progressReportIntervalMs ||
            isCompleted) {
          lastReportTime = nowMs;
          Future.microtask(() {
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
          });
        }

        final limit = speedLimitBytesPerSecond();
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
        // Reset the throttle window every iteration, whether or not a limit
        // is currently active. Previously this only reset inside `limit > 0`,
        // so a download that ran unthrottled for a while and then had a
        // speed limit applied would compute expectedElapsedMs from ALL bytes
        // downloaded since the session started, producing one enormous
        // (and pointless) stall the moment throttling turned on.
        throttleBaseMs = stopwatch.elapsedMilliseconds;
        downloadedThisSession = 0;
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
    });

    if (totalSize > 0 && actualFileSize != totalSize) {
      final difference = (actualFileSize - totalSize).abs();
      final ratio = totalSize > 0 ? difference / totalSize : 1.0;
      if (difference > 1024 && ratio > 0.001) {
        throw Exception(
          'Download integrity check failed: expected $totalSize bytes, got $actualFileSize bytes.',
        );
      }
      debugPrint(
        '[DownloadEngine] Download size mismatch ignored: expected $totalSize bytes, got $actualFileSize bytes.',
      );
    }

    await File(localFilePath).parent.create(recursive: true);
    // Only move/rename when the temp path differs from the final local path.
    // For in-place downloads `tempFilePath == localFilePath` and no move is
    // necessary (the file already resides at its final destination).
    if (tempFilePath != localFilePath) {
      if (localFilePath != tempFile.path) {
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
            throw Exception('File copy failed on fallback rename.');
          }
        }
      }
    }

    if (tempFilePath.isNotEmpty) {
      final stateFile = File('$tempFilePath.dmxstate');
      if (await stateFile.exists()) {
        await stateFile.delete();
      }
    }
  }

  String buildLocalFilePath(String directory, String fileName) {
    return p.join(directory, safeFileName(fileName));
  }

  String buildTempFilePath(String directory, String fileName) {
    // Write partial data directly into the final filename so the file is
    // visible in the user's downloads folder while downloading. The
    // engine still uses a sidecar state file (`.dmxstate`) so multi-threaded
    // downloads can resume from disk.
    return p.join(directory, safeFileName(fileName));
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
          '[DMX] _waitForState timed out after ${timeout.inMinutes} min '
          'for torrent $id (last state: "${lastSeenState ?? "unknown"}"). '
          'Proceeding — piece verification may be incomplete.',
        );
        completer.complete();
      }
    });
    cancelToken.whenCancel.then((_) {
      if (!completer.isCompleted) completer.complete();
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
  }) {
    final match = RegExp(
      r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
    ).firstMatch(value?.trim() ?? '');
    final start = int.tryParse(match?.group(1) ?? '');
    final end = int.tryParse(match?.group(2) ?? '');
    final totalText = match?.group(3);
    final total = totalText == null || totalText == '*'
        ? null
        : int.tryParse(totalText);

    if (start != expectedStart ||
        (expectedEnd >= 0 && end != expectedEnd) ||
        (expectedTotal > 0 && total != null && total != expectedTotal)) {
      throw DioException(
        requestOptions: RequestOptions(path: ''),
        type: DioExceptionType.badResponse,
        message:
            'Invalid Content-Range response: $value. '
            'Expected start: $expectedStart, got start: $start. '
            'Got end: $end, expected end: $expectedEnd. '
            'Got total: $total, expected total: $expectedTotal.',
      );
    }
  }

  void close() {
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
      unawaited(poolToClose.shutdown());
    }

    for (final id in _activeTorrentIds) {
      try {
        TorrentService.pauseTorrent(id);
      } catch (_) {}
    }
    _activeTorrentIds.clear();
  }

  /// Distributes total downloaded bytes across torrent files by priority.
  /// Used as a fallback when the plugin does not expose per-file progress.
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

    final groups = <int, List<Map<String, dynamic>>>{};
    for (final f in selected) {
      final priority = (f['priority'] as int?) ?? 4;
      (groups[priority] ??= []).add(f);
    }
    final sortedKeys = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    int remaining = totalDownloaded;
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
        (s, f) => s + ((f['length'] as int?) ?? 0),
      );
      if (groupSize <= 0) continue;
      if (remaining >= groupSize) {
        for (final f in group) {
          f['downloadedBytes'] = (f['length'] as int?) ?? 0;
        }
        remaining -= groupSize;
      } else {
        for (final f in group) {
          final length = (f['length'] as int?) ?? 0;
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
}

typedef ValueChangedProgress = void Function(DownloadProgress progress);

class _SpeedSample {
  final int timestampMs;
  final int bytes;
  _SpeedSample(this.timestampMs, this.bytes);
}

class _FileChangedOnServerException implements Exception {
  @override
  String toString() =>
      'FileChangedOnServerException: '
      'Server file changed during resume. Restart required.';
}

int? _applyEtaSmoothing(int? rawEta, int? prevEta) {
  if (rawEta == null) return null;
  if (prevEta != null && prevEta > 0) {
    return ((0.3 * rawEta) + (0.7 * prevEta)).round().clamp(0, 86400 * 365);
  }
  return rawEta.clamp(0, 86400 * 365);
}
