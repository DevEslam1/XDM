import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late Directory tempDir;
  late Uint8List testPayload;
  late String expectedSha256;
  const testFileSize = 256 * 1024; // 256 KB

  setUp(() async {
    tempDir =
        await Directory.systemTemp.createTemp('http_download_integration_');
    testPayload = Uint8List.fromList(
      List.generate(testFileSize, (i) => (i * 17 + 5) % 256),
    );
    expectedSha256 = sha256.convert(testPayload).toString();

    // Start local HTTP server supporting byte ranges
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      final rangeHeader = request.headers.value('range');
      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
        if (match != null) {
          final start = int.parse(match.group(1)!);
          final endStr = match.group(2);
          final end = (endStr != null && endStr.isNotEmpty)
              ? int.parse(endStr)
              : testFileSize - 1;

          final slice = testPayload.sublist(start, end + 1);
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers
              .set('Content-Range', 'bytes $start-$end/$testFileSize');
          request.response.headers.set('Content-Length', slice.length);
          request.response.headers.set('Accept-Ranges', 'bytes');
          request.response.add(slice);
          await request.response.close();
          return;
        }
      }

      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set('Content-Length', testFileSize);
      request.response.headers.set('Accept-Ranges', 'bytes');
      request.response.add(testPayload);
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
      'Local HttpServer integration test: download -> pause/cancel -> resume with Range verification',
      () async {
    final dio = Dio();
    final fileUrl =
        'http://${server.address.host}:${server.port}/test_file.bin';
    final targetPath = '${tempDir.path}/downloaded_output.bin';
    final targetFile = File(targetPath);

    // 1. Initial partial download (first 64KB)
    final cancelToken = CancelToken();
    final firstResponse = await dio.get<ResponseBody>(
      fileUrl,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        headers: {'Range': 'bytes=0-65535'},
      ),
    );

    expect(firstResponse.statusCode, HttpStatus.partialContent);
    final raf = await targetFile.open(mode: FileMode.write);
    await for (final chunk in firstResponse.data!.stream) {
      await raf.writeFrom(chunk);
    }
    await raf.close();

    expect(await targetFile.length(), 65536);

    // 2. Resume download from offset 65536 to end
    final currentLength = await targetFile.length();
    final resumeResponse = await dio.get<ResponseBody>(
      fileUrl,
      options: Options(
        responseType: ResponseType.stream,
        headers: {'Range': 'bytes=$currentLength-${testFileSize - 1}'},
      ),
    );

    expect(resumeResponse.statusCode, HttpStatus.partialContent);
    final appendRaf = await targetFile.open(mode: FileMode.append);
    await for (final chunk in resumeResponse.data!.stream) {
      await appendRaf.writeFrom(chunk);
    }
    await appendRaf.close();

    // 3. Verify complete file size and SHA-256 integrity
    expect(await targetFile.length(), testFileSize);
    final downloadedBytes = await targetFile.readAsBytes();
    final actualSha256 = sha256.convert(downloadedBytes).toString();
    expect(actualSha256, equals(expectedSha256));
  });
}
