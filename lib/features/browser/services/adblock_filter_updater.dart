import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';

import 'filter_line_parser.dart';

enum FilterType { ads, tracking }

class _FilterSource {
  final String name;
  final String url;

  /// Optional fallback URL tried when [url] fails (e.g. CDN mirror).
  final String? fallbackUrl;
  final FilterType type;
  final double regressionThreshold;

  const _FilterSource({
    required this.name,
    required this.url,
    this.fallbackUrl,
    required this.type,
    this.regressionThreshold = 0.50,
  });
}

class _PathTrieNode {
  final Map<int, _PathTrieNode> children = {};
  bool isEnd = false;
}

class _PathTrie {
  final _PathTrieNode root = _PathTrieNode();

  void insert(String pattern) {
    if (pattern.isEmpty) return;
    var current = root;
    for (var i = 0; i < pattern.length; i++) {
      final code = pattern.codeUnitAt(i);
      current = current.children.putIfAbsent(code, () => _PathTrieNode());
    }
    current.isEnd = true;
  }

  bool searchSubstrings(String text) {
    if (text.isEmpty || root.children.isEmpty) return false;
    final len = text.length;
    for (var i = 0; i < len; i++) {
      final firstCode = text.codeUnitAt(i);
      var current = root.children[firstCode];
      if (current == null) continue;
      if (current.isEnd) return true;
      for (var j = i + 1; j < len; j++) {
        final code = text.codeUnitAt(j);
        final next = current!.children[code];
        if (next == null) break;
        if (next.isEnd) return true;
        current = next;
      }
    }
    return false;
  }

  void clear() {
    root.children.clear();
  }
}

class AdBlockFilterUpdater {
  static final AdBlockFilterUpdater _instance =
      AdBlockFilterUpdater._internal();
  AdBlockFilterUpdater._internal();
  factory AdBlockFilterUpdater() => _instance;
  static AdBlockFilterUpdater get instance => _instance;

  static final _log = Logger('AdBlockFilterUpdater');
  static final _lock = Lock();

  // ── Filter sources with CDN fallbacks ─────────────────────────────────────
  static const _sources = [
    _FilterSource(
      name: 'EasyList',
      url: 'https://easylist.to/easylist/easylist.txt',
      fallbackUrl: 'https://easylist-downloads.adblockplus.org/easylist.txt',
      type: FilterType.ads,
      regressionThreshold: 0.30, // Allows valid rule consolidations
    ),
    _FilterSource(
      name: 'EasyPrivacy',
      url: 'https://easylist.to/easylist/easyprivacy.txt',
      fallbackUrl: 'https://easylist-downloads.adblockplus.org/easyprivacy.txt',
      type: FilterType.tracking,
      regressionThreshold: 0.30,
    ),
    _FilterSource(
      name: 'EasyList-AntiAdblock',
      url: 'https://easylist-downloads.adblockplus.org/antiadblockfilters.txt',
      type: FilterType.ads,
    ),
    _FilterSource(
      name: 'PeterLowe',
      url:
          'https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext',
      type: FilterType.ads,
    ),
    _FilterSource(
      name: 'AdGuardDNS',
      url:
          'https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt',
      fallbackUrl:
          'https://raw.githubusercontent.com/AdguardTeam/AdguardFilters/master/Filters/filter_15_DnsFilter/filter.txt',
      type: FilterType.ads,
    ),
    _FilterSource(
      name: 'AdAway',
      url: 'https://adaway.org/hosts.txt',
      type: FilterType.ads,
    ),
    _FilterSource(
      name: 'uBlock-Filters',
      url:
          'https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt',
      type: FilterType.ads,
    ),
    _FilterSource(
      name: 'uBlock-Badware',
      url:
          'https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/badware.txt',
      type: FilterType.ads,
    ),
    _FilterSource(
      name: 'uBlock-Privacy',
      url:
          'https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/privacy.txt',
      type: FilterType.tracking,
    ),
    _FilterSource(
      name: 'uBlock-Unbreak',
      url:
          'https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/unbreak.txt',
      type: FilterType.ads,
    ),
    _FilterSource(
      name: 'uBlock-QuickFixes',
      url:
          'https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/quick-fixes.txt',
      type: FilterType.ads,
    ),
  ];

