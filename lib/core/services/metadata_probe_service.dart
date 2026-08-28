import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/dio_client_pool.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';
import 'package:dmx/core/services/torrent_service.dart';
import 'package:dmx/core/utils/bencode_decoder.dart';
import 'package:dmx/core/utils/file_utils.dart';
import 'package:dmx/core/utils/url_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Handles metadata resolution for HTTP and Torrent sources.
/// Task 1.2: Specialized Service for metadata probing.
class MetadataProbeService {
  final DioClientPool _dioPool;

  MetadataProbeService(this._dioPool);

  Future<DownloadMetadata> resolveMetadata({
    required String url,
    String? requestedFileName,
    String? customUserAgent,
    String? referer,
    String? cookies,
    String? oauthToken,
    CancelToken? cancelToken,
  }) async {
    final isTorrent = isTorrentUrl(url, fileName: requestedFileName);
    if (isTorrent) {
      return _resolveTorrentMetadata(
        url: url,
        requestedFileName: requestedFileName,
        cancelToken: cancelToken,
      );
    }

    final punyUrl = convertIdnToPunycode(url);
    final uri = Uri.tryParse(punyUrl);
    final host = uri?.host.toLowerCase() ?? '';
    final isYoutube = host.contains('youtube.com') ||
        host == 'youtu.be' ||
        host.endsWith('.googlevideo.com');

    // FIX P1-5: Use separate Dio clients for concurrent HEAD/GET probes.
    // Sharing one Dio instance causes interceptor/header races and validateStatus bleed.
    // Also cancel the ranged GET when HEAD succeeds to avoid leaked socket.
    final headClient = _dioPool.acquireClient(
      url: punyUrl,
      customUserAgent: customUserAgent,
      referer: referer,
      cookies: cookies,
      oauthToken: oauthToken,
    );
    final getClient = _dioPool.acquireClient(
      url: punyUrl,
      customUserAgent: customUserAgent,
      referer: referer,
      cookies: cookies,
      oauthToken: oauthToken,
    );
    final getProbeCancel = CancelToken();
    // Propagate outer cancellation to GET probe.
    cancelToken?.whenCancel.then((_) {
      try {
        if (!getProbeCancel.isCancelled) getProbeCancel.cancel('outer_cancel');
      } catch (_) {}
    });

    try {
      final headFuture = _probeWithHead(
        punyUrl: punyUrl,
        client: headClient,
        requestedFileName: requestedFileName,
        isYoutube: isYoutube,
        cancelToken: cancelToken,
      );
      final getFuture = _probeWithGet(
        punyUrl: punyUrl,
        client: getClient,
        requestedFileName: requestedFileName,
        isYoutube: isYoutube,
        cancelToken: getProbeCancel,
      );

      try {
        final headResult = await headFuture;
        if (headResult.isValid) {
          // Cancel the in-flight ranged GET instead of ignore() leak.
          if (!getProbeCancel.isCancelled) getProbeCancel.cancel('head_valid');
          // Drain but don't block on GET error.
          getFuture.catchError((_) => const DownloadMetadata(fileName: '', category: '', fileSize: 0, supportsResume: false));
          return headResult;
        }
        final getResult = await getFuture;
        if (getResult.isValid) return getResult;
        return headResult;
      } catch (_) {
        final getResult = await getFuture.catchError((_) => const DownloadMetadata(fileName: '', category: '', fileSize: 0, supportsResume: false));
        if (getResult.isValid) return getResult;
        rethrow;
      }
    } finally {
      if (!getProbeCancel.isCancelled) {
        try { getProbeCancel.cancel('cleanup'); } catch (_) {}
      }
      _dioPool.releaseClient(headClient);
      _dioPool.releaseClient(getClient);
    }
  }

