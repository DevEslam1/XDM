import 'package:dmx/core/services/logging_service.dart';
import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/dio_client_pool.dart';
import 'package:dmx/core/services/torrent_service.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';
import 'package:dmx/core/utils/url_utils.dart';
import 'package:dmx/core/utils/file_utils.dart';
import 'package:dmx/core/utils/bencode_decoder.dart';
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

    final isolatedDio = _dioPool.acquireClient(
      url: punyUrl,
      customUserAgent: customUserAgent,
      referer: referer,
      cookies: cookies,
      oauthToken: oauthToken,
    );

    try {
      final headFuture = _probeWithHead(
        punyUrl: punyUrl,
        client: isolatedDio,
        requestedFileName: requestedFileName,
        isYoutube: isYoutube,
        cancelToken: cancelToken,
      );
      final getFuture = _probeWithGet(
        punyUrl: punyUrl,
        client: isolatedDio,
        requestedFileName: requestedFileName,
        isYoutube: isYoutube,
        cancelToken: cancelToken,
      );

      try {
        final headResult = await headFuture;
        if (headResult.isValid) {
          getFuture.ignore();
          return headResult;
        }
        final getResult = await getFuture;
        if (getResult.isValid) return getResult;
        return headResult;
      } catch (_) {
        final getResult = await getFuture;
        if (getResult.isValid) return getResult;
        rethrow;
      }
    } finally {
      _dioPool.releaseClient(isolatedDio);
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
      
      if (_isLikelyHtmlResponse(response.headers.value(Headers.contentTypeHeader)) && fileSize < 1024 * 1024) {
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
        if (_isLikelyHtmlResponse(getResponse.headers.value(Headers.contentTypeHeader)) && fileSize < 1024 * 1024) {
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

      final tempDir = (await getTemporaryDirectory()).path;
      final torrentId = TorrentService.addMagnet(url, tempDir);
      TorrentService.resumeTorrent(torrentId);
      TorrentResumeStore.registerSource(torrentId, url);
      
      final completer = Completer<DownloadMetadata>();
      StreamSubscription? sub;
      Timer? metadataTimer;
      bool cleanedUp = false;

      void cleanup() {
        if (cleanedUp) return;
        cleanedUp = true;
        sub?.cancel();
        metadataTimer?.cancel();
        try {
          TorrentService.pauseTorrent(torrentId);
          TorrentService.removeTorrent(torrentId, deleteFiles: false);
        } catch (e, st) {
      LoggingService.logger('MetadataProbeService').warning('Operation failed', e, st);
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
          final resolvedFiles = files.map((f) => {
            'name': f.name,
            'length': f.size,
            'selected': true,
            'priority': 4,
            'downloadedBytes': 0,
          }).toList();
          
          final totalSize = resolvedFiles.fold<int>(0, (sum, f) => sum + (f['length'] as int));
          
          cleanup();
          completer.complete(DownloadMetadata(
            fileName: torrent.name,
            category: categoryFromFileName(torrent.name),
            fileSize: totalSize,
            supportsResume: true,
            torrentFiles: resolvedFiles,
            torrentId: torrentId,
          ));
        }
      });

      metadataTimer = Timer(const Duration(seconds: 300), () {
        if (completer.isCompleted) return;
        cleanup();
        completer.complete(DownloadMetadata(
          fileName: resolvedName,
          category: 'Torrent',
          fileSize: 0,
          supportsResume: true,
        ));
      });

      return completer.future;
    }

    // Handle local .torrent file
    var fileName = requestedFileName?.trim().isNotEmpty == true
        ? safeFileName(requestedFileName!.trim())
        : 'torrent_download.zip';
    var fileSize = 0;
    List<Map<String, dynamic>>? torrentFiles;

    if (url.startsWith('file://')) {
      final file = File(Uri.parse(url).toFilePath());
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final meta = await compute(BencodeDecoder.parseTorrentBytes, bytes);
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
          fileSize = meta['length'] ?? torrentFiles.fold<int>(0, (s, f) => s + (f['length'] as int));
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
