import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
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

  /// Optional fallback URL tried when [url] fails (e.g. CDN mirror).
  final String? fallbackUrl;
  final FilterType type;

  const _FilterSource({
    required this.name,
    required this.url,
    this.fallbackUrl,
    required this.type,
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
    if (text.isEmpty) return false;
    final len = text.length;
    for (var i = 0; i < len; i++) {
      var current = root;
      for (var j = i; j < len; j++) {
        final code = text.codeUnitAt(j);
        final next = current.children[code];
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
  // ── Singleton ─────────────────────────────────────────────────────────────
  // CRITICAL FIX: Without a singleton, every AdBlockFilterUpdater() call
  // created a fresh instance with empty _downloadedDomains, making the entire
  // filter download pipeline useless for runtime URL blocking. Every caller
  // (shouldBlock, allowListedDomains, cosmeticRulesForHost) now shares the
  // same in-memory state that was populated by init() / updateIfNeeded().
  static final AdBlockFilterUpdater _instance =
      AdBlockFilterUpdater._internal();
  AdBlockFilterUpdater._internal();
  factory AdBlockFilterUpdater() => _instance;

  static final _log = Logger('AdBlockFilterUpdater');
  static final _lock = Lock();

  // ── Filter sources with CDN fallbacks ─────────────────────────────────────
  // Primary URLs are the canonical hosts; fallbackUrl is a CDN/jsDelivr mirror
  // used when the primary returns an error or times out.
  static const _sources = [
    _FilterSource(
      name: 'EasyList',
      url: 'https://easylist.to/easylist/easylist.txt',
      fallbackUrl: 'https://easylist-downloads.adblockplus.org/easylist.txt',
      type: FilterType.ads,
    ),
    _FilterSource(
      name: 'EasyPrivacy',
      url: 'https://easylist.to/easylist/easyprivacy.txt',
      fallbackUrl: 'https://easylist-downloads.adblockplus.org/easyprivacy.txt',
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
  final _PathTrie _urlPatternsTrie = _PathTrie();
  final Set<String> _cosmeticRules = {};
  final Map<String, Set<String>> _siteCosmeticRules = {};
  final Map<String, Set<String>> _cosmeticExceptions = {};
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
  static const double regressionThreshold = 0.50;

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
    // FIX: Populate the trie on startup so path-based blocking works immediately
    for (final p in cachedPatterns) {
      _urlPatternsTrie.insert(p);
    }
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
    final daysSince = (DateTime.now().millisecondsSinceEpoch - lastUpdate) ~/
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
        await response.pipe(sink);
      } finally {
        await sink.flush();
        await sink.close();
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
    _scriptletRules.clear();

    final prefs = await SharedPreferences.getInstance();
    final tempDir = await getTemporaryDirectory();
    bool allSourcesSucceeded = true;

    for (final source in _sources) {
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
          continue;
        }

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
        if (lastSize > 0 &&
            fileSize < (lastSize * regressionThreshold).round()) {
          _log.warning(
            'Filter ${source.name}: rejected suspiciously small file '
            '($fileSize bytes vs last good $lastSize bytes)',
          );
          if (await file.exists()) await file.delete();
          continue;
        }

        final lines = await file.readAsLines();
        if (!_isValidFilterSyntax(lines)) {
          _log.warning(
              'Filter ${source.name}: rejected due to invalid syntax (looks like HTML/JSON or corrupted)');
          if (await file.exists()) await file.delete();
          continue;
        }

        final result = await _parseFilterLines(lines, source.type);

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
    _allowListedDomains =
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
      _allowListedDomains.take(_maxDomains).toList(),
    );
    if (allSourcesSucceeded) {
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

      await prefs.setStringList(
        _scriptletsKey,
        _scriptletRules.take(1000).toList(),
      );
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
          // ignore: empty_catches
        } catch (e) {}
      }
    }
  }

  Future<({Set<String> blocked, Set<String> excepted})> _parseFilterLines(
      List<String> lines, FilterType type) async {
    final blocked = <String>{};
    final excepted = <String>{};

    for (final line in lines) {
      // FIX: Do not break early. Breaking causes exception rules (@@||) and
      // cosmetic rules (##.ad) later in the file to be silently ignored.
      // The _maxDomains limit is already safely enforced during the final
      if (line.isEmpty || line.length > _maxLineLength) continue;
      final trimmed = line.trim();

      // ABP Exception rules (@@||domain^)
      if (trimmed.startsWith('@@')) {
        final exceptionMatch = RegExp(
          r'^@@\|\|([a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9])\^',
        ).firstMatch(trimmed);
        if (exceptionMatch != null) {
          excepted.add(exceptionMatch.group(1)!.toLowerCase());
          continue;
        }
      }

      // Parse hosts file line format: "127.0.0.1 domain.com" or "0.0.0.0 domain.com"
      if (trimmed.startsWith('127.0.0.1') || trimmed.startsWith('0.0.0.0')) {
        final parts = trimmed.split(RegExp(r'\s+'));
        if (parts.length >= 2) {
          final domain = parts[1].trim().toLowerCase();
          if (RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$')
              .hasMatch(domain)) {
            blocked.add(domain);
            continue;
          }
        }
      }

      // Comments (ABP format uses !, hosts/plain lists use #)
      // NB: `##.class` cosmetic rules also start with '#', so only treat
      // lines that start with a bare '#' (not '##') as comments.
      if (line.startsWith('!') ||
          line.startsWith('[') ||
          (line.startsWith('#') &&
              !line.startsWith('##') &&
              !line.startsWith('#@#'))) {
        continue;
      }

      // Cosmetic exception rules: #@#.ad-container, site.com#@#.ad-container
      if (line.contains('#@#')) {
        final idx = line.indexOf('#@#');
        final firstPart = line.substring(0, idx);
        final secondPart = line.substring(idx + 3);
        if (secondPart.isNotEmpty && secondPart.length < 100) {
          final selector = secondPart;
          if (firstPart.isEmpty) {
            _cosmeticRules.remove(selector);
          } else {
            final domainsList = firstPart.split(',');
            for (var domain in domainsList) {
              domain = domain.trim().toLowerCase();
              if (domain.isEmpty) continue;
              _cosmeticExceptions
                  .putIfAbsent(domain, () => <String>{})
                  .add(selector);
            }
          }
        }
        continue;
      }

      // Cosmetic rules: ##.ad-container, ###sidebar-ad, site.com##.ad
      if (line.contains('##')) {
        final idx = line.indexOf('##');
        final firstPart = line.substring(0, idx);
        final secondPart = line.substring(idx + 2);
        if (secondPart.isNotEmpty && secondPart.length < 100) {
          final selector = secondPart;
          if (firstPart.isEmpty) {
            _cosmeticRules.add(selector);
          } else {
            final domainsList = firstPart.split(',');
            for (var domain in domainsList) {
              domain = domain.trim().toLowerCase();
              if (domain.isEmpty) continue;
              if (domain.startsWith('~')) {
                final excDomain = domain.substring(1).trim();
                if (excDomain.isNotEmpty) {
                  _cosmeticExceptions
                      .putIfAbsent(excDomain, () => <String>{})
                      .add(selector);
                }
              } else {
                _siteCosmeticRules
                    .putIfAbsent(domain, () => <String>{})
                    .add(selector);
              }
            }
          }
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
        _urlPatternsTrie.insert(line);
        continue;
      }
    }

    return (blocked: blocked, excepted: excepted);
  }

  @visibleForTesting
  Future<({Set<String> blocked, Set<String> excepted})> parseFilterFile(
          File file, FilterType type) async =>
      _parseFilterLines(await file.readAsLines(), type);

  bool shouldBlock(String hostnameOrUrl) {
    if (hostnameOrUrl.isEmpty) return false;

    String lower = hostnameOrUrl.toLowerCase();
    String path = '';
    if (hostnameOrUrl.contains('://')) {
      try {
        final uri = Uri.parse(hostnameOrUrl);
        lower = uri.host.toLowerCase();
        path = uri.path;
      } catch (_) {}
    } else if (hostnameOrUrl.contains('/')) {
      final idx = hostnameOrUrl.indexOf('/');
      lower = hostnameOrUrl.substring(0, idx).toLowerCase();
      path = hostnameOrUrl.substring(idx);
    }

    // FIX #9: Check collected URL path patterns
    if (path.isNotEmpty && _urlPatterns.isNotEmpty) {
      if (_urlPatternsTrie.searchSubstrings(path)) return true;
    }

    // FIX: Check allow-list FIRST so excepted domains are never blocked,
    // even if they appear in a blocklist.
    if (_allowListedDomains.contains(lower)) return false;
    final parts = lower.split('.');
    for (var i = 1; i < parts.length - 1; i++) {
      final parent = parts.sublist(i).join('.');
      if (_allowListedDomains.contains(parent)) return false;
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
    _allowListedDomains.clear();
    _siteCosmeticRules.clear();
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
    for (final source in _sources) {
      await prefs.remove('adblock_domains_blocked_${source.name}');
      await prefs.remove('adblock_domains_excepted_${source.name}');
      // FIX: Also remove the per-source size key so the regression check
      // doesn't reject the next download as "suspiciously small".
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

// Removed: _BypassHttpOverrides was an empty HttpOverrides subclass that
// had no effect. SSL bypass is now handled directly on the HttpClient
// via badCertificateCallback in _httpDownload().