  Future<DownloadMetadata> _probeWithHead({
    required String punyUrl,
    required Dio client,
    String? requestedFileName,
    required bool isYoutube,
    CancelToken? cancelToken,
  }) async {
    var fileName = requestedFileName?.trim().isNotEmpty == true
        ? safeFileName(requestedFileName!.trim())
        : fileNameFromUrl(punyUrl);
    var fileSize = 0;
    var supportsResume = isYoutube;
    String? etag;
    String? lastModified;

    try {
      final response = await client.head<dynamic>(
        punyUrl,
        cancelToken: cancelToken,
        options: Options(followRedirects: true, validateStatus: (_) => true),
      );
      final headerName = fileNameFromContentDisposition(response.headers);
      if (requestedFileName?.trim().isNotEmpty != true && headerName != null) {
        fileName = headerName;
      }
      etag = response.headers.value('etag');
      lastModified = response.headers.value('last-modified');
      fileSize = int.tryParse(
              response.headers.value(Headers.contentLengthHeader) ?? '') ??
          0;
      final acceptRanges =
          response.headers.value('accept-ranges')?.toLowerCase();
      supportsResume = acceptRanges != null
          ? acceptRanges == 'bytes'
          : (isYoutube || response.statusCode == 206);

      if (_isLikelyHtmlResponse(
              response.headers.value(Headers.contentTypeHeader)) &&
          fileSize < 1024 * 1024) {
        fileSize = 0;
      }
      if (response.statusCode != null && response.statusCode! >= 400) {
        if (![400, 403, 405].contains(response.statusCode)) {
          fileSize = 0;
        }
      }
    } catch (e) {
      debugPrint('HEAD request failed for $punyUrl: $e');
    }

    return DownloadMetadata(
      fileName: fileName,
      category: categoryFromFileName(fileName),
      fileSize: fileSize,
      supportsResume: supportsResume,
      etag: etag,
      lastModified: lastModified,
    );
  }

  Future<DownloadMetadata> _probeWithGet({
    required String punyUrl,
    required Dio client,
    String? requestedFileName,
    required bool isYoutube,
    CancelToken? cancelToken,
  }) async {
    var fileName = requestedFileName?.trim().isNotEmpty == true
        ? safeFileName(requestedFileName!.trim())
        : fileNameFromUrl(punyUrl);
    var fileSize = 0;
    var supportsResume = isYoutube;
    String? etag;
    String? lastModified;

    try {
      final getResponse = await client.get<ResponseBody>(
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
        final getHeaderName =
            fileNameFromContentDisposition(getResponse.headers);
        if (requestedFileName?.trim().isNotEmpty != true &&
            getHeaderName != null) {
          fileName = getHeaderName;
        }
        etag = getResponse.headers.value('etag');
        lastModified = getResponse.headers.value('last-modified');
        final contentRange = getResponse.headers.value('content-range');
        if (contentRange != null) {
          final totalMatch = RegExp(r'/(\d+)').firstMatch(contentRange);
          fileSize = int.tryParse(totalMatch?.group(1) ?? '') ?? fileSize;
        }
        if (fileSize == 0) {
          fileSize = int.tryParse(
                  getResponse.headers.value(Headers.contentLengthHeader) ??
                      '') ??
              0;
        }
        if (_isLikelyHtmlResponse(
                getResponse.headers.value(Headers.contentTypeHeader)) &&
            fileSize < 1024 * 1024) {
          fileSize = 0;
        }
        supportsResume = isYoutube ||
            getResponse.statusCode == 206 ||
            getResponse.headers.value('accept-ranges') == 'bytes';
        await getResponse.data?.stream.listen((_) {}).cancel();
      }
    } catch (e) {
      debugPrint('[MetadataProbeService] ranged GET probe failed: $e');
    }

    return DownloadMetadata(
      fileName: fileName,
      category: categoryFromFileName(fileName),
      fileSize: fileSize,
      supportsResume: supportsResume,
      etag: etag,
      lastModified: lastModified,
    );
  }

  bool _isLikelyHtmlResponse(String? contentType) {
    final normalized = (contentType ?? '').toLowerCase();
    return normalized.contains('text/html') ||
        normalized.contains('application/xhtml');
  }

