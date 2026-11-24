import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/dio_client_pool.dart';
import 'package:dmx/core/services/metadata_probe_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

class _FakePool extends DioClientPool {
  _FakePool(this.adapter);

  final HttpClientAdapter adapter;

  @override
  Dio acquireClient({
    String? url,
    String? customUserAgent,
    String? referer,
    String? cookies,
    String? oauthToken,
  }) {
    final dio = Dio(BaseOptions(validateStatus: (_) => true));
    dio.httpClientAdapter = adapter;
    return dio;
  }

  @override
  void releaseClient(Dio client) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MetadataProbeService.dispose', () {
    test('dispose is idempotent and flips isDisposed', () {
      final service = MetadataProbeService(DioClientPool());
      expect(service.isDisposed, isFalse);
      service.dispose();
      expect(service.isDisposed, isTrue);
      service.dispose();
    });
  });

  group('MetadataProbeService HTTP probing', () {
    test('HEAD metadata wins and reports size/etag/resume', () async {
      final pool = _FakePool(_FakeAdapter((options) async {
        if (options.method == 'HEAD') {
          return ResponseBody.fromString('', 200, headers: {
            Headers.contentLengthHeader: ['1024'],
            'accept-ranges': ['bytes'],
            'etag': ['"abc"'],
            'last-modified': ['Mon, 01 Jan 2026 00:00:00 GMT'],
            Headers.contentTypeHeader: ['application/octet-stream'],
          });
        }
        return ResponseBody(
          Stream.value(Uint8List.fromList([0])),
          206,
          headers: {
            'content-range': ['bytes 0-0/1024'],
            'accept-ranges': ['bytes'],
          },
        );
      }));

      final service = MetadataProbeService(pool);
      final meta = await service.resolveMetadata(
        url: 'https://example.com/file.bin',
      );

      expect(meta.fileName, 'file.bin');
      expect(meta.fileSize, 1024);
      expect(meta.supportsResume, isTrue);
      expect(meta.etag, '"abc"');
      expect(meta.lastModified, 'Mon, 01 Jan 2026 00:00:00 GMT');
      service.dispose();
    });

    test('HTML content smaller than 1MB is treated as size zero', () async {
      final pool = _FakePool(_FakeAdapter((options) async {
        return ResponseBody.fromString('', 200, headers: {
          Headers.contentLengthHeader: ['500'],
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        });
      }));

      final service = MetadataProbeService(pool);
      final meta = await service.resolveMetadata(
        url: 'https://example.com/index.html',
        requestedFileName: 'setup.exe',
      );

      expect(meta.fileName, 'setup.exe');
      expect(meta.fileSize, 0);
      expect(meta.supportsResume, isFalse);
      service.dispose();
    });

    test('HEAD failure falls back to ranged GET metadata', () async {
      final pool = _FakePool(_FakeAdapter((options) async {
        if (options.method == 'HEAD') {
          throw const SocketException('head failed');
        }
        return ResponseBody(
          Stream.value(Uint8List.fromList([0])),
          206,
          headers: {
            'content-range': ['bytes 0-0/2048'],
            'accept-ranges': ['bytes'],
          },
        );
      }));

      final service = MetadataProbeService(pool);
      final meta = await service.resolveMetadata(
        url: 'https://example.com/video.bin',
      );

      expect(meta.fileName, 'video.bin');
      expect(meta.fileSize, 2048);
      expect(meta.supportsResume, isTrue);
      service.dispose();
    });

    test('HEAD and GET failures yield filename-only metadata', () async {
      final pool = _FakePool(_FakeAdapter((options) async {
        throw const SocketException('network failed');
      }));

      final service = MetadataProbeService(pool);
      final meta = await service.resolveMetadata(
        url: 'https://example.com/setup.exe',
      );

      expect(meta.fileName, 'setup.exe');
      expect(meta.fileSize, 0);
      expect(meta.supportsResume, isFalse);
      service.dispose();
    });

    test('HTTP error status resets the probed size', () async {
      final pool = _FakePool(_FakeAdapter((options) async {
        return ResponseBody.fromString('not found', 404, headers: {
          Headers.contentLengthHeader: ['10'],
        });
      }));

      final service = MetadataProbeService(pool);
      final meta = await service.resolveMetadata(
        url: 'https://example.com/missing.bin',
      );
      expect(meta.fileSize, 0);
      service.dispose();
    });
  });

  group('MetadataProbeService torrent probing', () {
    test('parses a local .torrent file', () async {
      final dir = await Directory.systemTemp.createTemp('dmx_torrent_probe_');
      try {
        final file = File('${dir.path}/test.torrent');
        await file.writeAsBytes(
          utf8.encode('d4:infod4:name4:test6:lengthi100eee'),
        );

        final service = MetadataProbeService(DioClientPool());
        final meta = await service.resolveMetadata(url: file.uri.toString());

        expect(meta.category, 'Torrent');
        expect(meta.fileName, 'test');
        expect(meta.fileSize, 100);
        expect(meta.torrentFiles, isNotEmpty);
        service.dispose();
      } finally {
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
    });

    test('missing local .torrent yields an empty torrent metadata', () async {
      final service = MetadataProbeService(DioClientPool());
      final meta = await service.resolveMetadata(
        url: 'file:///nonexistent/dmx/nope.torrent',
      );
      expect(meta.category, 'Torrent');
      expect(meta.fileSize, 0);
      service.dispose();
    });

    test('fetches and parses a remote .torrent over the pooled client',
        () async {
      final pool = _FakePool(_FakeAdapter((options) async {
        return ResponseBody.fromBytes(
          utf8.encode('d4:infod4:name6:remote6:lengthi55eee'),
          200,
        );
      }));

      final service = MetadataProbeService(pool);
      final meta = await service.resolveMetadata(
        url: 'https://example.com/remote.torrent',
      );
      expect(meta.category, 'Torrent');
      expect(meta.fileName, 'remote');
      expect(meta.fileSize, 55);
      service.dispose();
    });

    test('a failing remote .torrent fetch degrades gracefully', () async {
      final pool = _FakePool(_FakeAdapter((options) async {
        throw const SocketException('torrent fetch failed');
      }));

      final service = MetadataProbeService(pool);
      final meta = await service.resolveMetadata(
        url: 'https://example.com/broken.torrent',
      );
      expect(meta.category, 'Torrent');
      expect(meta.fileSize, 0);
      service.dispose();
    });

    test('a bare filesystem .torrent path that does not exist is handled',
        () async {
      final service = MetadataProbeService(DioClientPool());
      final meta = await service.resolveMetadata(
        url: 'C:\\nonexistent\\dmx\\local.torrent',
      );
      expect(meta.category, 'Torrent');
      expect(meta.fileSize, 0);
      service.dispose();
    });
  });
}
