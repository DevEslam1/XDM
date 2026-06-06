import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'torrent_service.dart';

import '../utils/bencode_decoder.dart';
import '../utils/file_utils.dart';
import '../utils/url_utils.dart';

class DownloadMetadata {
  final String fileName;
  final String category;
  final int fileSize;
  final bool supportsResume;
  final List<Map<String, dynamic>>? torrentFiles;

  const DownloadMetadata({
    required this.fileName,
    required this.category,
    required this.fileSize,
    required this.supportsResume,
    this.torrentFiles,
  });
}

class DownloadProgress {
  final int downloadedBytes;
  final int fileSize;
  final double speed;
  final int? eta;
  final List<double>? chunks;
  final String? fileName;
  final List<Map<String, dynamic>>? torrentFiles;

  const DownloadProgress({
    required this.downloadedBytes,
    required this.fileSize,
    required this.speed,
    required this.eta,
    this.chunks,
    this.fileName,
    this.torrentFiles,
  });
}

class DownloadEngine {
  DownloadEngine({Dio? dio}) : _sharedDio = dio ?? Dio();

  // Kept around for tests/extensions that may need it, but the engine
  // no longer mutates this client; every request builds its own.
  // ignore: unused_field
  final Dio _sharedDio;

  /// Builds an isolated Dio instance configured with per-call options.
  /// Using a fresh client per request prevents the shared [_dio] instance
  /// from being mutated by concurrent downloads (which previously caused
  /// one in-flight download to silently pick up another download's
  /// proxy/UA/SSL settings).
  Dio _buildIsolatedClient({
    String? customUserAgent,
    bool enableProxy = false,
    String? proxyAddress,
    bool bypassSSL = false,
  }) {
    final client = Dio();
    if (customUserAgent != null && customUserAgent.trim().isNotEmpty) {
      client.options.headers['User-Agent'] = customUserAgent.trim();
    }

    final adapter = client.httpClientAdapter;
    if (adapter is IOHttpClientAdapter) {
      if (enableProxy &&
          proxyAddress != null &&
          proxyAddress.trim().isNotEmpty) {
        adapter.createHttpClient = () {
          final httpClient = HttpClient();
          httpClient.findProxy = (uri) {
            return 'PROXY ${proxyAddress.trim()}';
          };
          if (bypassSSL) {
            httpClient.badCertificateCallback = (cert, host, port) => true;
          }
          return httpClient;
        };
      }
    }
    return client;
  }

  Future<DownloadMetadata> resolveMetadata({
    required String url,
    String? requestedFileName,
    String? customUserAgent,
    bool enableProxy = false,
    String? proxyAddress,
    bool bypassSSL = false,
  }) async {
    final isTorrent =
        url.trim().startsWith('magnet:') ||
        url.trim().toLowerCase().endsWith('.torrent') ||
        (requestedFileName != null &&
            requestedFileName.toLowerCase().endsWith('.torrent'));

    if (isTorrent) {
      var fileName = requestedFileName?.trim().isNotEmpty == true
          ? safeFileName(requestedFileName!.trim())
          : 'torrent_download.zip';
      var fileSize = 100 * 1024 * 1024; // Default 100MB
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
                    'downloadedBytes': 0,
                    'speed': 0.0,
                  },
                )
                .toList();

            final totalSize = resolvedFiles.fold(
              0,
              (sum, f) => sum + (f['length'] as int),
            );

            TorrentService.removeTorrent(torrentId);

