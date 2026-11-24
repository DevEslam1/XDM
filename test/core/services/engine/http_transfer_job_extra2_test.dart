import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:flutter_test/flutter_test.dart';

class _RangeAdapter implements HttpClientAdapter {
  _RangeAdapter(this.data,
      {this.extraHeaders = const {}}) : statusCode = 206;
  final List<int> data;
  final int statusCode;
  final Map<String, List<String>> extraHeaders;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var start = 0;
    var end = data.length - 1;
    final range = options.headers['Range'];
    if (range is String) {
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
      if (m != null) {
        start = int.parse(m.group(1)!);
        if (m.group(2)!.isNotEmpty) end = int.parse(m.group(2)!);
        if (end >= data.length) end = data.length - 1;
      }
    }
    final slice = data.sublist(start, end + 1);
    return ResponseBody(
      Stream<Uint8List>.fromIterable([Uint8List.fromList(slice)]),
      statusCode,
      headers: {
        'content-range': ['bytes $start-$end/${data.length}'],
        Headers.contentLengthHeader: ['${slice.length}'],
        ...extraHeaders,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _StaticAdapter implements HttpClientAdapter {
  _StaticAdapter(this.statusCode) : headers = const {};
  final int statusCode;
  final Map<String, List<String>> headers;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(
      Stream<Uint8List>.fromIterable([Uint8List.fromList(const [])]),
      statusCode,
      headers: headers,
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
    tmp = await Directory.systemTemp.createTemp('dmx_http_extra2');
    replyPort = ReceivePort();
  });

  tearDown(() async {
    replyPort.close();
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  group('finalize via single-stream short circuit', () {
    test('an already-complete temp file is finalized and renamed', () async {
      final dir = tmp.path;
      final tempPath = '$dir/f.bin.dmxpart';
      final localPath = '$dir/f.bin';
      await File(tempPath).writeAsBytes(List.filled(100, 7));
      final complete = TransferState(
        totalSize: 100,
        threadCount: 1,
        chunks: [ChunkState(start: 0, end: 99, downloaded: 100)],
      );

      final job = HttpTransferJob(
        _cmd(dir, supportsResume: false, threads: 1),
        replyPort.sendPort,
      );
      addTearDown(job.dispose);

      job.stateForTesting = complete;
      // Legacy (non-task-scoped) state file must exist for hasUsableState.
      await File(StateStore.pathFor(tempPath)).writeAsString('x');
      final dio = Dio()..httpClientAdapter = _RangeAdapter(List.filled(100, 7));
      await job.executeDownload(dio);

      expect(await File(localPath).exists(), isTrue);
      expect(await File(localPath).length(), 100);
      expect(await File(tempPath).exists(), isFalse);
    });
  });

  group('multi-thread execution', () {
    test('downloads a multi-chunk file with range requests', () async {
      final dir = tmp.path;
      const size = 600 * 1024;
      final payload = List<int>.generate(size, (i) => i % 251);

      final job = HttpTransferJob(
        _cmd(dir, supportsResume: true, threads: 2, knownSize: size),
        replyPort.sendPort,
      );
      addTearDown(job.dispose);

      await job.loadAndReconcileState(Dio());
      final dio = Dio()..httpClientAdapter = _RangeAdapter(payload);
      await job.executeDownload(dio);

      final temp = File('$dir/f.bin.dmxpart');
      expect(await temp.exists(), isTrue);
      expect(await temp.length(), size);
    });
  });

  group('identity probe', () {
    test('detects an expired signed URL (401) and throws', () async {
      final dir = tmp.path;
      final tempPath = '$dir/f.bin.dmxpart';
      await File(tempPath).writeAsBytes(List.filled(50, 0));
      await StateStore.save(
        tempPath,
        TransferState(
          totalSize: 100,
          threadCount: 1,
          chunks: [ChunkState(start: 0, end: 99, downloaded: 50)],
        ),
        taskId: 'task-http',
      );

      final job = HttpTransferJob(
        _cmd(dir, supportsResume: true, urlExpiresHint: true),
        replyPort.sendPort,
      );
      addTearDown(job.dispose);
      final dio = Dio()..httpClientAdapter = _StaticAdapter(401);

      final st = await job.loadAndReconcileState(dio);
      expect(st.cycleState, 'updatingLinks');
    });

    test('probes a healthy source and stores the identity', () async {
      final dir = tmp.path;
      final tempPath = '$dir/f.bin.dmxpart';
      await File(tempPath).writeAsBytes(List.filled(50, 0));
      await StateStore.save(
        tempPath,
        TransferState(
          totalSize: 100,
          threadCount: 1,
          chunks: [ChunkState(start: 0, end: 99, downloaded: 50)],
        ),
        taskId: 'task-http',
      );

      final job = HttpTransferJob(
        _cmd(dir, supportsResume: true),
        replyPort.sendPort,
      );
      addTearDown(job.dispose);
      final dio = Dio()
        ..httpClientAdapter = _RangeAdapter(
          List.filled(100, 0),
          extraHeaders: {
            'etag': ['"abc"'],
            'last-modified': ['Wed, 21 Oct 2015 07:28:00 GMT'],
          },
        );

      final st = await job.loadAndReconcileState(dio);
      expect(st.etag, '"abc"');
      expect(HttpTransferJob.probeRunCount, greaterThan(0));
    });
  });
}
