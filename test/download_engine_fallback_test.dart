import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DownloadEngine fallback to single-thread on 416 range error', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final url = 'http://localhost:$port/testfile.bin';

    server.listen((HttpRequest request) async {
      final response = request.response;
      if (request.method == 'HEAD') {
        response.headers.set('accept-ranges', 'bytes');
        response.headers.set('content-length', '100');
        response.statusCode = HttpStatus.ok;
        await response.close();
      } else if (request.method == 'GET') {
        final range = request.headers.value('range');
        if (range != null && range.startsWith('bytes=')) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          await response.close();
        } else {
          response.statusCode = HttpStatus.ok;
          response.headers.set('content-length', '100');
          response.add(List<int>.generate(100, (i) => i));
          await response.close();
        }
      }
    });

    final engine = DownloadEngine(enableCleanupTimer: false);
    final tempFile = File('build/test_fallback.tmp');
    final localFile = File('build/test_fallback.bin');
    if (tempFile.existsSync()) tempFile.deleteSync();
    if (localFile.existsSync()) localFile.deleteSync();

    final progress = <DownloadProgress>[];
    await engine.download(
      url: url,
      tempFilePath: tempFile.path,
      localFilePath: localFile.path,
      knownFileSize: 100,
      supportsResume: true,
      cancelToken: CancelToken(),
      onProgress: (p) => progress.add(p),
      speedLimitBytesPerSecond: () => 0,
      activeDownloadCount: () => 1,
      threadCount: 4,
    );

    expect(localFile.existsSync(), isTrue);
    expect(localFile.lengthSync(), 100);
    expect(progress.last.downloadedBytes, 100);
    
    await server.close();
    if (tempFile.existsSync()) tempFile.deleteSync();
    if (localFile.existsSync()) localFile.deleteSync();
  });

  test('DownloadEngine throws badResponse exception on non-2xx status code', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final url = 'http://localhost:$port/errorfile.bin';

    server.listen((HttpRequest request) async {
      final response = request.response;
      response.statusCode = HttpStatus.notFound;
      await response.close();
    });

    final engine = DownloadEngine(enableCleanupTimer: false);
    final tempFile = File('build/test_error.tmp');
    final localFile = File('build/test_error.bin');
    if (tempFile.existsSync()) tempFile.deleteSync();
    if (localFile.existsSync()) localFile.deleteSync();

    try {
      await engine.download(
        url: url,
        tempFilePath: tempFile.path,
        localFilePath: localFile.path,
        knownFileSize: 100,
        supportsResume: false,
        cancelToken: CancelToken(),
        onProgress: (_) {},
        speedLimitBytesPerSecond: () => 0,
        activeDownloadCount: () => 1,
        threadCount: 1,
      );
      fail('Expected DownloadEngine to throw DioException');
    } catch (e) {
      expect(e, isA<DioException>());
      expect((e as DioException).type, equals(DioExceptionType.badResponse));
    } finally {
      await server.close();
      if (tempFile.existsSync()) tempFile.deleteSync();
      if (localFile.existsSync()) localFile.deleteSync();
    }
  });
}
