import '../models/download_task.dart';

/// Pure domain service providing deterministic filtering, sorting, and aggregation
/// operations on collections of [DownloadTask].
class DownloadFilterService {
  const DownloadFilterService();

  List<DownloadTask> filterAndSort({
    required List<DownloadTask> tasks,
    required String searchQuery,
    required String statusFilter,
    required Set<String> categoryFilters,
    required SortOption sortOption,
    required bool sortAscending,
  }) {
    final queryLower = searchQuery.toLowerCase().trim();

    final filtered = tasks.where((task) {
      if (queryLower.isNotEmpty) {
        final matchesSearch =
            task.fileName.toLowerCase().contains(queryLower) ||
                task.url.toLowerCase().contains(queryLower);
        if (!matchesSearch) return false;
      }

      if (categoryFilters.isNotEmpty &&
          !categoryFilters.contains(task.category)) {
        return false;
      }

      return switch (statusFilter) {
        'Downloading' => task.status == DownloadStatus.downloading ||
            task.status == DownloadStatus.queued ||
            (task.status == DownloadStatus.completed &&
                task.isTorrent &&
                task.seedingEnabled),
        'Completed' => task.status == DownloadStatus.completed &&
            !(task.isTorrent && task.seedingEnabled),
        'Failed' => task.status == DownloadStatus.failed,
        'Paused' => task.status == DownloadStatus.paused,
        'Scheduled' =>
          task.status == DownloadStatus.paused && task.scheduledAt != null,
        'Torrents' => task.isTorrent,
        _ => true,
      };
    }).toList();

    filtered.sort((a, b) {
      int comparison;
      switch (sortOption) {
        case SortOption.dateAdded:
          comparison = a.createdAt.compareTo(b.createdAt);
          break;
        case SortOption.fileSize:
          comparison = a.fileSize.compareTo(b.fileSize);
          break;
        case SortOption.fileName:
          comparison =
              a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase());
          break;
        case SortOption.status:
          comparison = a.status.name.compareTo(b.status.name);
          break;
        case SortOption.manual:
          comparison = a.queueOrder.compareTo(b.queueOrder);
          break;
      }
      return sortAscending ? comparison : -comparison;
    });

    return filtered;
  }

  Map<String, int> computeCategoryCounts(List<DownloadTask> tasks) {
    final counts = <String, int>{
      'All': tasks.length,
      'Video': 0,
      'Audio': 0,
      'Document': 0,
      'Documents': 0,
      'Archive': 0,
      'Compressed': 0,
      'APK': 0,
      'Software': 0,
      'Other': 0,
      'Torrents': 0,
    };
    for (final task in tasks) {
      if (task.isTorrent) {
        counts['Torrents'] = (counts['Torrents'] ?? 0) + 1;
      }
      final cat = task.category;
      if (counts.containsKey(cat)) {
        counts[cat] = (counts[cat] ?? 0) + 1;
      } else {
        counts['Other'] = (counts['Other'] ?? 0) + 1;
      }
    }
    return counts;
  }

  Map<String, double> computeCategorySizes(List<DownloadTask> tasks) {
    final sizes = <String, double>{
      'Video': 0.0,
      'Audio': 0.0,
      'Document': 0.0,
      'Documents': 0.0,
      'Archive': 0.0,
      'Compressed': 0.0,
      'APK': 0.0,
      'Software': 0.0,
      'Other': 0.0,
    };
    for (final task in tasks) {
      if (task.status == DownloadStatus.failed ||
          task.status == DownloadStatus.queued) {
        continue;
      }
      // FIX(M-1): Use downloadedBytes (actual disk usage) not fileSize.
      final sizeMb = task.downloadedBytes / (1024 * 1024);
      final cat = task.category;
      if (sizes.containsKey(cat)) {
        sizes[cat] = (sizes[cat] ?? 0.0) + sizeMb;
      } else {
        sizes['Other'] = (sizes['Other'] ?? 0.0) + sizeMb;
      }
    }
    return sizes;
  }
}
