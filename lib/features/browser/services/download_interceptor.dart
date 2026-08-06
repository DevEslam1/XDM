import 'dart:collection';

import '../../../core/utils/file_utils.dart';
import '../../../core/utils/url_utils.dart';
import 'package:path/path.dart' as p;

import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../models/browser_tab.dart';
import 'browser_detector.dart';
import 'media_sniffer.dart';

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

  /// Marks [url] so its next navigation is allowed through untouched.
  void addBypass(String url) {
    _bypassedSniffUrls.add(url);
    if (_bypassedSniffUrls.length > 200) {
      _bypassedSniffUrls.remove(_bypassedSniffUrls.first);
    }
  }

  /// One-shot check: returns true (and clears the mark) if [url] was bypassed.
  bool consumeBypass(String url) => _bypassedSniffUrls.remove(url);

  void dispose() {
    _bypassedSniffUrls.clear();
    _interceptedList.clear();
  }

  /// Whether a navigation from a page at [tabUrl] to [requestUrl] should be
  /// intercepted as a download.
  bool shouldIntercept({required String tabUrl, required String requestUrl}) =>
      !MediaSniffer.isYoutubeHost(tabUrl) &&
      BrowserDetector.isAutoDownloadable(requestUrl);

  Future<InterceptDownloadResult> startDirectDownload(
    String url, {
    String? suggestedName,
    String? type,
    String? downloadPageUrl,
    String? audioUrl,
    int? videoSize,
    int? audioSize,
  }) async {
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
      if (url.startsWith('magnet:')) {
        final parsed = parseMagnetUrl(url);
        finalFileName = parsed['name'] ?? 'Torrent download';
      } else {
        finalFileName = fileNameFromUrl(url);
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
    if (type == 'video') {
      resolvedCategory = 'Video';
    } else if (type == 'audio') {
      resolvedCategory = 'Audio';
    } else if (type == 'image') {
      resolvedCategory = 'Image';
    } else {
      resolvedCategory = resolveCategorySmart(url: url, fileName: finalFileName);
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
        size: videoSize ?? 0,
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
}
