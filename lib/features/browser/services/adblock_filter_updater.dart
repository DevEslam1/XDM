import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
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
    _FilterSource(
      name: 'EasyList-AntiAdblock',
      url: 'https://easylist-downloads.adblockplus.org/antiadblockfilters.txt',
      type: FilterType.ads,
    ),
    _FilterSource(
      name: 'PeterLowe',
      url:
          'https://pgl.yoyo.org/adservers/serverlist.php?hostformat=nohtml&showintro=0&startdate%5Bday%5D=&startdate%5Bmonth%5D=&startdate%5Byear%5D=&mimetype=plaintext',
      type: FilterType.ads,
    ),
    _FilterSource(
      name: 'AdGuardDNS',
      url: 'https://raw.githubusercontent.com/AdguardTeam/AdguardFilters/master/Filters/adguard_dns_filter.txt',
      type: FilterType.ads,
    ),
  ];

  static const _lastUpdateKey = 'adblock_last_update_ms';
  static const _domainsKey = 'adblock_downloaded_domains';
  static const _enabledKey = 'adblock_auto_update_enabled';
  static const _updateIntervalDays = 7;
  static const _maxDomains = 50000;
  static const _maxLineLength = 500;

  static const _patternsKey = 'adblock_url_patterns';
  static const _cosmeticKey = 'adblock_cosmetic_rules_v2';
  static const _siteCosmeticKey = 'adblock_site_cosmetic_rules_v2';
  static const _scriptletsKey = 'adblock_scriptlet_rules';

  bool _initialized = false;
  Set<String> _downloadedDomains = {};
  Set<String> _downloadedTrackingDomains = {};
  final Set<String> _urlPatterns = {};
  final Set<String> _cosmeticRules = {};
  final Map<String, Set<String>> _siteCosmeticRules = {};
  final Set<String> _scriptletRules = {};

  // PERF (TASK 4): LRU cache for cosmeticRulesForHost.
  // Keyed by lowercase host; evicts the oldest entry when capacity is reached.
  // Invalidated whenever _cosmeticRules or _siteCosmeticRules is mutated
  // (i.e., after a filter download/update).
  static const _kCosmeticCacheMax = 50;
  final LinkedHashMap<String, Set<String>> _cosmeticCache =
      LinkedHashMap<String, Set<String>>();

  void _invalidateCosmeticCache() => _cosmeticCache.clear();

  Set<String> _allowListedDomains = {};
  Completer<bool>? _inFlightUpdate;
  double regressionThreshold = 0.50;

  Set<String> get allBlockedDomains => _downloadedDomains;
  Set<String> get allTrackingDomains => _downloadedTrackingDomains;
  Set<String> get allowListedDomains => _allowListedDomains;
  int get downloadedDomainCount => _downloadedDomains.length;
  int get downloadedTrackingCount => _downloadedTrackingDomains.length;
  Set<String> get cosmeticRules => _cosmeticRules;
  Set<String> get urlPatterns => _urlPatterns;
  Set<String> get scriptletRules => _scriptletRules;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final prefs = await SharedPreferences.getInstance();
    final cachedAds = prefs.getStringList('${_domainsKey}_ads') ?? [];
    final cachedTracking = prefs.getStringList('${_domainsKey}_tracking') ?? [];
    final cachedExcepted = prefs.getStringList('${_domainsKey}_excepted') ?? [];
    final cachedPatterns = prefs.getStringList(_patternsKey) ?? [];
    final cachedCosmetics = prefs.getStringList(_cosmeticKey) ?? [];
    final cachedScriptlets = prefs.getStringList(_scriptletsKey) ?? [];

    _downloadedDomains = cachedAds.toSet();
    _downloadedTrackingDomains = cachedTracking.toSet();
    _allowListedDomains = cachedExcepted.toSet();
    _urlPatterns.addAll(cachedPatterns);
    _cosmeticRules.addAll(cachedCosmetics);
    _scriptletRules.addAll(cachedScriptlets);

    final siteCosmeticsStr = prefs.getString(_siteCosmeticKey);
    if (siteCosmeticsStr != null) {
      try {
        final decoded = jsonDecode(siteCosmeticsStr) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          final rules = (entry.value as List).cast<String>();
          _siteCosmeticRules[entry.key] = rules.toSet();
        }
      } catch (e) {
        _log.warning('Failed to load site cosmetic rules', e);
      }
    }
  }

  Future<bool> isStale() async {
    final prefs = await SharedPreferences.getInstance();
    final lastUpdate = prefs.getInt(_lastUpdateKey) ?? 0;
    if (lastUpdate == 0) return true;
    final daysSince =
        (DateTime.now().millisecondsSinceEpoch - lastUpdate) ~/
            (1000 * 60 * 60 * 24);
    return daysSince >= _updateIntervalDays;
  }

  Future<bool> updateIfNeeded({bool force = false}) async {
    if (_inFlightUpdate != null) {
      return _inFlightUpdate!.future;
    }
    final completer = Completer<bool>();
    _inFlightUpdate = completer;

    try {
      final res = await _lock.synchronized(() async {
        final prefs = await SharedPreferences.getInstance();
        final enabled = prefs.getBool(_enabledKey) ?? true;
        if (!enabled && !force) return false;

        if (!force) {
          final stale = await isStale();
          if (!stale) return false;
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
      completer.complete(res);
      return res;
    } catch (e) {
      completer.completeError(e);
      rethrow;
    } finally {
      _inFlightUpdate = null;
    }
  }

  Future<void> _downloadAndParse() async {
    _invalidateCosmeticCache();
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
        headers: {'User-Agent': 'XDM/3.0 (AdBlockUpdater)'},
      ),
    );

    final prefs = await SharedPreferences.getInstance();
    final tempDir = await getTemporaryDirectory();

    for (final source in _sources) {
      try {
        final tempPath = p.join(tempDir.path, '${source.name}.txt');
        await dio.download(source.url, tempPath);

        final file = File(tempPath);

        // ── Integrity check 1: reject empty files ──────────────────────────
        final fileSize = await file.length();
        if (fileSize == 0) {
          _log.warning('Filter ${source.name}: rejected empty file');
          if (await file.exists()) await file.delete();
          continue;
        }

        // ── Integrity check 2: reject binary content (null bytes) ──────────
        final sample = await file.openRead(0, 1024).expand((b) => b).toList();
        if (sample.contains(0x00)) {
          _log.warning('Filter ${source.name}: rejected binary content');
          if (await file.exists()) await file.delete();
          continue;
        }

        // ── Integrity check 3: reject suspicious size regressions ──────────
        final sizeKey = 'adblock_last_size_${source.name}';
        final lastSize = prefs.getInt(sizeKey) ?? 0;
        if (lastSize > 0 && fileSize < (lastSize * 0.50).round()) {
          _log.warning(
            'Filter ${source.name}: rejected suspiciously small file '
            '($fileSize bytes vs last good $lastSize bytes)',
          );
          if (await file.exists()) await file.delete();
          continue;
        }

        final result = await _parseFilterFile(file, source.type);

        // Save size of the successfully validated file for future comparisons
        await prefs.setInt(sizeKey, fileSize);

        // Save successfully parsed sets for this specific source
        await prefs.setStringList(
          'adblock_domains_blocked_${source.name}',
          result.blocked.toList(),
        );
        await prefs.setStringList(
          'adblock_domains_excepted_${source.name}',
          result.excepted.toList(),
        );

        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        _log.warning('Failed to download or parse source ${source.name}', e);
      }
    }

    // Now re-combine all cached source sets (using whatever currently exists in cache)
    final combinedAds = <String>{};
    final combinedTracking = <String>{};
    final combinedAdsExceptions = <String>{};
    final combinedTrackingExceptions = <String>{};

    for (final source in _sources) {
      final blocked = prefs.getStringList('adblock_domains_blocked_${source.name}') ?? [];
      final excepted = prefs.getStringList('adblock_domains_excepted_${source.name}') ?? [];

      if (source.type == FilterType.ads) {
        combinedAds.addAll(blocked);
        combinedAdsExceptions.addAll(excepted);
      } else {
        combinedTracking.addAll(blocked);
        combinedTrackingExceptions.addAll(excepted);
      }
    }

    _downloadedDomains = combinedAds.difference(combinedAdsExceptions);
    _downloadedTrackingDomains = combinedTracking.difference(combinedTrackingExceptions);
    _allowListedDomains = combinedAdsExceptions.union(combinedTrackingExceptions);

    // Save final merged sets
    await prefs.setStringList(
      '${_domainsKey}_ads',
      _downloadedDomains.take(_maxDomains).toList(),
    );
    await prefs.setStringList(
      '${_domainsKey}_tracking',
      _downloadedTrackingDomains.take(_maxDomains).toList(),
    );
    await prefs.setStringList(
      '${_domainsKey}_excepted',
      _allowListedDomains.take(_maxDomains).toList(),
    );
    await prefs.setStringList(
      _patternsKey,
      _urlPatterns.take(5000).toList(),
    );
    await prefs.setStringList(
      _cosmeticKey,
      _cosmeticRules.take(5000).toList(),
    );

    // Save site-cosmetic rules map to preferences
    final siteCosmeticsJson = jsonEncode(_siteCosmeticRules.map((k, v) => MapEntry(k, v.toList())));
    await prefs.setString(_siteCosmeticKey, siteCosmeticsJson);

    await prefs.setStringList(
      _scriptletsKey,
      _scriptletRules.take(1000).toList(),
    );
  }

  Future<({Set<String> blocked, Set<String> excepted})> _parseFilterFile(File file, FilterType type) async {
    final blocked = <String>{};
    final excepted = <String>{};
    final lines = await file.readAsLines();

    for (final line in lines) {
      if (blocked.length >= _maxDomains) break;
      if (line.isEmpty || line.length > _maxLineLength) continue;

      // Comments (ABP format uses !, hosts/plain lists use #)
      // NB: `##.class` cosmetic rules also start with '#', so only treat
      // lines that start with a bare '#' (not '##') as comments.
      if (line.startsWith('!') ||
          line.startsWith('[') ||
          (line.startsWith('#') && !line.startsWith('##'))) {
        continue;
      }

      // Exception rules @@||
      if (line.startsWith('@@')) {
        final inner = line.substring(2);
        final domainMatch = RegExp(
          r'^\|\|([a-zA-Z0-9.-]+)\^',
        ).firstMatch(inner);
        if (domainMatch != null) {
          excepted.add(domainMatch.group(1)!.toLowerCase());
        }
        continue;
      }

      // Scriptlet rules: ##+js(...) or site.com##+js(...)
      if (line.contains('##+js(')) {
        final parts = line.split('##+js(');
        if (parts.length == 2 && parts[1].isNotEmpty) {
          // Extract the content inside the parentheses
          final scriptlet = parts[1]
              .substring(0, parts[1].length - (parts[1].endsWith(')') ? 1 : 0));
          if (scriptlet.isNotEmpty) {
            _scriptletRules.add(scriptlet);
          }
        }
        continue;
      }

      // Cosmetic rules: ##.ad-container, ###sidebar-ad, site.com##.ad
      if (line.contains('##')) {
        final parts = line.split('##');
        if (parts.length == 2 && parts[1].isNotEmpty && parts[1].length < 100) {
          final selector = parts[1];
          if (parts[0].isEmpty) {
            _cosmeticRules.add(selector);
          } else {
            final domainsList = parts[0].split(',');
            for (var domain in domainsList) {
              domain = domain.trim().toLowerCase();
              if (domain.isEmpty || domain.startsWith('~')) continue;
              _siteCosmeticRules.putIfAbsent(domain, () => {}).add(selector);
            }
          }
        }
        continue;
      }

      // ABP-style ||domain^ rules
      final domainMatch = RegExp(
        r'^\|\|([a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9])\^',
      ).firstMatch(line);
      if (domainMatch != null) {
        final domain = domainMatch.group(1)!.toLowerCase();
        if (domain.contains('.') && !domain.startsWith('.')) {
          blocked.add(domain);
        }
        continue;
      }

      // Plain domain-per-line format (Peter Lowe list, hosts files, etc.)
      // Accept lines that look like bare hostnames: e.g. "ads.example.com"
      final trimmed = line.trim();
      if (RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$')
          .hasMatch(trimmed)) {
        final domain = trimmed.toLowerCase();
        if (!domain.startsWith('.')) {
          blocked.add(domain);
        }
        continue;
      }

      // URL path patterns: /ads/banner
      if (line.startsWith('/') && !line.startsWith('//')) {
        _urlPatterns.add(line);
      }
    }

    return (blocked: blocked, excepted: excepted);
  }

  @visibleForTesting
  Future<({Set<String> blocked, Set<String> excepted})> parseFilterFile(File file, FilterType type) =>
      _parseFilterFile(file, type);

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

  Set<String> cosmeticRulesForHost(String host) {
    final cacheKey = host.toLowerCase();

    // Fast path: return cached result if present.
    final cached = _cosmeticCache[cacheKey];
    if (cached != null) {
      // Refresh LRU position by removing and re-inserting.
      _cosmeticCache.remove(cacheKey);
      _cosmeticCache[cacheKey] = cached;
      return cached;
    }

    // Slow path: compute and store.
    final rules = <String>{}..addAll(_cosmeticRules);
    if (cacheKey.isNotEmpty) {
      if (_siteCosmeticRules.containsKey(cacheKey)) {
        rules.addAll(_siteCosmeticRules[cacheKey]!);
      }
      final parts = cacheKey.split('.');
      for (var i = 1; i < parts.length - 1; i++) {
        final parent = parts.sublist(i).join('.');
        if (_siteCosmeticRules.containsKey(parent)) {
          rules.addAll(_siteCosmeticRules[parent]!);
        }
      }
    }

    // Evict oldest entry if at capacity.
    if (_cosmeticCache.length >= _kCosmeticCacheMax) {
      _cosmeticCache.remove(_cosmeticCache.keys.first);
    }
    _cosmeticCache[cacheKey] = rules;
    return rules;
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
    _invalidateCosmeticCache();
    _downloadedDomains.clear();
    _downloadedTrackingDomains.clear();
    _siteCosmeticRules.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('${_domainsKey}_ads');
    await prefs.remove('${_domainsKey}_tracking');
    await prefs.remove(_cosmeticKey);
    await prefs.remove(_siteCosmeticKey);
    for (final source in _sources) {
      await prefs.remove('adblock_domains_blocked_${source.name}');
      await prefs.remove('adblock_domains_excepted_${source.name}');
    }
    await prefs.remove(_lastUpdateKey);
  }
}
