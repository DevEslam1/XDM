import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

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
  DownloadEngine({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  void _configureClient({
    String? customUserAgent,
    bool enableProxy = false,
    String? proxyAddress,
    bool bypassSSL = false,
  }) {
    if (customUserAgent != null && customUserAgent.trim().isNotEmpty) {
      _dio.options.headers['User-Agent'] = customUserAgent.trim();
    } else {
      _dio.options.headers.remove('User-Agent');
    }

    final adapter = _dio.httpClientAdapter;
    if (adapter is IOHttpClientAdapter) {
      if (enableProxy && proxyAddress != null && proxyAddress.trim().isNotEmpty) {
        adapter.createHttpClient = () {
          final client = HttpClient();
          client.findProxy = (uri) {
            return 'PROXY ${proxyAddress.trim()}';
          };
          if (bypassSSL) {
            client.badCertificateCallback = (cert, host, port) => true;
          }
          return client;
        };
      } else {
        adapter.createHttpClient = null;
      }
    }
  }

  Future<DownloadMetadata> resolveMetadata({
    required String url,
    String? requestedFileName,
    String? customUserAgent,
    bool enableProxy = false,
    String? proxyAddress,
    bool bypassSSL = false,
  }) async {
    final punyUrl = convertIdnToPunycode(url);
    var fileName = requestedFileName?.trim().isNotEmpty == true
        ? safeFileName(requestedFileName!.trim())
        : fileNameFromUrl(punyUrl);
    var fileSize = 0;
    var supportsResume = false;

    _configureClient(
      customUserAgent: customUserAgent,
      enableProxy: enableProxy,
      proxyAddress: proxyAddress,
      bypassSSL: bypassSSL,
    );

    try {
      final response = await _dio.head<dynamic>(
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
    final punyUrl = convertIdnToPunycode(url);

    _configureClient(
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

      final response = await _dio.get<ResponseBody>(
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
        await sink.flush();
        await sink.close();
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

          final chunkResponse = await _dio.get<ResponseBody>(
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
            await sink.flush();
            await sink.close();
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
        await outputSink.flush();
        await outputSink.close();
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
