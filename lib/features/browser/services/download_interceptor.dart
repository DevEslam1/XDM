import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:path/path.dart' as p;

import '../../../core/utils/file_utils.dart';
import '../../../core/utils/url_utils.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../models/browser_tab.dart';
import 'browser_detector.dart';
import 'media_sniffer.dart';

/// Result of content-type verification via HEAD/streamed GET.
class ContentCheckResult {
  final String finalUrl;
  final String contentType;
  final String contentDisposition;
  final bool isInconclusive;

  const ContentCheckResult({
    required this.finalUrl,
    required this.contentType,
    required this.contentDisposition,
    this.isInconclusive = false,
  });

  bool get isBinaryDownload {
    if (isInconclusive) return false;
    final lowerCd = contentDisposition.toLowerCase();
    final lowerCt = contentType.toLowerCase();
    if (lowerCd.contains('attachment')) return true;
    if (lowerCt.isEmpty ||
        lowerCt.contains('text/html') ||
        lowerCt.contains('text/plain')) {
      return false;
    }
    return lowerCt.contains('application/') ||
        lowerCt.contains('video/') ||
        lowerCt.contains('audio/') ||
        lowerCt.contains('image/');
  }
}

/// Outcome of [DownloadInterceptor.startDirectDownload].
enum InterceptDownloadStatus {
  /// A task with the same URL already finished.
  alreadyCompleted,

  /// A task with the same URL is downloading or queued.
  alreadyInProgress,

  /// A paused/failed task with the same URL was resumed instead.
  resumed,

  /// A new task was queued successfully.
  queued,

  /// Queuing failed — see [InterceptDownloadResult.errorMessage].
  failed,

  /// Nothing happened (no active tab available).
  skipped,
}

class InterceptDownloadResult {
  const InterceptDownloadResult(this.status, [this.errorMessage]);
  final InterceptDownloadStatus status;
  final String? errorMessage;
}

/// Decides when a navigation is a download and hands it off to
/// [DownloadProvider] (REFACTOR B extraction from `_BrowserScreenState`).
///
/// UI (interception sheet, snackbars) stays on the screen; this class owns
/// the sniff-bypass set, the intercept decision, and the enqueue logic
/// (dedup, filename numbering, category resolution).
class DownloadInterceptor {
  DownloadInterceptor({
    required this.resolveDownloadProvider,
    required this.resolveActiveTab,
  });

  /// Lazily resolves the download provider (Provider lookup on the screen).
  final DownloadProvider Function() resolveDownloadProvider;

  /// Returns the active tab, or null when none is available.
  final BrowserTab? Function() resolveActiveTab;

  /// URLs the user chose to keep browsing instead of downloading.
  final LinkedHashSet<String> _bypassedSniffUrls = LinkedHashSet<String>();

  final List<Map<String, String>> _interceptedList = [];
  List<Map<String, String>> get interceptedList =>
      List.unmodifiable(_interceptedList);
  int get interceptedCount => _interceptedList.length;

  void recordIntercepted(String url, String fileName) {
    _interceptedList.add({
      'url': url,
      'fileName': fileName,
      'time': DateTime.now().toIso8601String(),
    });
    if (_interceptedList.length > 100) {
      _interceptedList.removeAt(0);
    }
  }

  void clearIntercepted() {
    _interceptedList.clear();
  }

  String _normalizeBypassKey(String url) {
    try {
      final uri = Uri.parse(url);
      return '${uri.scheme}://${uri.host}${uri.path}';
    } catch (e, st) {
      LoggingService.logger('DownloadInterceptor')
          .warning('Operation failed with fallback', e, st);
      return url.split('?').first.split('#').first;
    }
  }

  /// Marks [url] so its next navigation is allowed through untouched.
  void addBypass(String url) {
    _bypassedSniffUrls.add(url);
    _bypassedSniffUrls.add(_normalizeBypassKey(url));
    if (_bypassedSniffUrls.length > 200) {
      _bypassedSniffUrls.remove(_bypassedSniffUrls.first);
    }
  }

  /// One-shot check: returns true (and clears the mark) if [url] or domain+path was bypassed.
  bool consumeBypass(String url) {
    final key = _normalizeBypassKey(url);
    final exact = _bypassedSniffUrls.remove(url);
    final normalized = _bypassedSniffUrls.remove(key);
    return exact || normalized;
  }