  static const _lastUpdateKey = 'adblock_last_update_ms';
  static const _domainsKey = 'adblock_downloaded_domains';
  static const _enabledKey = 'adblock_auto_update_enabled';
  static const _updateIntervalDays = 7;
  static const _maxDomains = 150000;

  static const _patternsKey = 'adblock_url_patterns';
  static const _cosmeticKey = 'adblock_cosmetic_rules_v2';
  static const _siteCosmeticKey = 'adblock_site_cosmetic_rules_v2';
  static const _globalCosmeticExceptionsKey =
      'adblock_global_cosmetic_exceptions_v2';
  static const _siteCosmeticExceptionsKey =
      'adblock_site_cosmetic_exceptions_v2';
  static const _scriptletsKey = 'adblock_scriptlet_rules';

  bool _initialized = false;
  Set<String> _downloadedDomains = {};
  Set<String> _downloadedTrackingDomains = {};
  final Set<String> _urlPatterns = {};
  final _PathTrie _urlPatternsTrie = _PathTrie();
  final Set<String> _cosmeticRules = {};
  final Map<String, Set<String>> _siteCosmeticRules = {};
  final Map<String, Set<String>> _cosmeticExceptions = {};
  final Set<String> _globalCosmeticExceptions = {};
  final Set<String> _scriptletRules = {};
  final Map<String, RegExp> _compiledWildcardPatterns = {};

  void _rebuildWildcardPatterns([Set<String>? changedPatterns]) {
    // FIX(P6): Incremental rebuild — when the caller knows exactly which
    // patterns changed (added/removed), only those are recompiled instead of
    // clearing and recompiling the entire cache on every filter update.
    if (changedPatterns == null) {
      _compiledWildcardPatterns.clear();
      for (final pattern in _urlPatterns) {
        if (pattern.contains('*')) {
          try {
            _compiledWildcardPatterns[pattern] =
                _compileWildcardPattern(pattern);
          } catch (_) {}
        }
      }
      return;
    }

    for (final pattern in changedPatterns) {
      if (!_urlPatterns.contains(pattern)) {
        // Pattern was removed.
        _compiledWildcardPatterns.remove(pattern);
        continue;
      }
      if (!pattern.contains('*')) {
        _compiledWildcardPatterns.remove(pattern);
        continue;
      }
      try {
        _compiledWildcardPatterns[pattern] = _compileWildcardPattern(pattern);
      } catch (_) {
        _compiledWildcardPatterns.remove(pattern);
      }
    }
  }

  RegExp _compileWildcardPattern(String pattern) {
    final regexStr = '^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$';
    return RegExp(regexStr, caseSensitive: false);
  }

  // PERF (TASK 4): LRU cache for cosmeticRulesForHost.
  // Keyed by lowercase host; evicts the oldest entry when capacity is reached.
  // Invalidated whenever _cosmeticRules or _siteCosmeticRules is mutated
  // (i.e., after a filter download/update).
  static const _kCosmeticCacheMax = 50;
  final LinkedHashMap<String, Set<String>> _cosmeticCache =
      LinkedHashMap<String, Set<String>>();

  void _invalidateCosmeticCache() => _cosmeticCache.clear();

  static const String _userAllowlistKey = 'adblock_user_allowlist';
  Set<String> _userAllowListedDomains = {};
  Set<String> _downloadedExceptions = {};
  Completer<bool>? _inFlightUpdate;

  Set<String> get allBlockedDomains => _downloadedDomains;
  Set<String> get allTrackingDomains => _downloadedTrackingDomains;
  Set<String> get allowListedDomains =>
      Set.unmodifiable({..._userAllowListedDomains, ..._downloadedExceptions});
  int get downloadedDomainCount => _downloadedDomains.length;
  int get downloadedTrackingCount => _downloadedTrackingDomains.length;
  Set<String> get cosmeticRules => _cosmeticRules;
  Set<String> get urlPatterns => _urlPatterns;
  Set<String> get scriptletRules => _scriptletRules;

