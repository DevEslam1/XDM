import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/engine/engine_exceptions.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:dmx/core/services/transfer_state.dart';
import 'package:flutter_test/flutter_test.dart';

class _StatusAdapter implements HttpClientAdapter {
  _StatusAdapter(
    this.statusCode, {
    this.body = const [],
    this.headers = const {},
  });
  final int statusCode;
  final List<int> body;
  final Map<String, List<String>> headers;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(
      Stream<Uint8List>.fromIterable([Uint8List.fromList(body)]),
      statusCode,
      headers: {
        Headers.contentLengthHeader: ['${body.length}'],
        ...headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

DownloadCommand _cmd(
  String dir, {
  bool supportsResume = true,
  int threads = 1,
  int knownSize = 100,
  bool urlExpiresHint = false,
}) =>
    DownloadCommand(
      taskId: 'task-http',
      url: 'http://example.com/f.bin',
      punyUrl: 'http://example.com/f.bin',
      tempFilePath: '$dir/f.bin.dmxpart',
      localFilePath: '$dir/f.bin',
      knownFileSize: knownSize,
      supportsResume: supportsResume,
      threadCount: threads,
      urlExpiresHint: urlExpiresHint,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late ReceivePort replyPort;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dmx_http_extra3');
    replyPort = ReceivePort();
  });

  tearDown(() async {
    replyPort.close();
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  HttpTransferJob jobFor(DownloadCommand cmd, TransferState st) {
    final job = HttpTransferJob(cmd, replyPort.sendPort);
    addTearDown(job.dispose);
    job.stateForTesting = st;
    return job;
  }

  TransferState fresh(int totalSize, {int threads = 1}) => TransferState(
        totalSize: totalSize,
        threadCount: threads,
        chunks: [ChunkState(start: 0, end: totalSize - 1)],
      );

  group('single-stream error paths', () {
    test('401 on a signed URL raises UrlExpiredException', () async {
      final job = jobFor(
        _cmd(tmp.path, urlExpiresHint: true),
        fresh(100),
      );
      final dio = Dio()..httpClientAdapter = _StatusAdapter(401);
      await expectLater(
          job.executeDownload(dio), throwsA(isA<UrlExpiredException>()));
    });

    test('a 200 response to a resume request restarts from zero', () async {
      final dir = tmp.path;
      await File('$dir/f.bin.dmxpart').writeAsBytes(List.filled(50, 1));
      final st = TransferState(
        totalSize: 100,
        threadCount: 1,
        chunks: [ChunkState(start: 0, end: 99, downloaded: 50)],
      );
      final job = jobFor(_cmd(dir, supportsResume: true), st);
      final dio = Dio()
        ..httpClientAdapter = _StatusAdapter(200, body: List.filled(100, 2));

      await job.executeDownload(dio);
      expect(await File('$dir/f.bin.dmxpart').length(), 100);
    });

    test('a repeated 416 exhausts attempts and fails', () async {
      final job = jobFor(_cmd(tmp.path, supportsResume: true), fresh(100));
      final dio = Dio()
        ..httpClientAdapter = _StatusAdapter(
          416,
          headers: {
            'content-range': ['bytes */100']
          },
        );
      await expectLater(
          job.executeDownload(dio), throwsA(isA<DownloadIntegrityException>()));
    });

    test('an HTML body is rejected', () async {
      final job = jobFor(_cmd(tmp.path, supportsResume: false), fresh(100));
      final dio = Dio()
        ..httpClientAdapter = _StatusAdapter(
          200,
          body: '<html></html>'.codeUnits,
          headers: {
            'content-type': ['text/html']
          },
        );
      await expectLater(job.executeDownload(dio), throwsA(isA<DioException>()));
    });

    test('a 404 fails without retrying', () async {
      final job = jobFor(_cmd(tmp.path, supportsResume: false), fresh(100));
      final dio = Dio()..httpClientAdapter = _StatusAdapter(404);
      await expectLater(job.executeDownload(dio), throwsA(isA<DioException>()));
    });

    test('a persistent 500 exhausts retries and fails', () async {
      final job = jobFor(_cmd(tmp.path, supportsResume: false), fresh(100));
      final dio = Dio()..httpClientAdapter = _StatusAdapter(500);
      await expectLater(job.executeDownload(dio), throwsA(isA<DioException>()));
    });
  });
}
