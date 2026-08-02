import 'dart:io';
import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';

enum FilterType { ads, tracking }

class _FilterSource {
  final String name;
  final String url;
  final FilterType type;

  const _FilterSource({
    required this.name,
    required this.url,
    required this.type,
  });
}

class AdBlockFilterUpdater {
  static final _log = Logger('AdBlockFilterUpdater');
  static final _lock = Lock();

  static const _sources = [
    _FilterSource(
      name: 'EasyList',
      url: 'https://easylist.to/easylist/easylist.txt',
      type: FilterType.ads,
    ),
    _FilterSource(
      name: 'EasyPrivacy',
      url: 'https://easylist.to/easylist/easyprivacy.txt',
      type: FilterType.tracking,
    ),
  ];

  static const _lastUpdateKey = 'adblock_last_update_ms';
  static const _domainsKey = 'adblock_downloaded_domains';
  static const _enabledKey = 'adblock_auto_update_enabled';
  static const _updateIntervalDays = 7;
  static const _maxDomains = 50000;
  static const _maxLineLength = 500;

  static const _patternsKey = 'adblock_url_patterns';
  static const _cosmeticKey = 'adblock_cosmetic_rules';

  bool _initialized = false;
  Set<String> _downloadedDomains = {};
  Set<String> _downloadedTrackingDomains = {};
  final Set<String> _urlPatterns = {};
  final Set<String> _cosmeticRules = {};

  Set<String> get allBlockedDomains => _downloadedDomains;
  Set<String> get allTrackingDomains => _downloadedTrackingDomains;
  int get downloadedDomainCount => _downloadedDomains.length;
  int get downloadedTrackingCount => _downloadedTrackingDomains.length;
  Set<String> get cosmeticRules => _cosmeticRules;
  Set<String> get urlPatterns => _urlPatterns;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final prefs = await SharedPreferences.getInstance();
    final cachedAds = prefs.getStringList('${_domainsKey}_ads') ?? [];
    final cachedTracking = prefs.getStringList('${_domainsKey}_tracking') ?? [];
    final cachedPatterns = prefs.getStringList(_patternsKey) ?? [];
    final cachedCosmetics = prefs.getStringList(_cosmeticKey) ?? [];

    _downloadedDomains = cachedAds.toSet();
    _downloadedTrackingDomains = cachedTracking.toSet();
    _urlPatterns.addAll(cachedPatterns);
    _cosmeticRules.addAll(cachedCosmetics);
  }

  Future<bool> updateIfNeeded({bool force = false}) async {
    return _lock.synchronized(() async {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_enabledKey) ?? true;
      if (!enabled && !force) return false;

      if (!force) {
        final lastUpdate = prefs.getInt(_lastUpdateKey) ?? 0;
        final daysSince =
            (DateTime.now().millisecondsSinceEpoch - lastUpdate) ~/
            (1000 * 60 * 60 * 24);
        if (daysSince < _updateIntervalDays) return false;
      }

      try {
        await _downloadAndParse();
        await prefs.setInt(
          _lastUpdateKey,
          DateTime.now().millisecondsSinceEpoch,
        );
        return true;
      } catch (e) {
        _log.warning('Ad-block filter update failed', e);
        return false;
      }
    });
  }

  Future<void> _downloadAndParse() async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
        headers: {'User-Agent': 'XDM/3.0 (AdBlockUpdater)'},
      ),
    );

    final tempDir = await getTemporaryDirectory();
    final newAds = <String>{};
    final newTracking = <String>{};

    for (final source in _sources) {
      try {
        final tempPath = p.join(tempDir.path, '${source.name}.txt');
        await dio.download(source.url, tempPath);

        final file = File(tempPath);
        final domains = await _parseFilterFile(file, source.type);

        if (source.type == FilterType.ads) {
          newAds.addAll(domains);
        } else {
          newTracking.addAll(domains);
        }

        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        _log.warning('Failed to download ${source.name}', e);
      }
    }

    if (newAds.isNotEmpty) {
      _downloadedDomains = newAds;
    }
    if (newTracking.isNotEmpty) {
      _downloadedTrackingDomains = newTracking;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      '${_domainsKey}_ads',
      _downloadedDomains.take(_maxDomains).toList(),
    );
    await prefs.setStringList(
      '${_domainsKey}_tracking',
      _downloadedTrackingDomains.take(_maxDomains).toList(),
    );
    await prefs.setStringList(
      _patternsKey,
      _urlPatterns.take(5000).toList(),
    );
    await prefs.setStringList(
      _cosmeticKey,
      _cosmeticRules.take(5000).toList(),
    );
  }

  Future<Set<String>> _parseFilterFile(File file, FilterType type) async {
    final domains = <String>{};
    final lines = await file.readAsLines();

    for (final line in lines) {
      if (domains.length >= _maxDomains) break;
      if (line.isEmpty || line.length > _maxLineLength) continue;

      if (line.startsWith('!') || line.startsWith('[')) continue;

      // Exception rules @@||
      if (line.startsWith('@@')) {
        final inner = line.substring(2);
        final domainMatch = RegExp(
          r'^\|\|([a-zA-Z0-9.-]+)\^',
        ).firstMatch(inner);
        if (domainMatch != null) {
          domains.remove(domainMatch.group(1)!.toLowerCase());
        }
        continue;
      }

      // Cosmetic rules: ##.ad-container, ###sidebar-ad
      if (line.contains('##')) {
        final parts = line.split('##');
        if (parts.length == 2 && parts[1].isNotEmpty && parts[1].length < 100) {
          _cosmeticRules.add(parts[1]);
        }
        continue;
      }

      final domainMatch = RegExp(
        r'^\|\|([a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9])\^',
      ).firstMatch(line);
      if (domainMatch != null) {
        final domain = domainMatch.group(1)!.toLowerCase();
        if (domain.contains('.') && !domain.startsWith('.')) {
          domains.add(domain);
        }
        continue;
      }

      // URL path patterns: /ads/banner
      if (line.startsWith('/') && !line.startsWith('//')) {
        _urlPatterns.add(line);
      }
    }

    return domains;
  }

  @visibleForTesting
  Future<Set<String>> parseFilterFile(File file, FilterType type) => _parseFilterFile(file, type);

  bool shouldBlock(String hostname) {
    if (hostname.isEmpty) return false;
    final lower = hostname.toLowerCase();
    if (_downloadedDomains.contains(lower)) return true;
    if (_downloadedTrackingDomains.contains(lower)) return true;

    final parts = lower.split('.');
    for (var i = 1; i < parts.length - 1; i++) {
      final parent = parts.sublist(i).join('.');
      if (_downloadedDomains.contains(parent)) return true;
      if (_downloadedTrackingDomains.contains(parent)) return true;
    }
    return false;
  }

  Future<DateTime?> getLastUpdateTime() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_lastUpdateKey);
    if (ms == null || ms == 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<int> getDaysUntilNextUpdate() async {
    final lastUpdate = await getLastUpdateTime();
    if (lastUpdate == null) return 0;
    final elapsed = DateTime.now().difference(lastUpdate).inDays;
    return (_updateIntervalDays - elapsed).clamp(0, _updateIntervalDays);
  }

  Future<void> setAutoUpdateEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
  }

  Future<void> clearDownloadedDomains() async {
    _downloadedDomains.clear();
    _downloadedTrackingDomains.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('${_domainsKey}_ads');
    await prefs.remove('${_domainsKey}_tracking');
    await prefs.remove(_lastUpdateKey);
  }
}
