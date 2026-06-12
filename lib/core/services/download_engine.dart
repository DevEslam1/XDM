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
  final bool? supportsResume;

  const DownloadProgress({
    required this.downloadedBytes,
    required this.fileSize,
    required this.speed,
    required this.eta,
    this.chunks,
    this.fileName,
    this.torrentFiles,
    this.supportsResume,
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
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
    bool bypassSSL = false,
  }) {
    final client = Dio();
    if (customUserAgent != null && customUserAgent.trim().isNotEmpty) {
      client.options.headers['User-Agent'] = customUserAgent.trim();
    }

    final adapter = client.httpClientAdapter;
    if (adapter is IOHttpClientAdapter) {
      if (enableProxy) {
        final String host = (proxyHost != null && proxyHost.trim().isNotEmpty)
            ? proxyHost.trim()
            : (proxyAddress != null && proxyAddress.contains(':') ? proxyAddress.split(':')[0].trim() : proxyAddress?.trim() ?? '');
        final int port = (proxyPort != null && proxyPort > 0)
            ? proxyPort
            : (proxyAddress != null && proxyAddress.contains(':') ? int.tryParse(proxyAddress.split(':')[1]) ?? 8080 : 8080);

        if (host.isNotEmpty) {
          adapter.createHttpClient = () {
            final httpClient = HttpClient();
            httpClient.findProxy = (uri) {
              return 'PROXY $host:$port';
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
            if (bypassSSL) {
              httpClient.badCertificateCallback = (cert, host, port) => true;
            }
            return httpClient;
          };
        }
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
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
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
      proxyHost: proxyHost,
      proxyPort: proxyPort,
      proxyUsername: proxyUsername,
      proxyPassword: proxyPassword,
      bypassSSL: bypassSSL,
    );

    try {
      final response = await isolatedDio.head<dynamic>(
        punyUrl,
        options: Options(
          followRedirects: true,
          validateStatus: (status) => status != null && status >= 200 && status < 400,
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
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
    bool bypassSSL = false,
    List<Map<String, dynamic>>? torrentFiles,
    int? torrentId,
    bool isNameAutoGenerated = false,
  }) async {
    int resolvedFileSize = knownFileSize;
    bool resolvedSupportsResume = supportsResume;
    String? resolvedFileName;
    String currentTempFilePath = tempFilePath;
    String currentLocalFilePath = localFilePath;

    final isTorrent =
        url.trim().startsWith('magnet:') ||
        url.trim().startsWith('file://') ||
        url.trim().toLowerCase().endsWith('.torrent') ||
        fileNameFromUrl(url).trim().toLowerCase().endsWith('.torrent');

    if (!isTorrent && resolvedFileSize == 0 && isNameAutoGenerated) {
      try {
        final meta = await resolveMetadata(
          url: url,
          customUserAgent: customUserAgent,
          enableProxy: enableProxy,
          proxyAddress: proxyAddress,
          proxyHost: proxyHost,
          proxyPort: proxyPort,
          proxyUsername: proxyUsername,
          proxyPassword: proxyPassword,
          bypassSSL: bypassSSL,
        );
        resolvedFileSize = meta.fileSize;
        resolvedSupportsResume = meta.supportsResume;
        resolvedFileName = meta.fileName;
      } catch (_) {}

      if (resolvedFileName != null) {
        final saveDir = File(localFilePath).parent.path;
        currentLocalFilePath = p.join(saveDir, safeFileName(resolvedFileName));
        currentTempFilePath = p.join(saveDir, '${safeFileName(resolvedFileName)}.dmxpart');
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

        // Finish if progress is complete or it's seeding/completed.
        // We ignore progress >= 1.0 if the torrent is in a checking, allocating, or metadata fetching state.
        final isCheckingOrMetadata = stateLabel.contains('checking') ||
            stateLabel.contains('metadata') ||
            stateLabel.contains('allocating');

        if ((progress >= 1.0 && !isCheckingOrMetadata) ||
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
      proxyHost: proxyHost,
      proxyPort: proxyPort,
      proxyUsername: proxyUsername,
      proxyPassword: proxyPassword,
      bypassSSL: bypassSSL,
    );

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
      // Real Multi-Thread segment downloading
      final futures = <Future<void>>[];
      final chunkProgress = List<int>.filled(threadCount, 0);
      final chunkSizes = List<int>.filled(threadCount, 0);
      final chunkFiles = List<File>.filled(threadCount, File(''));

      final totalSize = resolvedFileSize;
      final partSize = (totalSize / threadCount).floor();

      // Calculate start/end boundaries and part files
      for (int i = 0; i < threadCount; i++) {
        final start = i * partSize;
        final end = (i == threadCount - 1)
            ? (totalSize - 1)
            : (start + partSize - 1);
        final size = end - start + 1;
        chunkSizes[i] = size;
        chunkFiles[i] = File('$currentTempFilePath.part$i');
        await chunkFiles[i].parent.create(recursive: true);
      }

      // Initialize chunk progress from existing files and validate chunk file size
      for (int i = 0; i < threadCount; i++) {
        if (await chunkFiles[i].exists()) {
          final fileLen = await chunkFiles[i].length();
          if (fileLen > chunkSizes[i]) {
            await chunkFiles[i].delete();
            chunkProgress[i] = 0;
          } else {
            chunkProgress[i] = fileLen;
          }
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

      try {
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

            if (chunkResponse.statusCode != 206) {
              throw DioException(
                requestOptions: RequestOptions(path: punyUrl),
                type: DioExceptionType.badResponse,
                response: chunkResponse,
                message: 'Server returned ${chunkResponse.statusCode} instead of 206 for chunk range request.',
              );
            }

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
        final localFile = File(currentLocalFilePath);
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

        if (totalSize > 0) {
          final actualSize = await localFile.length();
          if (actualSize != totalSize) {
            throw Exception(
              'Download integrity check failed: expected $totalSize bytes, got $actualSize bytes.',
            );
          }
        }
      } catch (e) {
        if (e is DioException && e.type == DioExceptionType.cancel) {
          rethrow;
        }
        // Fallback on range failure or range reject
        debugPrint('Multi-threaded range request failed: $e. Falling back to single-threaded download.');
        // Clean up part files
        for (int i = 0; i < threadCount; i++) {
          final partFile = chunkFiles[i];
          if (await partFile.exists()) {
            try {
              await partFile.delete();
            } catch (_) {}
          }
        }
        // Fallback to single-threaded stream download
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
      resumeFrom = await tempFile.length();
    } else if (await tempFile.exists()) {
      await tempFile.delete();
    }

    final headers = <String, dynamic>{};
    if (resumeFrom > 0) {
      headers['range'] = 'bytes=$resumeFrom-';
    }

    var response = await isolatedDio.get<ResponseBody>(
      punyUrl,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: true,
        headers: headers,
        validateStatus: (status) => status != null && (status < 400 || status == 416),
      ),
    );

    var actualResumeFrom = resumeFrom;

    if (response.statusCode == 416) {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      actualResumeFrom = 0;
      headers.remove('range');
      response = await isolatedDio.get<ResponseBody>(
        punyUrl,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          headers: headers,
        ),
      );
    }

    final isPartialResponse = response.statusCode == 206;
    if (actualResumeFrom > 0 && !isPartialResponse) {
      // Server returned 200 instead of 206 — restart from scratch
      actualResumeFrom = 0;
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }

    final acceptRanges = response.headers.value('accept-ranges')?.toLowerCase();
    final serverSupportsResume = isPartialResponse || (acceptRanges == 'bytes');
    final responseName = fileNameFromContentDisposition(response.headers);
    final finalUrlName = responseName ?? fileNameFromUrl(response.realUri.toString());

    var totalSize = knownFileSize;
    final contentLength =
        int.tryParse(
          response.headers.value(Headers.contentLengthHeader) ?? '',
        ) ??
        0;
    if (contentLength > 0) {
      final actualSize = (isPartialResponse ? actualResumeFrom : 0) + contentLength;
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
            supportsResume: serverSupportsResume,
            fileName: finalUrlName,
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
      try {
        await sink.flush();
      } catch (_) {}
      try {
        await sink.close();
      } catch (_) {}
    }

    if (totalSize > 0) {
      final actualSize = await tempFile.length();
      if (actualSize != totalSize) {
        throw Exception(
          'Download integrity check failed: expected $totalSize bytes, got $actualSize bytes.',
        );
      }
    }

    final saveDir = File(localFilePath).parent.path;
    final finalLocalFilePath = isNameAutoGenerated
        ? p.join(saveDir, safeFileName(finalUrlName))
        : localFilePath;

    await File(finalLocalFilePath).parent.create(recursive: true);
    if (await File(finalLocalFilePath).exists()) {
      await File(finalLocalFilePath).delete();
    }
    try {
      await tempFile.rename(finalLocalFilePath);
    } catch (_) {
      // Fallback for cross-device/cross-filesystem move
      await tempFile.copy(finalLocalFilePath);
      final copiedLen = await File(finalLocalFilePath).length();
      final origLen = await tempFile.length();
      if (copiedLen == origLen) {
        await tempFile.delete();
      } else {
        throw Exception('File copy failed on fallback rename.');
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