  Future<DownloadMetadata> _resolveTorrentMetadata({
    required String url,
    String? requestedFileName,
    CancelToken? cancelToken,
  }) async {
    if (url.startsWith('magnet:')) {
      final magnetParams = parseMagnetUrl(url);
      final resolvedName = requestedFileName?.trim().isNotEmpty == true
          ? safeFileName(requestedFileName!.trim())
          : ((magnetParams['name'])?.trim().isNotEmpty == true
              ? safeFileName((magnetParams['name'] as String).trim())
              : 'torrent_download.zip');

      if (!TorrentService.isSupported) {
        return DownloadMetadata(
          fileName: resolvedName,
          category: 'Archive',
          fileSize: 0,
          supportsResume: true,
        );
      }

      // FIX: [Audit] Prevent double metadata fetch by checking TorrentResumeStore cache first
      final cachedFiles = await TorrentResumeStore.loadFilesForSource(url);
      if (cachedFiles != null && cachedFiles.isNotEmpty) {
        final totalSize = cachedFiles.fold<int>(
            0, (sum, f) => sum + ((f['length'] as int?) ?? 0));
        return DownloadMetadata(
          fileName: resolvedName,
          category: categoryFromFileName(resolvedName),
          fileSize: totalSize,
          supportsResume: true,
          torrentFiles: cachedFiles,
          torrentId: null,
        );
      }

      try {
        await TorrentService.ready.timeout(const Duration(seconds: 10));
      } catch (e, st) {
        LoggingService.logger('MetadataProbeService').warning(
            'TorrentService ready wait failed during probe: $e', e, st);
        return DownloadMetadata(
          fileName: resolvedName,
          category: 'Archive',
          fileSize: 0,
          supportsResume: true,
        );
      }

      final tempDir = (await getTemporaryDirectory()).path;
      final torrentId = TorrentService.addMagnet(url, tempDir);
      if (torrentId < 0) {
        return DownloadMetadata(
          fileName: resolvedName,
          category: 'Archive',
          fileSize: 0,
          supportsResume: true,
        );
      }

      TorrentService.boostMagnetDiscovery(torrentId);
      TorrentService.resumeTorrent(torrentId);
      TorrentResumeStore.registerSource(torrentId, url);

      // Check if metadata is already available in cache
      final initialStats = TorrentService.latestStats[torrentId];
      if (initialStats != null && initialStats.hasMetadata) {
        final files = TorrentService.getFiles(torrentId);
        final resolvedFiles = files
            .map((f) => {
                  'name': f.name,
                  'length': f.size,
                  'selected': true,
                  'priority': 4,
                  'downloadedBytes': 0,
                })
            .toList();

        final totalSize =
            resolvedFiles.fold<int>(0, (sum, f) => sum + (f['length'] as int));

        final resolvedTitle =
            initialStats.name.isNotEmpty ? initialStats.name : resolvedName;

        // FIX: [Audit] Cache resolved metadata to prevent double metadata fetch.
        // A snapshot with no usable lengths is not metadata — persisting it
        // would later overwrite real lengths with zeros, so skip the cache.
        if (totalSize > 0) {
          await TorrentResumeStore.saveMetadataSnapshot(
            sourceUrl: url,
            files: resolvedFiles,
            name: resolvedTitle,
          );
        }

        try {
          TorrentService.pauseTorrent(torrentId);
          TorrentService.removeTorrent(torrentId, deleteFiles: false);
        } catch (_) {}

        // FIX: [Audit] Do not return dead torrentId of removed handle
        return DownloadMetadata(
          fileName: resolvedTitle,
          category: categoryFromFileName(resolvedTitle),
          fileSize: totalSize,
          supportsResume: true,
          torrentFiles: resolvedFiles,
          torrentId: null,
        );
      }

      final completer = Completer<DownloadMetadata>();
      StreamSubscription? sub;
      Timer? metadataTimer;
      bool cleanedUp = false;

      void cleanup() {
        if (cleanedUp) return;
        cleanedUp = true;
        sub?.cancel();
        metadataTimer?.cancel();
        if (torrentId >= 0) {
          try {
            TorrentService.pauseTorrent(torrentId);
            TorrentService.removeTorrent(torrentId, deleteFiles: false);
          } catch (e, st) {
            LoggingService.logger('MetadataProbeService')
                .warning('Operation failed', e, st);
          }
        }
      }

      cancelToken?.whenCancel.then((_) {
        cleanup();
        if (!completer.isCompleted) {
          completer.completeError(DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.cancel,
            message: 'Metadata resolution cancelled',
          ));
        }
      });

      sub = TorrentService.torrentUpdates.listen((torrents) {
        final torrent = torrents[torrentId];
        if (torrent != null && torrent.hasMetadata && !completer.isCompleted) {
          final files = TorrentService.getFiles(torrentId);
          final resolvedFiles = files
              .map((f) => {
                    'name': f.name,
                    'length': f.size,
                    'selected': true,
                    'priority': 4,
                    'downloadedBytes': 0,
                  })
              .toList();

          final totalSize = resolvedFiles.fold<int>(
              0, (sum, f) => sum + (f['length'] as int));

          // FIX: [Audit] Cache resolved metadata before cleanup. Skip the cache
          // when no length could be resolved (see above).
          if (totalSize > 0) {
            TorrentResumeStore.saveMetadataSnapshot(
              sourceUrl: url,
              files: resolvedFiles,
              name: torrent.name,
            );
          }

          cleanup();
          // FIX: [Audit] Return torrentId: null since torrent was cleanly removed
          completer.complete(DownloadMetadata(
            fileName: torrent.name,
            category: categoryFromFileName(torrent.name),
            fileSize: totalSize,
            supportsResume: true,
            torrentFiles: resolvedFiles,
            torrentId: null,
          ));
        }
      });

      metadataTimer = Timer(const Duration(seconds: 300), () {
        if (completer.isCompleted) return;
        cleanup();
        completer.complete(DownloadMetadata(
          fileName: resolvedName,
          category: 'Archive',
          fileSize: 0,
          supportsResume: true,
        ));
      });

      return completer.future;
    }

