import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../utils/bencode_decoder.dart';
import '../utils/file_utils.dart';
import '../utils/url_utils.dart';

class DownloadMetadata {
  final String fileName;
  final String category;
  final int fileSize;
  final bool supportsResume;

  const DownloadMetadata({
    required this.fileName,
    required this.category,
    required this.fileSize,
    required this.supportsResume,
  });
}

class DownloadProgress {
  final int downloadedBytes;
  final int fileSize;
  final double speed;
  final int? eta;
  final List<double>? chunks;

  const DownloadProgress({
    required this.downloadedBytes,
    required this.fileSize,
    required this.speed,
    required this.eta,
    this.chunks,
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
      if (enableProxy && proxyAddress != null && proxyAddress.trim().isNotEmpty) {
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
    final isTorrent = url.trim().startsWith('magnet:') ||
        url.trim().toLowerCase().endsWith('.torrent') ||
        (requestedFileName != null && requestedFileName.toLowerCase().endsWith('.torrent'));

    if (isTorrent) {
      var fileName = requestedFileName?.trim().isNotEmpty == true
          ? safeFileName(requestedFileName!.trim())
          : 'torrent_download.zip';
      var fileSize = 100 * 1024 * 1024; // Default 100MB

      if (url.startsWith('magnet:')) {
        final parsed = parseMagnetUrl(url);
        if (parsed.containsKey('name')) {
          fileName = parsed['name']!;
        } else if (parsed.containsKey('infoHash')) {
          fileName = 'magnet_${parsed['infoHash']!.substring(0, 8)}.zip';
        }
      } else if (url.startsWith('file://')) {
        final filePath = Uri.parse(url).toFilePath();
        final file = File(filePath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final meta = BencodeDecoder.parseTorrentBytes(bytes);
          if (meta != null) {
            fileName = meta['name'] ?? fileName;
            fileSize = meta['length'] ?? fileSize;
          }
        }
      }

      return DownloadMetadata(
        fileName: fileName,
        category: 'Archive',
        fileSize: fileSize,
        supportsResume: true,
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
      debugPrint('DownloadEngine HEAD request failed (this is expected for some servers): $e');
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
  }) async {
    final isTorrent = url.trim().startsWith('magnet:') ||
        url.trim().startsWith('file://') ||
        url.trim().toLowerCase().endsWith('.torrent') ||
        fileNameFromUrl(url).trim().toLowerCase().endsWith('.torrent');

    if (isTorrent) {
      // NOTE: This is a simulated torrent download. A real BitTorrent
      // engine (e.g. libtorrent) would be needed for actual P2P transfers.
      final localFile = File(localFilePath);
      await localFile.parent.create(recursive: true);

      final totalSize = knownFileSize > 0 ? knownFileSize : 100 * 1024 * 1024;
      var downloaded = 0;
      final stopwatch = Stopwatch()..start();
      final chunks = List<double>.filled(threadCount, 0.0);

      while (downloaded < totalSize) {
        if (cancelToken.isCancelled) {
          throw DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.cancel,
            error: 'paused',
          );
        }

        await Future.delayed(const Duration(milliseconds: 200));

        final limit = speedLimitBytesPerSecond();
        var tickMaxBytes = totalSize ~/ 50; // Complete in ~10 seconds default
        if (limit > 0) {
          tickMaxBytes = (limit * 0.2).round(); // limit * 200ms
        }

        if (tickMaxBytes <= 0) tickMaxBytes = 1024;

        final bytesAdded = min(tickMaxBytes, totalSize - downloaded);
        downloaded += bytesAdded;

        final progressRatio = downloaded / totalSize;
        for (int i = 0; i < threadCount; i++) {
          final target = (i + 1) / threadCount;
          if (progressRatio >= target) {
            chunks[i] = 1.0;
          } else {
            final start = i / threadCount;
            chunks[i] = ((progressRatio - start) * threadCount).clamp(0.0, 1.0);
          }
        }

        final elapsedSecs = stopwatch.elapsedMicroseconds / 1000000.0;
        final speed = elapsedSecs > 0 ? downloaded / elapsedSecs : 0.0;
        final remainingBytes = totalSize - downloaded;
        final eta = speed > 0 ? (remainingBytes / speed).round() : 0;

        onProgress(DownloadProgress(
          downloadedBytes: downloaded,
          fileSize: totalSize,
          speed: speed,
          eta: eta,
          chunks: chunks,
        ));
      }

      // Write a placeholder file with torrent info
      final placeholderContent = StringBuffer()
        ..writeln('XDM Torrent Placeholder')
        ..writeln('========================')
        ..writeln('Source: $url')
        ..writeln('Expected size: $knownFileSize bytes')
        ..writeln('')
        ..writeln('Note: Real BitTorrent downloading requires a native')
        ..writeln('torrent engine integration (e.g. libtorrent).')
        ..writeln('This file is a placeholder for the torrent download.');
      await localFile.writeAsString(placeholderContent.toString());
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

    final isMultiThread = threadCount > 1 && supportsResume && knownFileSize > 0;

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
          while (speedSamples.isNotEmpty && nowMs - speedSamples.first.timestampMs > 3000) {
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
        final end = (i == threadCount - 1) ? (totalSize - 1) : (start + partSize - 1);
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
        while (speedSamples.isNotEmpty && nowMs - speedSamples.first.timestampMs > 3000) {
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

        final remaining = totalSize > downloadedTotal ? totalSize - downloadedTotal : 0;
        final eta = speed > 0 && remaining > 0 ? (remaining / speed).round() : null;

        // Construct actual chunk percentages
        final chunksList = List<double>.generate(threadCount, (idx) {
          return chunkSizes[idx] > 0 ? (chunkProgress[idx] / chunkSizes[idx]).clamp(0.0, 1.0) : 1.0;
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
        final end = (idx == threadCount - 1) ? (totalSize - 1) : (start + partSize - 1);
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
                final expectedElapsedMs = (downloadedThisSession / perTaskLimit * 1000).round();
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
