import 'dart:async';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../logging_service.dart';
import 'url_patterns.dart';
import 'site_registry.dart';

final _log = LoggingService.logger('SiteIntelligenceService');

enum SiteType {
  fileHosting,
  videoStreaming,
  audioStreaming,
  socialMedia,
  torrentSite,
  magnetSource,
  cloudStorage,
  softwareRepo,
  archiveSite,
  genericDirect,
  genericWebpage,
}

enum ContentHint {
  videoFile,
  audioFile,
  videoStream,
  audioStream,
  archiveFile,
  softwarePackage,
  document,
  image,
  mixedMedia,
  unknown,
}

enum DownloadStrategy {
  directHttp,
  resumableHttp,
  multiThread,
  browserRequired,
  apiExtraction,
  magnetDht,
  redirectFollow,
  tokenRefresh,
}

class SiteProfile {
  final String domain;
  final SiteType type;
  final String? displayName;
  final bool requiresCookies;
  final bool requiresReferer;
  final String? refererValue;
  final Map<String, String> extraHeaders;
  final bool supportsRangeRequests;
  final bool needsBrowserUserAgent;
  final ContentHint contentHint;
  final DownloadStrategy strategy;
  final List<String> urlPatterns;
  final Duration? tokenExpiry;
  final bool urlsExpire;
  final int reliabilityScore;
  const SiteProfile({
    required this.domain,
    required this.type,
    this.displayName,
    this.requiresCookies = false,
    this.requiresReferer = false,
    this.refererValue,
    this.extraHeaders = const {},
    this.supportsRangeRequests = false,
    this.needsBrowserUserAgent = false,
    this.contentHint = ContentHint.unknown,
    this.strategy = DownloadStrategy.directHttp,
    this.urlPatterns = const [],
    this.tokenExpiry,
    this.urlsExpire = false,
    this.reliabilityScore = 100,
  });
}

class UrlAnalysisResult {
  final SiteType siteType;
  final SiteProfile? profile;
  final ContentHint contentHint;
  final DownloadStrategy recommendedStrategy;
  final String? detectedFileName;
  final String? detectedExtension;
  final String? detectedQuality;
  final bool isExpiredOrSigned;
  final Map<String, String> recommendedHeaders;
  final String inferredCategory;
  final double confidence;
  UrlAnalysisResult({
    required this.siteType,
    this.profile,
    required this.contentHint,
    required this.recommendedStrategy,
    this.detectedFileName,
    this.detectedExtension,
    this.detectedQuality,
    this.isExpiredOrSigned = false,
    this.recommendedHeaders = const {},
    required this.inferredCategory,
    this.confidence = 0.5,
  });
}

enum MagnetQuality {
  excellent,
  good,
  fair,
  poor,
}

class MagnetAnalysis {
  final String? displayName;
  final String? infoHash;
  final List<String> trackers;
  final int trackerCount;
  final MagnetQuality quality;
  final ContentHint contentHint;
  final String inferredCategory;
  final String? inferredQuality;
  final bool isVideoContent;
  final bool isAudioContent;
  final bool isSoftware;
  final List<String> contentKeywords;
  MagnetAnalysis({
    this.displayName,
    this.infoHash,
    required this.trackers,
    required this.trackerCount,
    required this.quality,
    required this.contentHint,
    required this.inferredCategory,
    this.inferredQuality,
    this.isVideoContent = false,
    this.isAudioContent = false,
    this.isSoftware = false,
    this.contentKeywords = const [],
  });
}

class SiteReliability {
  final String domain;
  int totalAttempts;
  int successes;
  int failures;
  double averageSpeedMbps;
  DateTime? lastSuccess;
  DateTime? lastFailure;
  String? lastError;
  SiteReliability({
    required this.domain,
    this.totalAttempts = 0,
    this.successes = 0,
    this.failures = 0,
    this.averageSpeedMbps = 0,
    this.lastSuccess,
    this.lastFailure,
    this.lastError,
  });
  int get score {
    if (totalAttempts == 0) return 100;
    return ((successes / totalAttempts) * 100).round();
  }

  Map<String, dynamic> toJson() => {
        'domain': domain,
        'totalAttempts': totalAttempts,
        'successes': successes,
        'failures': failures,
        'averageSpeedMbps': averageSpeedMbps,
        'lastSuccess': lastSuccess?.toIso8601String(),
        'lastFailure': lastFailure?.toIso8601String(),
        'lastError': lastError,
      };
  factory SiteReliability.fromJson(Map<String, dynamic> json) =>
      SiteReliability(
        domain: json['domain'] as String? ?? '',
        totalAttempts: json['totalAttempts'] as int? ?? 0,
        successes: json['successes'] as int? ?? 0,
        failures: json['failures'] as int? ?? 0,
        averageSpeedMbps: (json['averageSpeedMbps'] as num?)?.toDouble() ?? 0,
        lastSuccess: json['lastSuccess'] != null
            ? DateTime.tryParse(json['lastSuccess'] as String)
            : null,
        lastFailure: json['lastFailure'] != null
            ? DateTime.tryParse(json['lastFailure'] as String)
            : null,
        lastError: json['lastError'] as String?,
      );
}