    // Handle .torrent file (local or remote HTTP/HTTPS)
    var fileName = requestedFileName?.trim().isNotEmpty == true
        ? safeFileName(requestedFileName!.trim())
        : 'torrent_download.zip';
    var fileSize = 0;
    List<Map<String, dynamic>>? torrentFiles;

    Uint8List? torrentBytes;
    if (url.startsWith('file://')) {
      final file = File(Uri.parse(url).toFilePath());
      if (await file.exists()) {
        torrentBytes = await file.readAsBytes();
      }
    } else if (url.startsWith('http://') || url.startsWith('https://')) {
      try {
        final client = _dioPool.acquireClient(url: url);
        try {
          final response = await client.get<List<int>>(
            url,
            options: Options(responseType: ResponseType.bytes),
            cancelToken: cancelToken,
          );
          if (response.data != null && response.data!.isNotEmpty) {
            torrentBytes = Uint8List.fromList(response.data!);
          }
        } finally {
          _dioPool.releaseClient(client);
        }
      } catch (e) {
        debugPrint(
            '[MetadataProbeService] Failed to fetch remote .torrent: $e');
      }
    } else {
      final file = File(url);
      if (await file.exists()) {
        torrentBytes = await file.readAsBytes();
      }
    }

    if (torrentBytes != null && torrentBytes.isNotEmpty) {
      final meta =
          await compute(BencodeDecoder.parseTorrentBytes, torrentBytes);
      if (meta != null) {
        fileName = meta['name'] ?? fileName;
        torrentFiles = (meta['files'] as List? ?? []).map((f) {
          final map = f as Map;
          return {
            'name': map['name'] as String? ?? '',
            'length': map['length'] as int? ?? 0,
            'selected': true,
            'priority': 4,
          };
        }).toList();
        fileSize = meta['length'] ??
            torrentFiles.fold<int>(
                0, (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0));
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