            if (!completer.isCompleted) {
              completer.complete(
                DownloadMetadata(
                  fileName: torrent.name,
                  category: 'Archive',
                  fileSize: totalSize,
                  supportsResume: true,
                  torrentFiles: resolvedFiles,
                ),
              );
            }
          }
        });

        // Timeout of 30 seconds -> Fallback to placeholder/magnet name instead of failing
        Future.delayed(const Duration(seconds: 30), () {
          if (!completer.isCompleted) {
            sub?.cancel();
            TorrentService.removeTorrent(torrentId);
            completer.complete(
              DownloadMetadata(
                fileName: resolvedName,
                category: 'Archive',
                fileSize: 0,
                supportsResume: true,
                torrentFiles: null,
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
          final meta = BencodeDecoder.parseTorrentBytes(bytes);
          if (meta != null) {
            fileName = meta['name'] ?? fileName;
            fileSize = meta['length'] ?? fileSize;
            torrentFiles = (meta['files'] as List? ?? [])
                .map(
                  (f) => {
                    'name': f['name'] as String? ?? '',
                    'length': f['length'] as int? ?? 0,
                    'selected': true,
                    'downloadedBytes': 0,
                    'speed': 0.0,
                  },
                )
                .toList();
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
    var supportsResume = false;

    // Use a per-call Dio so concurrent downloads don't share UA/proxy/SSL
    // state via the engine's long-lived client.
    final isolatedDio = _buildIsolatedClient(
      customUserAgent: customUserAgent,
      enableProxy: enableProxy,
      proxyAddress: proxyAddress,
      bypassSSL: bypassSSL,
    );

    try {
      final response = await isolatedDio.head<dynamic>(
        punyUrl,
        options: Options(
          followRedirects: true,
          validateStatus: (status) => status != null && status < 500,
        ),
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
      supportsResume = acceptRanges == 'bytes';
    } catch (e) {
      // Some servers block HEAD; GET will still attempt the download.
      debugPrint(
        'DownloadEngine HEAD request failed (this is expected for some servers): $e',
      );
    }

    return DownloadMetadata(
      fileName: fileName,
      category: categoryFromFileName(fileName),
      fileSize: fileSize,
      supportsResume: supportsResume,
    );
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
    bool enableProxy = false,
    String? proxyAddress,
    bool bypassSSL = false,
    List<Map<String, dynamic>>? torrentFiles,
    int? torrentId,
  }) async {
    final isTorrent =
        url.trim().startsWith('magnet:') ||
        url.trim().startsWith('file://') ||
        url.trim().toLowerCase().endsWith('.torrent') ||
        fileNameFromUrl(url).trim().toLowerCase().endsWith('.torrent');

    if (isTorrent) {
      int id = torrentId ?? -1;
      if (id == -1) {
        final saveDir = File(localFilePath).parent.path;
        if (url.startsWith('magnet:')) {
          id = TorrentService.addMagnet(url, saveDir);
        } else {
          String filePath = url;
          if (url.startsWith('file://')) {
            filePath = Uri.parse(url).toFilePath();
          }
          id = TorrentService.addTorrentFile(filePath, saveDir);
        }
      }

      // Wait for metadata to resolve
      final metadataCompleter = Completer<void>();
      StreamSubscription? metadataSub;

      metadataSub = TorrentService.torrentUpdates.listen((torrents) {
        final torrent = torrents[id];
        if (torrent != null && torrent.hasMetadata) {
          metadataSub?.cancel();
          if (!metadataCompleter.isCompleted) {
            metadataCompleter.complete();
          }
        }
      });

      // Handle cancel during metadata loading
      cancelToken.whenCancel.then((_) {
        metadataSub?.cancel();
        TorrentService.pauseTorrent(id);
        if (!metadataCompleter.isCompleted) {
          metadataCompleter.completeError(
            DioException(
              requestOptions: RequestOptions(path: url),
              type: DioExceptionType.cancel,
              error: 'paused',
            ),
          );
        }
      });

      await metadataCompleter.future;

      // Set file priorities after metadata is loaded
      if (torrentFiles != null && torrentFiles.isNotEmpty) {
        final priorities = torrentFiles
            .map((f) => (f['selected'] as bool? ?? true) ? 1 : 0)
            .toList();
        TorrentService.setFilePriorities(id, priorities);
      }

      // Resume download
      TorrentService.resumeTorrent(id);

      final downloadCompleter = Completer<void>();
      StreamSubscription? downloadSub;

      downloadSub = TorrentService.torrentUpdates.listen((torrents) {
        final torrent = torrents[id];
        if (torrent == null) return;

        final progress = torrent.progress; // double from 0.0 to 1.0
        final stateLabel = torrent.stateLabel.toLowerCase();

        final totalSize = torrent.totalWanted > 0
            ? torrent.totalWanted
            : (knownFileSize > 0 ? knownFileSize : 0);
        final downloadedBytes = torrent.totalDone;
        final speed = torrent.downloadRate.toDouble();

        final remaining = totalSize - downloadedBytes;
        final eta = speed > 0 && remaining > 0
            ? (remaining / speed).round()
            : 0;

        List<Map<String, dynamic>>? resolvedFiles;
        String? resolvedName;
        if (torrent.hasMetadata) {
          resolvedName = torrent.name;
          try {
            final files = TorrentService.getFiles(id);
            resolvedFiles = files
                .map(
                  (f) => {
                    'name': f.name,
                    'length': f.size,
                    'selected': true,
                    'downloadedBytes': 0,
                    'speed': 0.0,
                  },
                )
                .toList();
          } catch (_) {}
        }

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

        // Finish if progress is complete or it's seeding/completed
        if (progress >= 1.0 ||
            stateLabel == 'seeding' ||
            stateLabel == 'completed' ||
            stateLabel == 'finished') {
          downloadSub?.cancel();
          if (!downloadCompleter.isCompleted) {
            downloadCompleter.complete();
          }
        }
      });

      cancelToken.whenCancel.then((_) {
        downloadSub?.cancel();
        TorrentService.pauseTorrent(id);
        if (!downloadCompleter.isCompleted) {
          downloadCompleter.completeError(
            DioException(
              requestOptions: RequestOptions(path: url),
              type: DioExceptionType.cancel,
              error: 'paused',
            ),
          );
        }
      });

      await downloadCompleter.future;
      return;
    }

    final punyUrl = convertIdnToPunycode(url);

    // Use a per-call Dio so concurrent downloads don't share UA/proxy/SSL
    // state via the engine's long-lived client.
    final isolatedDio = _buildIsolatedClient(
      customUserAgent: customUserAgent,
      enableProxy: enableProxy,
      proxyAddress: proxyAddress,
      bypassSSL: bypassSSL,
    );

    final isMultiThread =
        threadCount > 1 && supportsResume && knownFileSize > 0;

    if (!isMultiThread) {
      final tempFile = File(tempFilePath);
      await tempFile.parent.create(recursive: true);

      var resumeFrom = 0;
      if (supportsResume && await tempFile.exists()) {
        resumeFrom = await tempFile.length();
      } else if (await tempFile.exists()) {
        await tempFile.delete();
      }

      final headers = <String, dynamic>{};
      if (resumeFrom > 0) {
        headers['range'] = 'bytes=$resumeFrom-';
      }

      final response = await isolatedDio.get<ResponseBody>(
        punyUrl,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          headers: headers,
        ),
      );

      var totalSize = knownFileSize;
      final contentLength =
          int.tryParse(
            response.headers.value(Headers.contentLengthHeader) ?? '',
          ) ??
          0;
      if (totalSize <= 0 && contentLength > 0) {
        totalSize = resumeFrom + contentLength;
      }

      final sink = tempFile.openWrite(
        mode: resumeFrom > 0 ? FileMode.append : FileMode.write,
      );
      final stopwatch = Stopwatch()..start();
      var downloadedThisSession = 0;
      var downloadedTotal = resumeFrom;
      final speedSamples = <_SpeedSample>[];

      try {
        await for (final chunk in response.data!.stream) {
          if (cancelToken.isCancelled) {
            throw DioException(
              requestOptions: RequestOptions(path: punyUrl),
              type: DioExceptionType.cancel,
              message: 'Download cancelled.',
            );
          }
          sink.add(chunk);
          downloadedThisSession += chunk.length;
          downloadedTotal += chunk.length;

          final nowMs = stopwatch.elapsedMilliseconds;
          speedSamples.add(_SpeedSample(nowMs, downloadedTotal));

          // Keep samples from the last 3 seconds (3000 ms)
          while (speedSamples.isNotEmpty &&
              nowMs - speedSamples.first.timestampMs > 3000) {
            speedSamples.removeAt(0);
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
          final eta = speed > 0 && remaining > 0
              ? (remaining / speed).round()
              : null;

          onProgress(
            DownloadProgress(
              downloadedBytes: downloadedTotal,
              fileSize: totalSize,
              speed: speed,
              eta: eta,
            ),
          );

          final limit = speedLimitBytesPerSecond();
          if (limit > 0) {
            final activeCount = activeDownloadCount().clamp(1, 1000);
            final perTaskLimit = limit / activeCount;
            final expectedElapsedMs =
                (downloadedThisSession / perTaskLimit * 1000).round();
            final actualElapsedMs = stopwatch.elapsedMilliseconds;
            if (expectedElapsedMs > actualElapsedMs) {
              await Future<void>.delayed(
                Duration(milliseconds: expectedElapsedMs - actualElapsedMs),
              );
            }
          }
        }
      } finally {
        // Closing the sink can throw on Windows if the underlying handle
        // was already invalidated by the cancellation path. Swallow it
        // so the real error reaches the caller.
        try {
          await sink.flush();
        } catch (_) {}
        try {
          await sink.close();
        } catch (_) {}
      }

      await File(localFilePath).parent.create(recursive: true);
      if (await File(localFilePath).exists()) {
        await File(localFilePath).delete();
      }
      try {
        await tempFile.rename(localFilePath);
      } catch (_) {
        // Fallback for cross-device/cross-filesystem move
        await tempFile.copy(localFilePath);
        await tempFile.delete();
      }
    } else {
      // Real Multi-Thread segment downloading
      final futures = <Future<void>>[];
      final chunkProgress = List<int>.filled(threadCount, 0);
      final chunkSizes = List<int>.filled(threadCount, 0);
      final chunkFiles = List<File>.filled(threadCount, File(''));

      final totalSize = knownFileSize;
      final partSize = (totalSize / threadCount).floor();

      // Calculate start/end boundaries and part files
      for (int i = 0; i < threadCount; i++) {
        final start = i * partSize;
        final end = (i == threadCount - 1)
            ? (totalSize - 1)
            : (start + partSize - 1);
        final size = end - start + 1;
        chunkSizes[i] = size;
        chunkFiles[i] = File('$tempFilePath.part$i');
        await chunkFiles[i].parent.create(recursive: true);
      }

      // Initialize chunk progress from existing files
      for (int i = 0; i < threadCount; i++) {
        if (await chunkFiles[i].exists()) {
          chunkProgress[i] = await chunkFiles[i].length();
        }
      }

      final stopwatch = Stopwatch()..start();
      var downloadedThisSession = 0;
      final speedSamples = <_SpeedSample>[];

      void reportProgress() {
        final downloadedTotal = chunkProgress.reduce((a, b) => a + b);
        final nowMs = stopwatch.elapsedMilliseconds;
        speedSamples.add(_SpeedSample(nowMs, downloadedTotal));

        // Keep samples from the last 3 seconds (3000 ms)
        while (speedSamples.isNotEmpty &&
            nowMs - speedSamples.first.timestampMs > 3000) {
          speedSamples.removeAt(0);
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
        final eta = speed > 0 && remaining > 0
            ? (remaining / speed).round()
            : null;

        // Construct actual chunk percentages
        final chunksList = List<double>.generate(threadCount, (idx) {
          return chunkSizes[idx] > 0
              ? (chunkProgress[idx] / chunkSizes[idx]).clamp(0.0, 1.0)
              : 1.0;
        });

        onProgress(
          DownloadProgress(
            downloadedBytes: downloadedTotal,
            fileSize: totalSize,
            speed: speed,
            eta: eta,
            chunks: chunksList,
          ),
        );
      }

      for (int i = 0; i < threadCount; i++) {
        final idx = i;
        final start = idx * partSize;
        final end = (idx == threadCount - 1)
            ? (totalSize - 1)
            : (start + partSize - 1);
        final file = chunkFiles[idx];

        futures.add(() async {
          final resumeFrom = chunkProgress[idx];
          if (resumeFrom >= chunkSizes[idx]) {
            // Already finished this chunk
            return;
          }

          final headers = <String, dynamic>{};
          headers['range'] = 'bytes=${start + resumeFrom}-$end';

          final chunkResponse = await isolatedDio.get<ResponseBody>(
            punyUrl,
            cancelToken: cancelToken,
            options: Options(
              responseType: ResponseType.stream,
              followRedirects: true,
              headers: headers,
            ),
          );

          final sink = file.openWrite(
            mode: resumeFrom > 0 ? FileMode.append : FileMode.write,
          );

          try {
            await for (final chunk in chunkResponse.data!.stream) {
              if (cancelToken.isCancelled) {
                throw DioException(
                  requestOptions: RequestOptions(path: punyUrl),
                  type: DioExceptionType.cancel,
                  message: 'Download cancelled.',
                );
              }
              sink.add(chunk);
              chunkProgress[idx] += chunk.length;
              downloadedThisSession += chunk.length;

              reportProgress();

              final limit = speedLimitBytesPerSecond();
              if (limit > 0) {
                final activeCount = activeDownloadCount().clamp(1, 1000);
                final perTaskLimit = limit / activeCount;
                final expectedElapsedMs =
                    (downloadedThisSession / perTaskLimit * 1000).round();
                final actualElapsedMs = stopwatch.elapsedMilliseconds;
                if (expectedElapsedMs > actualElapsedMs) {
                  await Future<void>.delayed(
                    Duration(milliseconds: expectedElapsedMs - actualElapsedMs),
                  );
                }
              }
            }
          } finally {
            try {
              await sink.flush();
            } catch (_) {}
            try {
              await sink.close();
            } catch (_) {}
          }
        }());
      }

      // Wait for all threads to complete
      await Future.wait(futures);

      // Merge chunk files into localFilePath
      final localFile = File(localFilePath);
      await localFile.parent.create(recursive: true);
      if (await localFile.exists()) {
        await localFile.delete();
      }

      final outputSink = localFile.openWrite();
      try {
        for (int i = 0; i < threadCount; i++) {
          final partFile = chunkFiles[i];
          if (await partFile.exists()) {
            final partStream = partFile.openRead();
            await for (final data in partStream) {
              outputSink.add(data);
            }
            await partFile.delete();
          }
        }
      } finally {
        try {
          await outputSink.flush();
        } catch (_) {}
        try {
          await outputSink.close();
        } catch (_) {}
      }
    }
  }

  String buildLocalFilePath(String directory, String fileName) {
    return p.join(directory, safeFileName(fileName));
  }

  String buildTempFilePath(String directory, String fileName) {
    return p.join(directory, '${safeFileName(fileName)}.dmxpart');
  }
}

typedef ValueChangedProgress = void Function(DownloadProgress progress);

class _SpeedSample {
  final int timestampMs;
  final int bytes;
  _SpeedSample(this.timestampMs, this.bytes);
}