  // Shared Dio instance — reusing connections across content checks
  // avoids the overhead of creating a new HttpClient per call.
  late final Dio _sharedDio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 4),
    receiveTimeout: const Duration(seconds: 4),
    followRedirects: true,
    maxRedirects: 10,
    validateStatus: (s) => true,
  ));

  /// Reusable HEAD-then-streamed-GET verification logic.
  Future<ContentCheckResult> verifyContentType(
    String url, {
    String? referer,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    try {
      final origin = Uri.tryParse(referer ?? '')?.origin ?? '';
      final headers = <String, String>{
        'User-Agent': 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        if (referer != null && referer.isNotEmpty) 'Referer': referer,
        if (origin.isNotEmpty) 'Origin': origin,
      };

      final dio = _sharedDio;

      String finalUrl = url;
      String contentType = '';
      String contentDisposition = '';

      try {
        final response = await dio.head<void>(
          url,
          options: Options(
            responseType: ResponseType.bytes,
            headers: headers,
          ),
        );
        if (response.statusCode != null && response.statusCode! < 400) {
          finalUrl = response.realUri.toString().isNotEmpty
              ? response.realUri.toString()
              : (response.redirects.isNotEmpty
                  ? response.redirects.last.location.toString()
                  : url);
          contentType =
              (response.headers.value('content-type') ?? '').toLowerCase();
          contentDisposition =
              (response.headers.value('content-disposition') ?? '')
                  .toLowerCase();
        }
      } catch (e, st) {
        LoggingService.logger('DownloadInterceptor')
            .warning('Operation failed', e, st);
      }

      if (contentType.isEmpty || contentType.contains('text/html')) {
        try {
          final response = await dio.get<ResponseBody>(
            url,
            options: Options(
              responseType: ResponseType.stream,
              headers: headers,
            ),
          );
          finalUrl = response.realUri.toString().isNotEmpty
              ? response.realUri.toString()
              : (response.redirects.isNotEmpty
                  ? response.redirects.last.location.toString()
                  : url);
          contentType =
              (response.headers.value('content-type') ?? '').toLowerCase();
          contentDisposition =
              (response.headers.value('content-disposition') ?? '')
                  .toLowerCase();

          await response.data?.stream.drain<void>().catchError((_) {});
        } catch (e, st) {
          LoggingService.logger('DownloadInterceptor')
              .warning('Operation failed', e, st);
        }
      }

      if (contentType.isEmpty && contentDisposition.isEmpty) {
        return ContentCheckResult(
          finalUrl: url,
          contentType: '',
          contentDisposition: '',
          isInconclusive: true,
        );
      }

      return ContentCheckResult(
        finalUrl: finalUrl,
        contentType: contentType,
        contentDisposition: contentDisposition,
        isInconclusive: false,
      );
    } catch (_) {
      return ContentCheckResult(
        finalUrl: url,
        contentType: '',
        contentDisposition: '',
        isInconclusive: true,
      );
    }
  }

  void dispose() {
    _bypassedSniffUrls.clear();
    _interceptedList.clear();
    _sharedDio.close(force: true);
  }

  /// Whether a navigation from a page at [tabUrl] to [requestUrl] should be
  /// intercepted as a download.
  bool shouldIntercept({required String tabUrl, required String requestUrl}) =>
      !MediaSniffer.isYoutubeHost(tabUrl) &&
      BrowserDetector.isAutoDownloadable(requestUrl);

  String? parseFilenameFromContentDispositionString(String value) {
    if (value.isEmpty) return null;
    final utf8Match = RegExp(
      r"filename\*=(?:UTF-8|ISO-8859-1)''([^;\s]+)",
      caseSensitive: false,
    ).firstMatch(value);
    if (utf8Match != null) {
      try {
        return safeFileName(Uri.decodeComponent(utf8Match.group(1)!));
      } catch (e, st) {
        LoggingService.logger('DownloadInterceptor')
            .warning('Operation failed with fallback', e, st);
        return safeFileName(utf8Match.group(1)!);
      }
    }

    final quotedMatch = RegExp(
      r'filename="([^"]+)"|filename=([^";\s]+)',
      caseSensitive: false,
    ).firstMatch(value);
    if (quotedMatch != null) {
      final name = quotedMatch.group(1) ?? quotedMatch.group(2);
      if (name != null) return safeFileName(name.trim());
    }
    return null;
  }

  final Set<String> _pendingInterceptions = {};

  Future<InterceptDownloadResult> startDirectDownload(
    String url, {
    String? suggestedName,
    String? type,
    String? downloadPageUrl,
    String? audioUrl,
    int? videoSize,
    int? audioSize,
    String? mimeType,
    int? contentLength,
    String? contentDisposition,
  }) async {
    // Debounce rapid interceptions for identical URLs
    if (_pendingInterceptions.contains(url)) {
      return const InterceptDownloadResult(
          InterceptDownloadStatus.alreadyInProgress);
    }
    _pendingInterceptions.add(url);
    Timer(const Duration(seconds: 2), () {
      _pendingInterceptions.remove(url);
    });

    final downloadProvider = resolveDownloadProvider();
    final existingTasks =
        downloadProvider.tasks.where((t) => t.url == url).toList();
    if (existingTasks.isNotEmpty) {
      final existingTask = existingTasks.first;
      if (existingTask.status == DownloadStatus.completed) {
        return const InterceptDownloadResult(
          InterceptDownloadStatus.alreadyCompleted,
        );
      } else if (existingTask.status == DownloadStatus.downloading ||
          existingTask.status == DownloadStatus.queued) {
        return const InterceptDownloadResult(
          InterceptDownloadStatus.alreadyInProgress,
        );
      } else {
        downloadProvider.resumeTask(existingTask.id);
        return const InterceptDownloadResult(InterceptDownloadStatus.resumed);
      }
    }
    String finalFileName = suggestedName ?? '';
    if (finalFileName.isEmpty) {
      if (contentDisposition != null && contentDisposition.isNotEmpty) {
        finalFileName =
            parseFilenameFromContentDispositionString(contentDisposition) ?? '';
      }
      if (finalFileName.isEmpty) {
        if (url.startsWith('magnet:')) {
          final parsed = parseMagnetUrl(url);
          finalFileName = parsed['name'] ?? 'Torrent download';
        } else {
          finalFileName = fileNameFromUrl(url);
        }
      }
    }
    String numberedName = finalFileName;
    final ext = p.extension(finalFileName);
    final base = p.basenameWithoutExtension(finalFileName);
    var counter = 1;
    final existingNames =
        downloadProvider.tasks.map((t) => t.fileName.toLowerCase()).toSet();
    while (existingNames.contains(numberedName.toLowerCase())) {
      numberedName = '${base}_$counter$ext';
      counter++;
    }
    finalFileName = numberedName;
    String resolvedCategory = '';
    if (type == 'video' ||
        (mimeType != null && mimeType.startsWith('video/'))) {
      resolvedCategory = 'Video';
    } else if (type == 'audio' ||
        (mimeType != null && mimeType.startsWith('audio/'))) {
      resolvedCategory = 'Audio';
    } else if (type == 'image' ||
        (mimeType != null && mimeType.startsWith('image/'))) {
      resolvedCategory = 'Image';
    } else {
      if (mimeType != null) {
        final kind = BrowserDetector.detectFromContentType(mimeType);
        if (kind != null) {
          resolvedCategory = switch (kind) {
            DetectedMediaKind.video => 'Video',
            DetectedMediaKind.audio => 'Audio',
            DetectedMediaKind.image => 'Image',
            DetectedMediaKind.document => 'Document',
            DetectedMediaKind.archive => 'Archive',
            DetectedMediaKind.executable => 'Executable',
            DetectedMediaKind.torrent => 'Torrent',
            _ => '',
          };
        }
      }
      if (resolvedCategory.isEmpty) {
        resolvedCategory =
            resolveCategorySmart(url: url, fileName: finalFileName);
      }
    }
    try {
      final activeTab = resolveActiveTab();
      if (activeTab == null) {
        return const InterceptDownloadResult(InterceptDownloadStatus.skipped);
      }
      final resolvedOriginUrl =
          downloadPageUrl ?? (activeTab.isHome ? null : activeTab.url);
      await downloadProvider.addDownload(
        name: finalFileName,
        url: url,
        size: videoSize ?? contentLength ?? 0,
        category: resolvedCategory,
        savePath: '',
        downloadPageUrl: resolvedOriginUrl,
        mergedAudioUrl: audioUrl,
        audioSize: audioSize ?? 0,
      );
      if (downloadProvider.lastError != null) {
        return InterceptDownloadResult(
          InterceptDownloadStatus.failed,
          downloadProvider.lastError,
        );
      }
      return const InterceptDownloadResult(InterceptDownloadStatus.queued);
    } catch (e) {
      return InterceptDownloadResult(
        InterceptDownloadStatus.failed,
        e.toString(),
      );
    }
  }

  /// Intercepts multiple URLs in batch mode.
  Future<void> interceptBatch(List<String> urls) async {
    final downloadProvider = resolveDownloadProvider();
    final tasks = <DownloadAddSpec>[];
    for (final url in urls) {
      final fileName = fileNameFromUrl(url);
      final category = resolveCategorySmart(url: url, fileName: fileName);
      tasks.add(DownloadAddSpec(
        name: fileName,
        url: url,
        size: 0,
        category: category,
        savePath: '',
      ));
    }
    await downloadProvider.addDownloadsBatch(tasks);
  }

  /// Queues a single download with priority integration.
  Future<void> queueDownload(String url,
      {int priority = 0, String? name}) async {
    final downloadProvider = resolveDownloadProvider();
    final fileName = name ?? fileNameFromUrl(url);
    final category = resolveCategorySmart(url: url, fileName: fileName);
    await downloadProvider.addDownload(
      name: fileName,
      url: url,
      size: 0,
      category: category,
      savePath: '',
    );
  }
}
