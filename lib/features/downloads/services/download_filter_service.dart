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
        final matchesSearch = task.fileName.toLowerCase().contains(queryLower) ||
            task.url.toLowerCase().contains(queryLower);
        if (!matchesSearch) return false;
      }

      if (categoryFilters.isNotEmpty && !categoryFilters.contains(task.category)) {
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
          comparison = a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase());
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
      'Documents': 0,
      'Compressed': 0,
      'Video': 0,
      'Audio': 0,
      'Software': 0,
      'Other': 0,
      'Torrents': 0,
    };
    for (final task in tasks) {
      if (task.isTorrent) {
        counts['Torrents'] = (counts['Torrents'] ?? 0) + 1;
      }
      if (counts.containsKey(task.category)) {
        counts[task.category] = (counts[task.category] ?? 0) + 1;
      }
    }
    return counts;
  }

  Map<String, double> computeCategorySizes(List<DownloadTask> tasks) {
    final sizes = <String, double>{
      'Documents': 0.0,
      'Compressed': 0.0,
      'Video': 0.0,
      'Audio': 0.0,
      'Software': 0.0,
      'Other': 0.0,
    };
    for (final task in tasks) {
      if (!sizes.containsKey(task.category)) continue;
      if (task.status == DownloadStatus.failed || task.status == DownloadStatus.queued) continue;
      sizes[task.category] = (sizes[task.category] ?? 0.0) + task.fileSize / (1024 * 1024);
    }
    return sizes;
  }
}
