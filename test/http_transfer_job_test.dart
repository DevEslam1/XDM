import 'dart:async';
import 'dart:isolate';
import 'package:dio/dio.dart';
import 'package:dmx/core/services/engine/chunk_scheduler.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:dmx/core/services/transfer_state.dart';
import 'package:flutter_test/flutter_test.dart';

class _MockNullResponseBodyAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // Return a ResponseBody that produces a null stream in response.data?.stream or throws
    return ResponseBody(
      const Stream.empty(),
      206,
      headers: {
        'content-range': ['bytes 0-999/1000'],
        'content-length': ['1000'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _MockInterceptorThrowOnNullData extends Interceptor {
  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    // Null out data to simulate null response.data on 206
    response.data = null;
    super.onResponse(response, handler);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HttpTransferJob (FIX-1)', () {
    test(
        'asserts a 206 response with null body does NOT attempt stream read and throws DioException with message "Empty response body."',
        () async {
      final receivePort = ReceivePort();
      const cmd = DownloadCommand(
        taskId: 'test-206-null',
        url: 'https://example.com/testfile.bin',
        punyUrl: 'https://example.com/testfile.bin',
        tempFilePath: 'build/test_206_null.tmp',
        localFilePath: 'build/test_206_null.bin',
        threadCount: 1,
        knownFileSize: 1000,
        supportsResume: true,
      );

      final job = HttpTransferJob(cmd, receivePort.sendPort);
      job.stateForTesting = TransferState(
        totalSize: 1000,
        threadCount: 1,
        chunks: ChunkScheduler.singleStream(1000),
      );

      final dio = Dio();
      dio.httpClientAdapter = _MockNullResponseBodyAdapter();
      dio.interceptors.add(_MockInterceptorThrowOnNullData());

      expect(
        () => job.executeDownload(dio),
        throwsA(isA<DioException>().having(
          (e) => e.message,
          'message',
          'Empty response body.',
        )),
      );

      receivePort.close();
    });
  });
}
