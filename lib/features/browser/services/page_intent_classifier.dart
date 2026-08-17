import 'dart:async';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/services/site_intelligence/site_intelligence_service.dart';
import 'ad_blocker_service.dart';
import 'browser_detector.dart';
import 'download_interceptor.dart';

/// نوع الصفحة المكتشف
enum PageIntent {
  /// صفحة تحميل مباشر (فيها زر/رابط تحميل ملف)
  directDownload,

  /// صفحة ماجنت / تورنت
  magnetPage,

  /// صفحة عادية (تصفح)
  normalBrowsing,

  /// صفحة إعلان / redirect إعلاني
  adPage,

  /// صفحة وسائط (فيديو/صوت قابل للتشغيل)
  mediaPage,

  /// صفحة تسجيل دخول / captcha
  authPage,

  /// صفحة ملف (PDF, ZIP, إلخ) أو صفحة تحميل
  filePage,
}

/// قرار المتصفح بناءً على التصنيف
enum PageAction {
  /// فتح في نفس التاب
  openSameTab,

  /// فتح في تاب جديد
  openNewTab,

  /// فتح في تاب جديد في الخلفية
  openBackgroundTab,

  /// بلوك كامل (إعلان)
  block,

  /// فتح في تاب جديد + اقتراح تحميل
  openNewTabWithDownloadSuggestion,

  /// تحميل مباشر بدون فتح صفحة
  directDownload,

  /// فتح في تاب جديد + تحذير
  openNewTabWithWarning,
}

/// نتيجة التصنيف الكاملة
class PageClassification {
  final PageIntent intent;
  final PageAction action;
  final String url;
  final double confidence; // 0.0 - 1.0
  final String? detectedFileName;
  final String? detectedMimeType;
  final int? detectedFileSize;
  final String? reason; // سبب التصنيف (للدبج)
  final DetectedMediaKind? mediaKind;

  const PageClassification({
    required this.intent,
    required this.action,
    required this.url,
    this.confidence = 0.5,
    this.detectedFileName,
    this.detectedMimeType,
    this.detectedFileSize,
    this.reason,
    this.mediaKind,
  });

  bool get isHighConfidence => confidence >= 0.8;
  bool get shouldBlock => action == PageAction.block;
  bool get shouldOpenNewTab =>
      action == PageAction.openNewTab ||
      action == PageAction.openBackgroundTab ||
      action == PageAction.openNewTabWithDownloadSuggestion ||
      action == PageAction.openNewTabWithWarning;

  @override
  String toString() =>
      'PageClassification(intent: ${intent.name}, action: ${action.name}, '
      'confidence: ${confidence.toStringAsFixed(2)}, reason: $reason)';
}

/// قواعد كشف صفحات الإعلانات
class _AdPageRule {
  final RegExp pattern;
  final double weight;
  const _AdPageRule(this.pattern, this.weight);
}

/// المصنف الذكي للصفحات
class PageIntentClassifier {
  static final _log = Logger('PageIntentClassifier');

  PageIntentClassifier._();
  static final PageIntentClassifier instance = PageIntentClassifier._();

  static const _prefKey = 'page_classifier_enabled';
  static const _adDomainsKey = 'known_ad_domains';

  bool _enabled = true;
  final Set<String> _knownAdDomains = {};
  final SiteIntelligenceService _intelligence = SiteIntelligenceService();

