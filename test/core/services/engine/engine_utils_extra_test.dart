// ignore_for_file: invalid_use_of_protected_member
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:dmx/core/services/engine/ssrf_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildTransferDio interceptors (direct invocation)', () {
    InterceptorsWrapper wrapperOf(Dio dio) =>
        dio.interceptors.whereType<InterceptorsWrapper>().first;

    test('onRequest passes an allowed literal host through', () async {
      final dio = buildTransferDio(url: 'http://8.8.8.8/f');
      final handler = RequestInterceptorHandler();
      wrapperOf(dio).onRequest(
          RequestOptions(path: 'http://8.8.8.8/f'), handler);
      await handler.future;
    });

    test('onRequest rejects a blocked metadata host', () async {
      final dio = buildTransferDio(url: 'http://169.254.169.254/f');
      final handler = RequestInterceptorHandler();
      wrapperOf(dio).onRequest(
          RequestOptions(path: 'http://169.254.169.254/f'), handler);
      await expectLater(handler.future, throwsA(anything));
    });

    test('onResponse passes a non-redirect response through', () async {
      final dio = buildTransferDio(url: 'https://example.com/f');
      final response = Response(
        requestOptions: RequestOptions(path: 'https://example.com/f'),
        statusCode: 200,
      );
      final handler = ResponseInterceptorHandler();
      wrapperOf(dio).onResponse(response, handler);
      await handler.future;
    });

    test('onResponse rejects a redirect into a private network', () async {
      final dio = buildTransferDio(url: 'https://example.com/f');
      final response = Response(
        requestOptions: RequestOptions(path: 'https://example.com/f'),
        statusCode: 200,
        redirects: [
          RedirectRecord(302, 'GET', Uri.parse('http://169.254.169.254/')),
        ],
      );
      final handler = ResponseInterceptorHandler();
      wrapperOf(dio).onResponse(response, handler);
      await expectLater(handler.future, throwsA(anything));
    });

    test('onResponse accepts a benign redirect', () async {
      final dio = buildTransferDio(url: 'https://example.com/f');
      final response = Response(
        requestOptions: RequestOptions(path: 'https://example.com/f'),
        statusCode: 200,
        redirects: [
          RedirectRecord(302, 'GET', Uri.parse('https://cdn.example.com/f')),
        ],
      );
      final handler = ResponseInterceptorHandler();
      wrapperOf(dio).onResponse(response, handler);
      await handler.future;
    });
  });

  group('actualDownloadedBytes state without totalSize', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('dmx_utils_extra');
    });
    tearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    test('uses min(stateBytes, fileLen) when totalSize is unknown', () async {
      final f = File('${dir.path}/s.dmxpart');
      await f.writeAsBytes(List.filled(50, 0));
      final state = TransferState(
        totalSize: 0,
        threadCount: 1,
        chunks: [ChunkState.indeterminate(downloaded: 5)],
      );
      await StateStore.save(f.path, state, taskId: 'task-x');
      final bytes = await actualDownloadedBytes(f.path,
          stateStore: StateStore.instance, taskId: 'task-x');
      expect(bytes, 5);
    });
  });

  group('SsrfGuard IPv6 + DNS failure handling', () {
    test('blocks a hostname resolving to unique-local IPv6', () async {
      await expectLater(
        SsrfGuard.validateAsync(
          Uri.parse('http://rebind.example.com/x'),
          lookupFn: (_) async => [InternetAddress('fd00::1')],
        ),
        throwsA(isA<SsrfBlockedException>()),
      );
    });

    test('blocks a hostname resolving to loopback IPv6 when not allowed',
        () async {
      await expectLater(
        SsrfGuard.validateAsync(
          Uri.parse('http://rebind.example.com/x'),
          lookupFn: (_) async => [InternetAddress('::1')],
        ),
        throwsA(isA<SsrfBlockedException>()),
      );
    });

    test('allows loopback IPv6 when allowPrivate is set', () async {
      await SsrfGuard.validateAsync(
        Uri.parse('http://rebind.example.com/x'),
        allowPrivate: true,
        lookupFn: (_) async => [InternetAddress('::1')],
      );
    });

    test('swallows SocketException from the resolver', () async {
      await SsrfGuard.validateAsync(
        Uri.parse('http://lookup.example.com/x'),
        lookupFn: (_) async => throw const SocketException('no dns'),
      );
    });

    test('swallows a lookup timeout', () async {
      await SsrfGuard.validateAsync(
        Uri.parse('http://slow.example.com/x'),
        lookupTimeout: const Duration(milliseconds: 5),
        lookupFn: (_) => Future.delayed(
          const Duration(milliseconds: 50),
          () => [InternetAddress('8.8.8.8')],
        ),
      );
    });

    test('swallows an unexpected resolver error', () async {
      await SsrfGuard.validateAsync(
        Uri.parse('http://weird.example.com/x'),
        lookupFn: (_) async => throw StateError('boom'),
      );
    });
  });
}
