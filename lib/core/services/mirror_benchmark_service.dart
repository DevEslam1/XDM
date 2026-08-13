import 'dart:async';
import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

class MirrorBenchmarkService {
  static final _log = Logger('MirrorBenchmark');
  static final Map<String, _BenchmarkResult> _results = {};
  static const _cacheTtl = Duration(hours: 1);
  static const _benchmarkBytes = 512 * 1024;
  static const _maxCacheSize = 50;

  static Future<List<MirrorBenchmarkResult>> benchmarkAll(
    List<String> urls,
  ) async {
    final results = await Future.wait(
      urls.map((url) async {
        try {
          return await _benchmarkSingle(url);
        } catch (e) {
          _log.warning('[Benchmark] Failed for $url: $e');
          return MirrorBenchmarkResult(
            url: url,
            latencyMs: 99999,
            speedBps: 0,
            success: false,
          );
        }
      }),
    );

    final ranked = List<MirrorBenchmarkResult>.of(results)
      ..sort((a, b) {
        if (a.success != b.success) return a.success ? -1 : 1;
        return a.latencyMs.compareTo(b.latencyMs);
      });
    return ranked;
  }

  static void clearCache() => _results.clear();

  static Future<MirrorBenchmarkResult> _benchmarkSingle(String url) async {
    final cached = _results[url];
    if (cached != null && !cached.isExpired) {
      return cached.toResult(url);
    }

    final stopwatch = Stopwatch()..start();
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 10),
      ),
    );
    final cancelToken = CancelToken();

    try {
      await dio.head(url, options: Options(validateStatus: (_) => true));
      final ttfb = stopwatch.elapsedMilliseconds;
      stopwatch.reset();

      final response = await dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(
          headers: {'Range': 'bytes=0-${_benchmarkBytes - 1}'},
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
        ),
      );

      int bytesReceived = 0;
      try {
        await for (final chunk in response.data!.stream) {
          bytesReceived += chunk.length;
          if (bytesReceived >= _benchmarkBytes) {
            break;
          }
        }
      } finally {
        if (!cancelToken.isCancelled) {
          cancelToken.cancel('benchmark_complete');
        }
      }

      final downloadMs = stopwatch.elapsedMilliseconds;
      final speedBps =
          downloadMs > 0 ? (bytesReceived * 1000.0 / downloadMs) : 0.0;

      final result = _BenchmarkResult(
        ttfbMs: ttfb,
        downloadMs: downloadMs,
        speedBps: speedBps,
        timestamp: DateTime.now(),
      );

      // Enforce cache size limit
      if (_results.length >= _maxCacheSize) {
        _results.remove(_results.keys.first);
      }
      _results[url] = result;

      return result.toResult(url);
    } finally {
      dio.close();
    }
  }
}

class MirrorBenchmarkResult {
  final String url;
  final int latencyMs;
  final double speedBps;
  final bool success;

  const MirrorBenchmarkResult({
    required this.url,
    required this.latencyMs,
    required this.speedBps,
    required this.success,
  });
}

class _BenchmarkResult {
  final int ttfbMs;
  final int downloadMs;
  final double speedBps;
  final DateTime timestamp;

  _BenchmarkResult({
    required this.ttfbMs,
    required this.downloadMs,
    required this.speedBps,
    required this.timestamp,
  });

  bool get isExpired =>
      DateTime.now().difference(timestamp) > MirrorBenchmarkService._cacheTtl;

  MirrorBenchmarkResult toResult(String url) => MirrorBenchmarkResult(
        url: url,
        latencyMs: ttfbMs,
        speedBps: speedBps,
        success: true,
      );
}