  static final List<_AdPageRule> _adPagePatterns = [
    _AdPageRule(
      RegExp(
        r'(doubleclick\.net|googlesyndication\.com|googleadservices\.com|'
        r'adnxs\.com|adsrvr\.org|criteo\.com|criteo\.net|'
        r'taboola\.com|outbrain\.com|revcontent\.com|mgid\.com|'
        r'popads\.net|popcash\.net|exoclick\.com|exosrv\.com|'
        r'juicyads\.com|trafficjunky\.com|hilltopads\.net|'
        r'clickadu\.com|adsterra\.com|propellerads\.com|'
        r'onclickads\.net|onclickmax\.com|onclickmega\.com|'
        r'pushails\.com|onesignal\.com|pushengage\.com|'
        r'adform\.net|adcolony\.com|admob\.com|'
        r'bidswitch\.net|buysellads\.com|carbonads\.com|'
        r'casalemedia\.com|chartbeat\.com|dianomi\.com|'
        r'directrev\.com|dotomi\.com|hotjar\.com|infolinks\.com|'
        r'leadzu\.com|media\.net|mediavine\.com|moatads\.com|'
        r'mookie1\.com|openx\.net|pubmatic\.com|quantserve\.com|'
        r'revenuehits\.com|revive-adserver\.com|rubiconproject\.com|'
        r'serving-sys\.com|sharethis\.com|smartadserver\.com|'
        r'tapad\.com|trckswrm\.com|tribalfusion\.com|turn\.com|'
        r'undertone\.com|viglink\.com|xad\.com|yieldmo\.com|zedo\.com)',
        caseSensitive: false,
      ),
      1.0,
    ),
    _AdPageRule(
      RegExp(
        r'(\/ads?\/|\/advert|\/banner|\/sponsor|\/promo\/|'
        r'\/click\?|\/redirect\?ad|\/ad_click|\/adclick|'
        r'\/track\?|\/tracking\/|\/pixel\?|\/beacon\?)',
        caseSensitive: false,
      ),
      0.7,
    ),
    _AdPageRule(
      RegExp(
        r'(popup|popunder|interstitial|overlay[-_]?ad|'
        r'floating[-_]?ad|sticky[-_]?ad|splash[-_]?ad|'
        r'welcome[-_]?ad|exit[-_]?intent|exit[-_]?popup)',
        caseSensitive: false,
      ),
      0.8,
    ),
    _AdPageRule(
      RegExp(
        r'^(ad|ads|adserver|adserv|advert|banner|promo|sponsor|'
        r'tracking|analytics|pixel|beacon|click|redirect)\.',
        caseSensitive: false,
      ),
      0.9,
    ),
    _AdPageRule(
      RegExp(
        r'(\/lp\/|\/landing\?|\/campaign\/|\/promo-code|'
        r'\/special-offer|\/limited-time|\/deal\?|'
        r'utm_source=.*utm_medium=(cpc|cpm|banner|display))',
        caseSensitive: false,
      ),
      0.6,
    ),
  ];

  // static final List<RegExp> _downloadPagePatterns = [
  //   RegExp(
  //     r'(\/download|\/downloads|\/dl\/|\/get\/|\/fetch\/|'
  //     r'\/file\/|\/files\/|\/attachment|\/getfile|'
  //     r'\/save\/|\/export\/|\/retrieve)',
  //     caseSensitive: false,
  //   ),
  //   RegExp(
  //     r'(download[_-]?(page|button|link|now|here|file)|'
  //     r'click[_-]?to[_-]?download|free[_-]?download|'
  //     r'start[_-]?download|direct[_-]?download)',
  //     caseSensitive: false,
  //   ),
  //   ];

  static final List<RegExp> _mediaPagePatterns = [
    RegExp(
      r'(\/watch\?|\/video\/|\/videos\/|\/embed\/|\/player\/|'
      r'\/stream\/|\/live\/|\/clip\/|\/shorts\/|'
      r'\/playlist\?|\/channel\/|\/c\/)',
      caseSensitive: false,
    ),
  ];