class SiteIntelligenceService {
  static final SiteIntelligenceService _instance =
      SiteIntelligenceService._internal();
  factory SiteIntelligenceService() => _instance;
  SiteIntelligenceService._internal();

  static const _reliabilityKey = 'site_reliability_data';
  final Map<String, SiteReliability> _reliability = {};
  bool _loaded = false;
  bool _disposed = false;
  Timer? _persistTimer;
  bool _persistPending = false;
  // FIX-M4: Dirty counter for debouncing
  int _dirtyCount = 0;

  // FIX: Regex to detect any valid URL scheme (e.g. http, https, ftp, file).
  // Previously only http:// and https:// were checked, causing URLs with
  // other schemes to be mangled by prepending 'https://'.
  static final _urlSchemeRegex = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://');

  Future<void>? _initFuture;

  Future<void> init() async {
    if (_loaded) return;
    if (_initFuture != null) return _initFuture!;
    _initFuture = _doInit();
    await _initFuture;
    _initFuture = null;
  }

  Future<void> _doInit() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_reliabilityKey);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final map = Map<String, dynamic>.from(decoded);
          map.forEach((k, v) {
            if (v is Map) {
              _reliability[k] =
                  SiteReliability.fromJson(Map<String, dynamic>.from(v));
            }
          });
        }
      }
    } catch (e) {
      _log.warning('Failed to load reliability data: $e');
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    if (_disposed) return;
    _dirtyCount++;
    // FIX-M4: Flush immediately if dirty count >= 5
    if (_dirtyCount >= 5) {
      await flushPending();
      return;
    }
    if (_persistPending) return;
    _persistPending = true;
    _persistTimer?.cancel();
    // FIX-M4: 30s debounce delay
    _persistTimer = Timer(const Duration(seconds: 30), () async {
      _persistPending = false;
      if (_disposed) return;
      await flushPending();
    });
  }

  Future<void> dispose() async {
    _disposed = true;
    _persistTimer?.cancel();
    _persistTimer = null;
    await flushPending();
  }

  Future<void> flushPending() async {
    _persistTimer?.cancel();
    _persistPending = false;
    _dirtyCount = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw =
          jsonEncode(_reliability.map((k, v) => MapEntry(k, v.toJson())));
      await prefs.setString(_reliabilityKey, raw);
    } catch (e) {
      _log.warning('Failed to flush reliability data: $e');
    }
  }

  UrlAnalysisResult analyzeUrl(String url) {
    if (_disposed) return _fallbackResult();
    final cleanUrl = url.trim();
    if (cleanUrl.isEmpty) return _fallbackResult();
    if (cleanUrl.startsWith('magnet:')) {
      final magnet = analyzeMagnet(cleanUrl);
      return UrlAnalysisResult(
        siteType: SiteType.magnetSource,
        contentHint: magnet.contentHint,
        recommendedStrategy: DownloadStrategy.magnetDht,
        inferredCategory: magnet.inferredCategory,
        detectedFileName: magnet.displayName,
        confidence: 1.0,
      );
    }
    // FIX: Check for any URL scheme, not just http/https. This prevents
    // mangling URLs with other valid schemes (e.g. ftp://, file://).
    final hasScheme = _urlSchemeRegex.hasMatch(cleanUrl);
    final uri = Uri.tryParse(hasScheme ? cleanUrl : 'https://$cleanUrl');
    if (uri == null) return _fallbackResult();
    final host = uri.host.toLowerCase();

    SiteProfile? profile;
    String? matchedDomain;
    final parts = host.split('.');
    for (int i = 0; i < parts.length - 1; i++) {
      final candidate = parts.sublist(i).join('.');
      if (SiteRegistry.registry.containsKey(candidate)) {
        profile = SiteRegistry.registry[candidate];
        matchedDomain = candidate;
        _log.fine('Matched site profile for domain: $matchedDomain');
        break;
      }
    }

    String? fileName = p.basename(uri.path);
    if (fileName == '/' || fileName.isEmpty) fileName = null;
    final String? extension = fileName != null ? p.extension(fileName) : null;

    String? quality;
    final qualityMatch = UrlPatterns.qualityRegex.firstMatch(cleanUrl);
    if (qualityMatch != null) {
      quality = qualityMatch.group(0);
    }

    bool urlsExpire = profile?.urlsExpire ?? false;
    final hasExpiryParam = uri.queryParameters.entries.any((entry) =>
        UrlPatterns.isExpiryOrSignatureParam(entry.key, entry.value));
    if (hasExpiryParam) urlsExpire = true;

    SiteType siteType = profile?.type ?? SiteType.genericWebpage;
    ContentHint contentHint = profile?.contentHint ?? ContentHint.unknown;
    final DownloadStrategy strategy =
        profile?.strategy ?? DownloadStrategy.directHttp;
    double confidence = profile != null ? 0.9 : 0.4;

    if (profile == null) {
      if (extension != null && extension.isNotEmpty) {
        siteType = SiteType.genericDirect;
        confidence = 0.7;
        if (UrlPatterns.videoExtensions.contains(extension)) {
          contentHint = ContentHint.videoFile;
        } else if (UrlPatterns.audioExtensions.contains(extension)) {
          contentHint = ContentHint.audioFile;
        } else if (UrlPatterns.archiveExtensions.contains(extension)) {
          contentHint = ContentHint.archiveFile;
        } else if (UrlPatterns.softwareExtensions.contains(extension)) {
          contentHint = ContentHint.softwarePackage;
        } else if (UrlPatterns.documentExtensions.contains(extension)) {
          contentHint = ContentHint.document;
        } else if (UrlPatterns.imageExtensions.contains(extension)) {
          contentHint = ContentHint.image;
        }
      }
    }

    final headers = <String, String>{};
    if (profile != null) {
      headers.addAll(profile.extraHeaders);
      if (profile.requiresReferer) {
        headers['Referer'] =
            profile.refererValue ?? '${uri.scheme}://${uri.host}/';
      }
    }

    final category = resolveCategory(
      url: cleanUrl,
      fileName: fileName,
      siteType: siteType,
      contentHint: contentHint,
    );

    return UrlAnalysisResult(
      siteType: siteType,
      profile: profile,
      contentHint: contentHint,
      recommendedStrategy: strategy,
      detectedFileName: fileName,
      detectedExtension: extension,
      detectedQuality: quality,
      isExpiredOrSigned: urlsExpire,
      recommendedHeaders: headers,
      inferredCategory: category,
      confidence: confidence,
    );
  }

  MagnetAnalysis analyzeMagnet(String url) {
    final hashMatch = UrlPatterns.magnetHashRegex.firstMatch(url);
    final nameMatch = UrlPatterns.magnetNameRegex.firstMatch(url);
    final trackerMatches = UrlPatterns.magnetTrackerRegex.allMatches(url);

    final infoHash = hashMatch?.group(1);
    final String? name =
        nameMatch != null ? Uri.decodeComponent(nameMatch.group(1)!) : null;
    final trackers =
        trackerMatches.map((m) => Uri.decodeComponent(m.group(1)!)).toList();

    MagnetQuality quality = MagnetQuality.poor;
    if (trackers.length >= 5) {
      quality = MagnetQuality.excellent;
    } else if (trackers.length >= 3) {
      quality = MagnetQuality.good;
    } else if (trackers.isNotEmpty) {
      quality = MagnetQuality.fair;
    }

    ContentHint contentHint = ContentHint.unknown;
    String? inferredQuality;
    bool isVideo = false;
    bool isAudio = false;
    bool isSoftware = false;
    final keywords = <String>{};

    if (name != null) {
      final lowerName = name.toLowerCase();

      final qMatch = UrlPatterns.qualityRegex.firstMatch(name);
      if (qMatch != null) {
        inferredQuality = qMatch.group(0);
        keywords.add(qMatch.group(0)!);
      }

      final codecMatch = UrlPatterns.videoCodecRegex.firstMatch(lowerName);
      if (codecMatch != null) {
        keywords.add(codecMatch.group(0)!);
      }

      final audioCodecMatch = UrlPatterns.audioCodecRegex.firstMatch(lowerName);
      if (audioCodecMatch != null) {
        keywords.add(audioCodecMatch.group(0)!);
      }

      final sourceMatch = UrlPatterns.sourceRegex.firstMatch(lowerName);
      if (sourceMatch != null) {
        keywords.add(sourceMatch.group(0)!);
      }

      final releaseMatch = UrlPatterns.releaseGroupRegex.firstMatch(name);
      if (releaseMatch != null && releaseMatch.group(1) != null) {
        keywords.add(releaseMatch.group(1)!);
      }

      final yearMatch = UrlPatterns.yearRegex.firstMatch(name);
      if (yearMatch != null) {
        keywords.add(yearMatch.group(0)!);
      }

      if (UrlPatterns.videoCodecRegex.hasMatch(lowerName) ||
          UrlPatterns.sourceRegex.hasMatch(lowerName) ||
          UrlPatterns.videoExtensions.any((ext) => lowerName.contains(ext))) {
        contentHint = ContentHint.videoFile;
        isVideo = true;
      } else if (UrlPatterns.audioCodecRegex.hasMatch(lowerName) ||
          UrlPatterns.audioExtensions.any((ext) => lowerName.contains(ext))) {
        contentHint = ContentHint.audioFile;
        isAudio = true;
      } else if (UrlPatterns.softwareExtensions
              .any((ext) => lowerName.contains(ext)) ||
          lowerName.contains('repack') ||
          lowerName.contains('crack')) {
        contentHint = ContentHint.softwarePackage;
        isSoftware = true;
      }
    }

    final category = resolveCategory(
      url: url,
      siteType: SiteType.magnetSource,
      contentHint: contentHint,
      magnetName: name,
    );

    return MagnetAnalysis(
      displayName: name,
      infoHash: infoHash,
      trackers: trackers,
      trackerCount: trackers.length,
      quality: quality,
      contentHint: contentHint,
      inferredCategory: category,
      inferredQuality: inferredQuality,
      isVideoContent: isVideo,
      isAudioContent: isAudio,
      isSoftware: isSoftware,
      contentKeywords: keywords.toList(),
    );
  }

  String resolveCategory({
    required String url,
    String? fileName,
    SiteType? siteType,
    ContentHint? contentHint,
    String? magnetName,
  }) {
    if (contentHint != null) {
      switch (contentHint) {
        case ContentHint.videoFile:
        case ContentHint.videoStream:
          return 'Video';
        case ContentHint.audioFile:
        case ContentHint.audioStream:
          return 'Audio';
        case ContentHint.archiveFile:
          return 'Archive';
        case ContentHint.softwarePackage:
          return 'Software';
        case ContentHint.document:
          return 'Document';
        case ContentHint.image:
          return 'Image';
        default:
          break;
      }
    }
    if (siteType != null) {
      if (siteType == SiteType.videoStreaming) return 'Video';
      if (siteType == SiteType.audioStreaming) return 'Audio';
    }
    final searchArea =
        '${url.toLowerCase()} ${fileName?.toLowerCase() ?? ""} ${magnetName?.toLowerCase() ?? ""}';
    if (searchArea.contains('movie') ||
        searchArea.contains('season') ||
        searchArea.contains('episode') ||
        searchArea.contains('1080p') ||
        searchArea.contains('720p')) {
      return 'Video';
    }
    if (searchArea.contains('music') ||
        searchArea.contains('album') ||
        searchArea.contains('track') ||
        searchArea.contains('flac') ||
        searchArea.contains('mp3')) {
      return 'Audio';
    }
    if (searchArea.contains('setup') ||
        searchArea.contains('installer') ||
        searchArea.contains('.apk') ||
        searchArea.contains('.exe') ||
        searchArea.contains('.msi') ||
        searchArea.contains('.dmg') ||
        searchArea.contains('.deb') ||
        searchArea.contains('.rpm')) {
      return 'Software';
    }
    if (searchArea.contains('doc') ||
        searchArea.contains('pdf') ||
        searchArea.contains('ebook')) {
      return 'Document';
    }
    if (fileName != null) {
      final ext = p.extension(fileName).toLowerCase();
      if (UrlPatterns.videoExtensions.contains(ext)) return 'Video';
      if (UrlPatterns.audioExtensions.contains(ext)) return 'Audio';
      if (UrlPatterns.archiveExtensions.contains(ext)) return 'Archive';
      if (UrlPatterns.softwareExtensions.contains(ext)) return 'Software';
      if (UrlPatterns.documentExtensions.contains(ext)) return 'Document';
      if (UrlPatterns.imageExtensions.contains(ext)) return 'Image';
    }
    return 'Other';
  }

  void recordOutcome(
    String url,
    bool success, [
    double? speedMbps,
    String? errorMessage,
  ]) {
    if (_disposed) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return;
    final stat =
        _reliability.putIfAbsent(host, () => SiteReliability(domain: host));
    stat.totalAttempts++;
    if (success) {
      stat.successes++;
      stat.lastSuccess = DateTime.now();
      if (speedMbps != null && speedMbps > 0) {
        if (stat.averageSpeedMbps == 0) {
          stat.averageSpeedMbps = speedMbps;
        } else {
          stat.averageSpeedMbps =
              (stat.averageSpeedMbps * 0.8) + (speedMbps * 0.2);
        }
      }
    } else {
      stat.failures++;
      stat.lastFailure = DateTime.now();
      if (errorMessage != null && errorMessage.isNotEmpty) {
        stat.lastError = errorMessage;
      }
    }
    _persist();
  }

  SiteReliability? getReliability(String host) =>
      _reliability[host.toLowerCase()];

  UrlAnalysisResult _fallbackResult() => UrlAnalysisResult(
        siteType: SiteType.genericWebpage,
        contentHint: ContentHint.unknown,
        recommendedStrategy: DownloadStrategy.directHttp,
        inferredCategory: 'Other',
      );
}
