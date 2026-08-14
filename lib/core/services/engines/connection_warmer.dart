import 'dart:async';
import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';
import '../../../features/downloads/models/download_task.dart';
import '../power_monitor.dart';
import '../protocol_cache.dart';

/// Service managing TLS pre-warming and connection caching.
/// Task 2.1: Converted from static mutable state to injectable singleton.
class ConnectionWarmer {
  static final _log = Logger('ConnectionWarmer');
  static ConnectionWarmer? _instance;
  static ConnectionWarmer get instance => _instance ??= ConnectionWarmer();

  final Map<String, DateTime> _warmedHosts = {};
  static const _warmTtl = Duration(minutes: 5);
  static const _maxWarmedHosts = 10;
  final Lock _lock = Lock();

  ConnectionWarmer();

  Future<void> warmConnection(String url) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasAuthority) return;

      final host = uri.host;
      final shouldWarm = await _lock.synchronized(() {
        final lastWarm = _warmedHosts[host];
        if (lastWarm != null &&
            DateTime.now().difference(lastWarm) < _warmTtl) {
          return false;
        }
        if (_warmedHosts.length >= _maxWarmedHosts) {
          final oldest = _warmedHosts.entries
              .reduce((a, b) => a.value.isBefore(b.value) ? a : b);
          _warmedHosts.remove(oldest.key);
        }
        _warmedHosts[host] = DateTime.now();
        return true;
      });
      if (!shouldWarm) return;

      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 5),
      ));
      try {
        await dio.head(
          url,
          options: Options(
            receiveTimeout: const Duration(seconds: 3),
            validateStatus: (_) => true,
          ),
        );
      } finally {
        dio.close();
      }

      _log.fine('[ConnectionWarmer] Pre-warmed TLS connection to $host');
    } catch (e) {
      _log.info('[ConnectionWarmer] pre-warm skipped: $e');
    }
  }

  Future<void> warmQueuedTasks(List<DownloadTask> queuedTasks) async {
    final sortedTasks = List<DownloadTask>.from(queuedTasks);
    sortedTasks.sort((a, b) {
      final protoA = ProtocolCache.get(a.url);
      final protoB = ProtocolCache.get(b.url);
      final isH2A =
          protoA == ProtocolSupport.http2 || protoA == ProtocolSupport.http3;
      final isH2B =
          protoB == ProtocolSupport.http2 || protoB == ProtocolSupport.http3;
      if (isH2A != isH2B) {
        return isH2A ? -1 : 1;
      }
      return 0;
    });

    final maxWarmCount =
        (PowerMonitor.batteryLevel > 50 || PowerMonitor.isCharging) ? 5 : 3;
    final toWarm = sortedTasks.take(maxWarmCount);
    await Future.wait(
      toWarm.map((t) => warmConnection(t.url)),
      eagerError: false,
    );
  }

  Future<bool> isWarmed(String url) async {
    return _lock.synchronized(() {
      try {
        final host = Uri.parse(url).host;
        final lastWarm = _warmedHosts[host];
        return lastWarm != null &&
            DateTime.now().difference(lastWarm) < _warmTtl;
      } catch (e) {
        _log.info(
            '[ConnectionWarmer] URL parse skipped, returning not warmed: $e');
        return false;
      }
    });
  }

  Future<void> clear() async {
    await _lock.synchronized(() {
      _warmedHosts.clear();
    });
  }

  void dispose() {
    _warmedHosts.clear();
  }
}