  static final List<RegExp> _authPagePatterns = [
    RegExp(
      r'(\/login|\/signin|\/sign-in|\/auth|\/oauth|\/sso|'
      r'\/captcha|\/verify|\/2fa|\/mfa|\/recaptcha|'
      r'accounts\.google\.com|login\.|signin\.)',
      caseSensitive: false,
    ),
  ];

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefKey) ?? true;

      final adDomains = prefs.getStringList(_adDomainsKey);
      if (adDomains != null) {
        _knownAdDomains.addAll(adDomains);
      }
    } catch (e) {
      _log.warning('Failed to init PageIntentClassifier: $e');
    }
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, value);
    } catch (e) {
      _log.warning('Failed to save classifier state: $e');
    }
  }

  bool get isEnabled => _enabled;

  Future<void> addKnownAdDomain(String domain) async {
    _knownAdDomains.add(domain.toLowerCase());
    await _persistAdDomains();
  }

  Future<void> _persistAdDomains() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_adDomainsKey, _knownAdDomains.toList());
    } catch (e) {
      _log.warning('Failed to persist ad domains: $e');
    }
  }

  static const Set<String> allowedSchemes = {'http', 'https', 'magnet'};

  /// Checks if URL uses a safe and whitelisted scheme (SEC-03).
  static bool isAllowedScheme(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) return false;
    return allowedSchemes.contains(uri.scheme.toLowerCase());
  }

  PageClassification classify(String url) {
    if (!_enabled) {
      return PageClassification(
        intent: PageIntent.normalBrowsing,
        action: PageAction.openSameTab,
        url: url,
        confidence: 1.0,
        reason: 'Classifier disabled',
      );
    }

    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return PageClassification(
        intent: PageIntent.normalBrowsing,
        action: PageAction.openSameTab,
        url: url,
        confidence: 1.0,
        reason: 'Empty URL',
      );
    }

    // Scheme validation & whitelist guard (SEC-03)
    final uri = Uri.tryParse(trimmed);
    if (uri != null &&
        uri.hasScheme &&
        !allowedSchemes.contains(uri.scheme.toLowerCase())) {
      return PageClassification(
        intent: PageIntent.adPage,
        action: PageAction.block,
        url: url,
        confidence: 1.0,
        reason: 'Blocked dangerous or unsupported URL scheme: ${uri.scheme}',
      );
    }

    // 1. Magnet links → openNewTabWithDownloadSuggestion
    if (trimmed.startsWith('magnet:')) {
      return _classifyMagnet(trimmed);
    }

    // 2. Streaming media pages (YouTube, Vimeo, etc.) → openSameTab
    final mediaClassification = _classifyMediaPage(trimmed);
    if (mediaClassification != null) return mediaClassification;

    // 3. Direct files (.torrent, .zip, .pdf, .exe, etc.)
    final fileDetection = _classifyDirectFile(trimmed);
    if (fileDetection != null) return fileDetection;

    // 4. Ad page matching
    final adClassification = _classifyAdPage(trimmed);
    if (adClassification != null) return adClassification;

    // 5. Auth pages
    if (_isAuthPage(trimmed)) {
      return PageClassification(
        intent: PageIntent.authPage,
        action: PageAction.openSameTab,
        url: url,
        confidence: 0.9,
        reason: 'Authentication/login page detected',
      );
    }

    // 6. Download pages / File hosting (disabled pre-request guessing to prevent false positives)
    // final downloadClassification = _classifyDownloadPage(trimmed);
    // if (downloadClassification != null) return downloadClassification;

    // 7. Site Intelligence analysis
    final analysis = _intelligence.analyzeUrl(trimmed);
    if (analysis.profile != null) {
      return _classifyFromSiteProfile(trimmed, analysis);
    }

    // 8. Default: normal browsing
    return PageClassification(
      intent: PageIntent.normalBrowsing,
      action: PageAction.openSameTab,
      url: url,
      confidence: 0.5,
      reason: 'No specific pattern matched',
    );
  }

  PageClassification classifyWithContext({
    required String currentUrl,
    required String targetUrl,
    bool isUserInitiated = true,
    bool isFromClick = false,
  }) {
    final currentHost = Uri.tryParse(currentUrl)?.host.toLowerCase() ?? '';
    final targetHost = Uri.tryParse(targetUrl)?.host.toLowerCase() ?? '';
    final isSameOrigin = currentHost.isNotEmpty && currentHost == targetHost;

    if (isUserInitiated && isFromClick) {
      if (isSameOrigin) {
        return PageClassification(
          intent: PageIntent.normalBrowsing,
          action: PageAction.openSameTab,
          url: targetUrl,
          confidence: 0.9,
          reason: 'User click on same-origin navigation',
        );
      }
      final classification = classify(targetUrl);
      if (classification.intent == PageIntent.adPage) {
        final lowerTarget = targetUrl.toLowerCase();
        final isAdBlocked = AdBlockerService.instance.shouldBlockUrl(targetUrl);
        final isFileHost = lowerTarget.contains('dlhaven') ||
            lowerTarget.contains('mediafire') ||
            lowerTarget.contains('pixeldrain') ||
            lowerTarget.contains('gofile') ||
            lowerTarget.contains('mega.nz');

        if (!isAdBlocked &&
            (isFileHost || BrowserDetector.isAutoDownloadable(targetUrl))) {
          return PageClassification(
            intent: PageIntent.normalBrowsing,
            action: PageAction.openSameTab,
            url: targetUrl,
            confidence: 0.8,
            reason: 'User clicked legitimate download/file host link',
          );
        }
        return PageClassification(
          intent: classification.intent,
          action: PageAction.openNewTabWithWarning,
          url: targetUrl,
          confidence: classification.confidence * 0.7,
          reason: 'User-initiated but classified as ad',
          mediaKind: classification.mediaKind,
        );
      }
      return classification;
    }

    final targetClassification = classify(targetUrl);
    final currentClassification = classify(currentUrl);

    if (currentClassification.intent == PageIntent.filePage &&
        (targetClassification.intent == PageIntent.filePage ||
            targetClassification.intent == PageIntent.directDownload)) {
      return PageClassification(
        intent: PageIntent.directDownload,
        action: PageAction.directDownload,
        url: targetUrl,
        confidence: 0.9,
        detectedFileName: targetClassification.detectedFileName,
        detectedMimeType: targetClassification.detectedMimeType,
        reason: 'Download page redirected to file',
      );
    }

    if (targetClassification.intent == PageIntent.adPage &&
        currentClassification.intent != PageIntent.adPage) {
      return targetClassification;
    }

    return targetClassification;
  }

  Future<PageClassification> classifyWithContextAsync({
    required String currentUrl,
    required String targetUrl,
    required DownloadInterceptor interceptor,
    bool isUserInitiated = true,
    bool isFromClick = false,
  }) async {
    final directCheck = await classifyDirectFileAsync(
      targetUrl,
      interceptor: interceptor,
      referer: currentUrl,
    );
    if (directCheck != null) {
      return directCheck;
    }
    return classifyWithContext(
      currentUrl: currentUrl,
      targetUrl: targetUrl,
      isUserInitiated: isUserInitiated,
      isFromClick: isFromClick,
    );
  }

  PageClassification _classifyMagnet(String url) {
    final analysis = _intelligence.analyzeMagnet(url);
    return PageClassification(
      intent: PageIntent.magnetPage,
      action: PageAction.openNewTabWithDownloadSuggestion,
      url: url,
      confidence: 0.95,
      detectedFileName: analysis.displayName,
      reason:
          'Magnet link detected (${analysis.trackerCount} trackers, quality: ${analysis.quality.name})',
      mediaKind: DetectedMediaKind.magnet,
    );
  }

  PageClassification? _classifyDirectFile(String url) {
    final detected = BrowserDetector.detect(url);
    if (detected == null) return null;

    if (detected.kind == DetectedMediaKind.torrent) {
      return PageClassification(
        intent: PageIntent.magnetPage,
        action: PageAction.openNewTabWithDownloadSuggestion,
        url: url,
        confidence: 0.95,
        detectedFileName: detected.suggestedFileName,
        reason: 'Torrent file URL detected',
        mediaKind: DetectedMediaKind.torrent,
      );
    }

    if (detected.kind == DetectedMediaKind.archive ||
        detected.kind == DetectedMediaKind.executable) {
      // Heuristic synchronous classification (for high confidence path-based files)
      if (detected.confidence == DetectionConfidence.high) {
        return PageClassification(
          intent: PageIntent.directDownload,
          action: PageAction.directDownload,
          url: url,
          confidence: 0.9,
          detectedFileName: detected.suggestedFileName,
          reason: 'Direct file URL (${detected.kind.name}, path-based)',
          mediaKind: detected.kind,
        );
      }
      return PageClassification(
        intent: PageIntent.normalBrowsing,
        action: PageAction.openSameTab,
        url: url,
        confidence: 0.5,
        reason: 'Query-based file extension requires server verification',
      );
    }

    if (detected.kind == DetectedMediaKind.document) {
      return PageClassification(
        intent: PageIntent.filePage,
        action: PageAction.openNewTabWithDownloadSuggestion,
        url: url,
        confidence: 0.85,
        detectedFileName: detected.suggestedFileName,
        reason: 'Document file URL',
        mediaKind: detected.kind,
      );
    }

    if (detected.kind == DetectedMediaKind.video ||
        detected.kind == DetectedMediaKind.audio) {
      return PageClassification(
        intent: PageIntent.mediaPage,
        action: PageAction.openNewTabWithDownloadSuggestion,
        url: url,
        confidence: 0.85,
        detectedFileName: detected.suggestedFileName,
        reason: 'Media file URL (${detected.kind.name})',
        mediaKind: detected.kind,
      );
    }

    if (detected.kind == DetectedMediaKind.image) {
      return PageClassification(
        intent: PageIntent.normalBrowsing,
        action: PageAction.openNewTab,
        url: url,
        confidence: 0.8,
        detectedFileName: detected.suggestedFileName,
        reason: 'Image URL',
        mediaKind: detected.kind,
      );
    }

    return null;
  }

  Future<PageClassification?> classifyDirectFileAsync(
    String url, {
    required DownloadInterceptor interceptor,
    String? referer,
  }) async {
    final detected = BrowserDetector.detect(url);
    if (detected == null) return null;

    if (detected.kind == DetectedMediaKind.torrent) {
      return PageClassification(
        intent: PageIntent.magnetPage,
        action: PageAction.openNewTabWithDownloadSuggestion,
        url: url,
        confidence: 0.95,
        detectedFileName: detected.suggestedFileName,
        reason: 'Torrent file URL detected',
        mediaKind: DetectedMediaKind.torrent,
      );
    }

    if (detected.kind == DetectedMediaKind.archive ||
        detected.kind == DetectedMediaKind.executable) {
      final check = await interceptor.verifyContentType(url, referer: referer);
      if (!check.isInconclusive) {
        if (check.isBinaryDownload) {
          return PageClassification(
            intent: PageIntent.directDownload,
            action: PageAction.directDownload,
            url: check.finalUrl,
            confidence: 0.95,
            detectedFileName: detected.suggestedFileName,
            reason: 'Server verified direct file (${detected.kind.name})',
            mediaKind: detected.kind,
          );
        } else {
          // Server returned HTML -> navigate like normal page
          return PageClassification(
            intent: PageIntent.normalBrowsing,
            action: PageAction.openSameTab,
            url: url,
            confidence: 0.9,
            reason: 'Server returned HTML content for link',
          );
        }
      } else {
        // Inconclusive/timeout
        if (detected.confidence == DetectionConfidence.low) {
          return PageClassification(
            intent: PageIntent.normalBrowsing,
            action: PageAction.openSameTab,
            url: url,
            confidence: 0.5,
            reason:
                'Inconclusive server check for low confidence extension match',
          );
        } else {
          // Fallback to heuristic directDownload for HIGH confidence (path-based)
          return PageClassification(
            intent: PageIntent.directDownload,
            action: PageAction.directDownload,
            url: url,
            confidence: 0.9,
            detectedFileName: detected.suggestedFileName,
            reason:
                'Direct file URL (${detected.kind.name}, path-based fallback)',
            mediaKind: detected.kind,
          );
        }
      }
    }

    return _classifyDirectFile(url);
  }

  PageClassification? _classifyAdPage(String url) {
    final uri = Uri.tryParse(url.startsWith('http') ? url : 'https://$url');
    if (uri == null) return null;

    final host = uri.host.toLowerCase();
    double adScore = 0.0;
    final reasons = <String>[];

    if (_knownAdDomains.contains(host)) {
      adScore += 1.0;
      reasons.add('Known ad domain');
    }

    if (AdBlockerService.instance.shouldBlockUrl(url)) {
      adScore += 0.9;
      reasons.add('Blocked by AdBlocker');
    }

    for (final rule in _adPagePatterns) {
      if (rule.pattern.hasMatch(url)) {
        adScore += rule.weight;
        reasons.add('Pattern matched');
      }
    }

    if (host.startsWith('ad.') ||
        host.startsWith('ads.') ||
        host.startsWith('adserver.') ||
        host.startsWith('banner.') ||
        host.startsWith('promo.')) {
      adScore += 0.9;
      reasons.add('Ad subdomain');
    }

    if (adScore >= 0.7) {
      return PageClassification(
        intent: PageIntent.adPage,
        action: PageAction.block,
        url: url,
        confidence: adScore.clamp(0.0, 1.0),
        reason: 'Ad page detected: ${reasons.join(', ')}',
      );
    }

    if (adScore >= 0.4) {
      return PageClassification(
        intent: PageIntent.adPage,
        action: PageAction.openNewTabWithWarning,
        url: url,
        confidence: adScore.clamp(0.0, 1.0),
        reason: 'Possible ad page: ${reasons.join(', ')}',
      );
    }

    return null;
  }

  bool _isAuthPage(String url) {
    return _authPagePatterns.any((p) => p.hasMatch(url));
  }

  // PageClassification? _classifyDownloadPage(String url) {
  //   for (final pattern in _downloadPagePatterns) {
  //     if (pattern.hasMatch(url)) {
  //       return PageClassification(
  //         intent: PageIntent.filePage,
  //         action: PageAction.openSameTab,
  //         url: url,
  //         confidence: 0.75,
  //         reason: 'Download page pattern matched',
  //       );
  //     }
  //   }
  //
  //   final analysis = _intelligence.analyzeUrl(url);
  //   if (analysis.siteType == SiteType.fileHosting) {
  //     return PageClassification(
  //       intent: PageIntent.filePage,
  //       action: PageAction.openSameTab,
  //       url: url,
  //       confidence: 0.85,
  //       reason: 'File hosting site: ${analysis.profile?.displayName}',
  //     );
  //   }
  //
  //   return null;
  // }

  PageClassification? _classifyMediaPage(String url) {
    for (final pattern in _mediaPagePatterns) {
      if (pattern.hasMatch(url)) {
        return PageClassification(
          intent: PageIntent.mediaPage,
          action: PageAction.openSameTab,
          url: url,
          confidence: 0.8,
          reason: 'Media page pattern matched',
          mediaKind: DetectedMediaKind.video,
        );
      }
    }

    final analysis = _intelligence.analyzeUrl(url);
    if (analysis.siteType == SiteType.videoStreaming ||
        analysis.siteType == SiteType.audioStreaming) {
      return PageClassification(
        intent: PageIntent.mediaPage,
        action: PageAction.openSameTab,
        url: url,
        confidence: 0.9,
        reason: 'Streaming site: ${analysis.profile?.displayName}',
        mediaKind: analysis.siteType == SiteType.videoStreaming
            ? DetectedMediaKind.video
            : DetectedMediaKind.audio,
      );
    }

    return null;
  }

  PageClassification _classifyFromSiteProfile(
    String url,
    UrlAnalysisResult analysis,
  ) {
    final profile = analysis.profile!;

    switch (analysis.recommendedStrategy) {
      case DownloadStrategy.browserRequired:
        return PageClassification(
          intent: PageIntent.filePage,
          action: PageAction.openSameTab,
          url: url,
          confidence: 0.8,
          reason: 'Browser-required site: ${profile.displayName}',
        );

      case DownloadStrategy.magnetDht:
        return PageClassification(
          intent: PageIntent.magnetPage,
          action: PageAction.openNewTabWithDownloadSuggestion,
          url: url,
          confidence: 0.9,
          reason: 'Magnet/DHT site: ${profile.displayName}',
          mediaKind: DetectedMediaKind.magnet,
        );

      case DownloadStrategy.apiExtraction:
        return PageClassification(
          intent: PageIntent.mediaPage,
          action: PageAction.openSameTab,
          url: url,
          confidence: 0.85,
          reason: 'API extraction site: ${profile.displayName}',
          mediaKind: DetectedMediaKind.video,
        );

      case DownloadStrategy.redirectFollow:
        return PageClassification(
          intent: PageIntent.filePage,
          action: PageAction.openSameTab,
          url: url,
          confidence: 0.7,
          reason: 'Redirect-follow site: ${profile.displayName}',
        );

      default:
        return PageClassification(
          intent: PageIntent.normalBrowsing,
          action: PageAction.openSameTab,
          url: url,
          confidence: 0.6,
          reason: 'Known site: ${profile.displayName}',
        );
    }
  }
}