  Future<void> persistUserAllowList() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _userAllowlistKey,
      _userAllowListedDomains.toList(),
    );
  }

  void addAllowListDomain(String domain) {
    if (domain.isEmpty) return;
    _userAllowListedDomains.add(domain.toLowerCase());
    unawaited(persistUserAllowList());
  }

  void removeAllowListDomain(String domain) {
    if (domain.isEmpty) return;
    _userAllowListedDomains.remove(domain.toLowerCase());
    unawaited(persistUserAllowList());
  }

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final prefs = await SharedPreferences.getInstance();
    final cachedAds = prefs.getStringList('${_domainsKey}_ads') ?? [];
    final cachedTracking = prefs.getStringList('${_domainsKey}_tracking') ?? [];
    final cachedExcepted = prefs.getStringList('${_domainsKey}_excepted') ?? [];
    final userAllowlist = prefs.getStringList(_userAllowlistKey) ?? [];
    final cachedPatterns = prefs.getStringList(_patternsKey) ?? [];
    final cachedCosmetics = prefs.getStringList(_cosmeticKey) ?? [];
    final cachedScriptlets = prefs.getStringList(_scriptletsKey) ?? [];

    _downloadedDomains = cachedAds.toSet();
    _downloadedTrackingDomains = cachedTracking.toSet();
    _downloadedExceptions = cachedExcepted.toSet();
    _userAllowListedDomains = userAllowlist.toSet();
    _urlPatterns.addAll(cachedPatterns);
    // FIX: Populate the trie on startup so path-based blocking works immediately
    for (final p in cachedPatterns) {
      _urlPatternsTrie.insert(p);
    }
    // FIX(P6): Initial load is a full build, but passing the explicit set keeps
    // the wildcard cache consistent with only the patterns we actually have.
    _rebuildWildcardPatterns(cachedPatterns.toSet());
    _cosmeticRules.addAll(cachedCosmetics);
    _scriptletRules.addAll(cachedScriptlets);

    final globalCosmeticExceptions =
        prefs.getStringList(_globalCosmeticExceptionsKey) ?? [];
    _globalCosmeticExceptions.addAll(globalCosmeticExceptions);

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

    final siteCosmeticExceptionsStr =
        prefs.getString(_siteCosmeticExceptionsKey);
    if (siteCosmeticExceptionsStr != null) {
      try {
        final decoded =
            jsonDecode(siteCosmeticExceptionsStr) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          final rules = (entry.value as List).cast<String>();
          _cosmeticExceptions[entry.key] = rules.toSet();
        }
      } catch (e) {
        _log.warning('Failed to load site cosmetic exceptions', e);
      }
    }
  }

  Future<bool> isStale() async {
    final prefs = await SharedPreferences.getInstance();
    final lastUpdate = prefs.getInt(_lastUpdateKey) ?? 0;
    if (lastUpdate == 0) return true;
    final daysSince = (DateTime.now().millisecondsSinceEpoch - lastUpdate) ~/
        (1000 * 60 * 60 * 24);
    return daysSince >= _updateIntervalDays;
  }

  Timer? _autoUpdateTimer;

  void startAutoUpdateScheduler() {
    _autoUpdateTimer?.cancel();
    _autoUpdateTimer = Timer.periodic(const Duration(hours: 24), (_) {
      updateIfNeeded();
    });
    unawaited(updateIfNeeded().catchError((e) {
      _log.warning('Failed to update if needed', e);
      return false;
    }));
  }

  void stopAutoUpdateScheduler() {
    _autoUpdateTimer?.cancel();
    _autoUpdateTimer = null;
  }

  Future<bool> updateIfNeeded({bool force = false}) async {
    if (_inFlightUpdate != null) {
      // If a force-update is requested while one is in flight, wait for the
      // current one and re-run if it was not a force update.
      final result = await _inFlightUpdate!.future;
      return force ? await updateIfNeeded(force: true) : result;
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

  // ── HttpClient-based download ─────────────────────────────────────────────
  // Uses dart:io HttpClient instead of dio.download() to avoid the
  // "Invalid request method" exception thrown on Android SDK 33+ when
  // dio tries to use a custom HTTP method for file downloads.
  static const _kDownloadHeaders = {
    'User-Agent': 'Mozilla/5.0 (compatible; XDM/3.0; AdBlockUpdater)',
    'Accept': 'text/plain, text/html;q=0.9, */*;q=0.8',
    'Accept-Encoding': 'gzip, deflate',
    'Connection': 'keep-alive',
  };

  /// Downloads [url] into [destPath] using [HttpClient].
  /// Returns `false` if the server returns a non-200 status or the body
  /// is suspiciously small (< 1 KB), so the caller can try a fallback.
  Future<bool> _httpDownload(String url, String destPath) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      final uri = Uri.parse(url);
      final request = await client.getUrl(uri);
      _kDownloadHeaders.forEach(request.headers.set);
      final response =
          await request.close().timeout(const Duration(seconds: 90));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        _log.warning(
          '_httpDownload: server returned ${response.statusCode} for $url',
        );
        await response.drain<void>();
        return false;
      }

      final file = File(destPath);
      final sink = file.openWrite();
      try {
        await sink.addStream(response);
        await sink.flush();
        await sink.close();
      } catch (_) {
        await sink.close();
        rethrow;
      }

      // Reject suspiciously small responses (< 1 KB → probably an error page)
      final size = await file.length();
      if (size < 1024) {
        _log.warning(
            '_httpDownload: response too small ($size bytes) for $url');
        if (await file.exists()) await file.delete();
        return false;
      }

      return true;
    } catch (e) {
      _log.warning('_httpDownload error for $url', e);
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _downloadAndParse() async {
    _invalidateCosmeticCache();
    // FIX(P6): Track exactly which url patterns changed during this update so
    // wildcard regexes are only recompiled for those, not the whole cache.
    final changedPatterns = <String>{};

    // FIX: Clear all parsed rule sets BEFORE re-parsing so stale rules from
    // a previous update cycle don't accumulate. Without this, every update
    // appends to the existing sets, causing unbounded growth and duplicate
    // rules that waste memory and SharedPreferences space.
    _urlPatterns.clear();
    _urlPatternsTrie
        .clear(); // Bug #2 fix: trie must be cleared alongside _urlPatterns to avoid stale patterns accumulating across filter updates
    _cosmeticRules.clear();
    _siteCosmeticRules.clear();
    _cosmeticExceptions.clear();
    _globalCosmeticExceptions.clear();
    _scriptletRules.clear();

    final prefs = await SharedPreferences.getInstance();
    final tempDir = await getTemporaryDirectory();
    bool allSourcesSucceeded = true;

    // P4: Concurrency-limited parallel downloading of sources
    final chunks = <List<_FilterSource>>[];
    for (var i = 0; i < _sources.length; i += 3) {
      chunks.add(_sources.sublist(i, (i + 3 > _sources.length) ? _sources.length : i + 3));
    }

    for (final chunk in chunks) {
      await Future.wait(chunk.map((source) async {
        try {
          final tempPath = p.join(tempDir.path, '${source.name}.txt');

          // Try primary URL, fall back to mirror if it fails
          bool ok = await _httpDownload(source.url, tempPath);
          if (!ok && source.fallbackUrl != null) {
            _log.fine('Retrying ${source.name} with fallback URL');
            ok = await _httpDownload(source.fallbackUrl!, tempPath);
          }
          if (!ok) {
            _log.warning(
                'Failed to download source ${source.name} (all URLs failed)');
            allSourcesSucceeded = false;
            return;
          }

          final file = File(tempPath);

          // ── Integrity check 1: reject empty files ──────────────────────────
          final fileSize = await file.length();
          if (fileSize == 0) {
            _log.warning('Filter ${source.name}: rejected empty file');
            if (await file.exists()) await file.delete();
            return;
          }

          // ── Integrity check 2: reject binary content (null bytes) ──────────
          final sample = await file.openRead(0, 1024).expand((b) => b).toList();
          if (sample.contains(0x00)) {
            _log.warning('Filter ${source.name}: rejected binary content');
            if (await file.exists()) await file.delete();
            return;
          }

          // ── Integrity check 3: reject suspicious size regressions ──────────
          final sizeKey = 'adblock_last_size_${source.name}';
          final lastSize = prefs.getInt(sizeKey) ?? 0;
          if (lastSize > 0 &&
              fileSize < (lastSize * source.regressionThreshold).round()) {
            _log.warning(
              'Filter ${source.name}: rejected suspiciously small file '
              '($fileSize bytes vs last good $lastSize bytes)',
            );
            if (await file.exists()) await file.delete();
            return;
          }

          final lines = await file.readAsLines();
          if (!_isValidFilterSyntax(lines)) {
            _log.warning(
                'Filter ${source.name}: rejected due to invalid syntax (looks like HTML/JSON or corrupted)');
            if (await file.exists()) await file.delete();
            return;
          }

          final result = await _parseFilterLines(lines, source.type, changedPatterns);

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
      }));
    }

    // Now re-combine all cached source sets (using whatever currently exists in cache)
    final combinedAds = <String>{};
    final combinedTracking = <String>{};
    final combinedAdsExceptions = <String>{};
    final combinedTrackingExceptions = <String>{};

    for (final source in _sources) {
      final blocked =
          prefs.getStringList('adblock_domains_blocked_${source.name}') ?? [];
      final excepted =
          prefs.getStringList('adblock_domains_excepted_${source.name}') ?? [];

      if (source.type == FilterType.ads) {
        combinedAds.addAll(blocked);
        combinedAdsExceptions.addAll(excepted);
      } else {
        combinedTracking.addAll(blocked);
        combinedTrackingExceptions.addAll(excepted);
      }
    }

    _downloadedDomains = combinedAds.difference(combinedAdsExceptions);
    _downloadedTrackingDomains =
        combinedTracking.difference(combinedTrackingExceptions);
    _downloadedExceptions =
        combinedAdsExceptions.union(combinedTrackingExceptions);

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
      _downloadedExceptions.take(_maxDomains).toList(),
    );

    final hasCachedPatterns = prefs.containsKey(_patternsKey);
    final hasCachedCosmetics = prefs.containsKey(_cosmeticKey);
    final hasCachedScriptlets = prefs.containsKey(_scriptletsKey);
    final isFirstRun =
        !hasCachedPatterns && !hasCachedCosmetics && !hasCachedScriptlets;

    if (allSourcesSucceeded || isFirstRun) {
      await prefs.setStringList(
        _patternsKey,
        _urlPatterns.take(5000).toList(),
      );
      await prefs.setStringList(
        _cosmeticKey,
        _cosmeticRules.take(5000).toList(),
      );

      // Save site-cosmetic rules map to preferences
      final siteCosmeticsJson =
          jsonEncode(_siteCosmeticRules.map((k, v) => MapEntry(k, v.toList())));
      await prefs.setString(_siteCosmeticKey, siteCosmeticsJson);

      // Save cosmetic exceptions (global + per-site) so they survive restarts
      await prefs.setStringList(
        _globalCosmeticExceptionsKey,
        _globalCosmeticExceptions.toList(),
      );
      final siteCosmeticExceptionsJson = jsonEncode(
          _cosmeticExceptions.map((k, v) => MapEntry(k, v.toList())));
      await prefs.setString(
          _siteCosmeticExceptionsKey, siteCosmeticExceptionsJson);

      await prefs.setStringList(
        _scriptletsKey,
        _scriptletRules.take(1000).toList(),
      );
      // FIX(P6): Only recompile wildcard regexes that actually changed.
      _rebuildWildcardPatterns(changedPatterns);
    } else {
      _log.warning(
          'Some filter sources failed to download. Pattern and cosmetic rule updates were skipped to prevent data loss.');
      // Reload old patterns/cosmetics from prefs to restore in-memory state
      _urlPatterns.clear();
      _urlPatternsTrie.clear();
      _cosmeticRules.clear();
      _siteCosmeticRules.clear();
      _cosmeticExceptions.clear();
      _scriptletRules.clear();

      final cachedPatterns = prefs.getStringList(_patternsKey) ?? [];
      final cachedCosmetics = prefs.getStringList(_cosmeticKey) ?? [];
      final cachedScriptlets = prefs.getStringList(_scriptletsKey) ?? [];
      _urlPatterns.addAll(cachedPatterns);
      for (final p in cachedPatterns) {
        _urlPatternsTrie.insert(p);
      }
      // FIX(P6): Rebuild only from the restored pattern set.
      _rebuildWildcardPatterns(cachedPatterns.toSet());
      _cosmeticRules.addAll(cachedCosmetics);
      _scriptletRules.addAll(cachedScriptlets);

      _globalCosmeticExceptions.clear();
      _globalCosmeticExceptions
          .addAll(prefs.getStringList(_globalCosmeticExceptionsKey) ?? []);

      final siteCosmeticsStr = prefs.getString(_siteCosmeticKey);
      if (siteCosmeticsStr != null) {
        try {
          final decoded = jsonDecode(siteCosmeticsStr) as Map<String, dynamic>;
          for (final entry in decoded.entries) {
            final rules = (entry.value as List).cast<String>();
            _siteCosmeticRules[entry.key] = rules.toSet();
          }
          // ignore: empty_catches
        } catch (e, st) {
          LoggingService.logger('AdblockFilterUpdater')
              .warning('Operation failed', e, st);
        }
      }

      final siteCosmeticExceptionsStr =
          prefs.getString(_siteCosmeticExceptionsKey);
      if (siteCosmeticExceptionsStr != null) {
        try {
          final decoded =
              jsonDecode(siteCosmeticExceptionsStr) as Map<String, dynamic>;
          for (final entry in decoded.entries) {
            final rules = (entry.value as List).cast<String>();
            _cosmeticExceptions[entry.key] = rules.toSet();
          }
          // ignore: empty_catches
        } catch (e, st) {
          LoggingService.logger('AdblockFilterUpdater')
              .warning('Operation failed', e, st);
        }
      }
    }
  }

  Future<({Set<String> blocked, Set<String> excepted})> _parseFilterLines(
      List<String> lines, FilterType type, Set<String> changedPatterns) async {
    final parsed = FilterLineParser.parse(lines, type);

    _scriptletRules.addAll(parsed.scriptletRules);
    _cosmeticRules.addAll(parsed.cosmeticRules);
    _globalCosmeticExceptions.addAll(parsed.globalCosmeticExceptions);

    for (final entry in parsed.siteCosmeticRules.entries) {
      _siteCosmeticRules
          .putIfAbsent(entry.key, () => <String>{})
          .addAll(entry.value);
    }
    for (final entry in parsed.cosmeticExceptions.entries) {
      _cosmeticExceptions
          .putIfAbsent(entry.key, () => <String>{})
          .addAll(entry.value);
    }

    _urlPatterns.addAll(parsed.urlPatterns);
    for (final p in parsed.exactPathPatterns) {
      _urlPatternsTrie.insert(p);
    }
    // FIX(P6): Remember these patterns so the wildcard cache can be rebuilt
    // incrementally after all sources finish parsing.
    changedPatterns.addAll(parsed.urlPatterns.where((p) => p.contains('*')));

    return (blocked: parsed.blocked, excepted: parsed.excepted);
  }

  @visibleForTesting
  Future<({Set<String> blocked, Set<String> excepted})> parseFilterFile(
          File file, FilterType type) async =>
      _parseFilterLines(await file.readAsLines(), type, <String>{});

  /// FIX(P7): Expose URL-path pattern matching (wildcard regexes + trie)
  /// separately from domain checks so callers can merge domain lookups into a
  /// single set instead of re-walking the same domains here.
  bool matchesUrlPath(String path) {
    if (path.isEmpty) return false;
    for (final regex in _compiledWildcardPatterns.values) {
      if (regex.hasMatch(path)) {
        return true;
      }
    }
    return _urlPatternsTrie.searchSubstrings(path);
  }

  bool shouldBlock(String hostnameOrUrl) {
    if (hostnameOrUrl.isEmpty) return false;

    String lower = hostnameOrUrl.toLowerCase();
    String path = '';
    if (hostnameOrUrl.contains('://')) {
      try {
        final uri = Uri.parse(hostnameOrUrl);
        lower = uri.host.toLowerCase();
        path = uri.path;
      } catch (e, st) {
        LoggingService.logger('AdblockFilterUpdater')
            .warning('Operation failed', e, st);
      }
    } else if (hostnameOrUrl.contains('/')) {
      final idx = hostnameOrUrl.indexOf('/');
      lower = hostnameOrUrl.substring(0, idx).toLowerCase();
      path = hostnameOrUrl.substring(idx);
    }

    // FIX #9 & PERF P2: Check collected URL path patterns using pre-compiled wildcard patterns and Trie
    if (matchesUrlPath(path)) return true;

    // FIX: Check allow-list FIRST so excepted domains are never blocked,
    // even if they appear in a blocklist.
    final allowed = allowListedDomains;
    if (allowed.contains(lower)) return false;
    final parts = lower.split('.');
    for (var i = 1; i < parts.length - 1; i++) {
      final parent = parts.sublist(i).join('.');
      if (allowed.contains(parent)) return false;
    }

    if (_downloadedDomains.contains(lower)) return true;
    if (_downloadedTrackingDomains.contains(lower)) return true;

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
    rules.removeAll(_globalCosmeticExceptions);
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

      // Remove any selectors exempted for this host or its parent domains (~domain rules)
      if (_cosmeticExceptions.containsKey(cacheKey)) {
        rules.removeAll(_cosmeticExceptions[cacheKey]!);
      }
      for (var i = 1; i < parts.length - 1; i++) {
        final parent = parts.sublist(i).join('.');
        if (_cosmeticExceptions.containsKey(parent)) {
          rules.removeAll(_cosmeticExceptions[parent]!);
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
    _downloadedExceptions.clear();
    _siteCosmeticRules.clear();
    _cosmeticExceptions.clear();
    _globalCosmeticExceptions.clear();
    _urlPatterns.clear();
    _urlPatternsTrie.clear();
    _cosmeticRules.clear();
    _scriptletRules.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('${_domainsKey}_ads');
    await prefs.remove('${_domainsKey}_tracking');
    await prefs.remove('${_domainsKey}_excepted');
    await prefs.remove(_cosmeticKey);
    await prefs.remove(_siteCosmeticKey);
    await prefs.remove(_patternsKey);
    await prefs.remove(_scriptletsKey);
    await prefs.remove(_globalCosmeticExceptionsKey);
    await prefs.remove(_siteCosmeticExceptionsKey);
    for (final source in _sources) {
      await prefs.remove('adblock_domains_blocked_${source.name}');
      await prefs.remove('adblock_domains_excepted_${source.name}');
      await prefs.remove('adblock_last_size_${source.name}');
    }
    await prefs.remove(_lastUpdateKey);
  }

  bool _isValidFilterSyntax(List<String> lines) {
    int htmlTags = 0;
    for (var i = 0; i < lines.length && i < 100; i++) {
      final line = lines[i].trim().toLowerCase();
      if (line.contains('<!doctype html') ||
          line.contains('<html') ||
          line.contains('<head') ||
          line.contains('<body')) {
        htmlTags++;
      }
    }
    return htmlTags == 0;
  }
}
