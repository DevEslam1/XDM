import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class MagnetCacheService {
  static final _log = Logger('MagnetCacheService');
  static const _cacheDir = 'magnet_cache';
  static String? _basePath;
  static const _ttl = Duration(days: 30);

  static Future<void> init([String? overridePath]) async {
    if (overridePath != null) {
      _basePath = overridePath;
    } else {
      try {
        final appDir = await getApplicationSupportDirectory();
        _basePath = p.join(appDir.path, _cacheDir);
      } catch (e) {
        _log.info(
          '[MagnetCacheService] app support dir unavailable, falling back to system temp: $e',
        );
        _basePath = p.join(Directory.systemTemp.path, _cacheDir);
      }
    }
    final dir = Directory(_basePath!);
    if (!await dir.exists()) await dir.create(recursive: true);
  }

  static Future<void> cacheMetadata(
    String infoHash,
    Map<String, dynamic> metadata, {
    List<String>? trackers,
  }) async {
    if (_basePath == null) await init();
    final file = File(p.join(_basePath!, '$infoHash.json'));
    final data = {
      'hash': infoHash,
      'cachedAt': DateTime.now().millisecondsSinceEpoch,
      'metadata': metadata,
      if (trackers != null) 'trackers': trackers,
    };
    await file.writeAsString(jsonEncode(data));
    _log.fine('[MagnetCache] Cached metadata for infoHash: $infoHash');
  }

  static Future<Map<String, dynamic>?> getCachedMetadata(
      String infoHash) async {
    if (_basePath == null) await init();
    final file = File(p.join(_basePath!, '$infoHash.json'));
    if (!await file.exists()) return null;

    try {
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final cachedAt = data['cachedAt'] as int;
      final age = DateTime.now().millisecondsSinceEpoch - cachedAt;

      if (age > _ttl.inMilliseconds) {
        await file.delete();
        return null;
      }

      final metadata = Map<String, dynamic>.from(
          data['metadata'] as Map<String, dynamic>? ?? {});
      if (data.containsKey('trackers')) {
        metadata['trackers'] = data['trackers'];
      }
      return metadata;
    } catch (e) {
      _log.warning('[MagnetCache] Failed to read cache for $infoHash: $e');
      return null;
    }
  }

  static Future<void> clearCache() async {
    if (_basePath == null) await init();
    final dir = Directory(_basePath!);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }
  }
}
