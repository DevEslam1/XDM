import '../../../../core/utils/file_utils.dart';
import '../../models/download_task.dart';

/// Mixin that encapsulates UI filtering, sorting, searching, category
/// management, and navigation state for the download list.
///
/// Requires the host class to expose:
///  - `List<DownloadTask> get providerTasks`
///  - `void notifyListeners()`
mixin DownloadFilterMixin {
  // ---------------------------------------------------------------------------
  // Abstract contract — must be provided by the host class
  // ---------------------------------------------------------------------------
  List<DownloadTask> get providerTasks;
  void notifyListeners();
  DownloadTask? findTaskById(String id);

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  SortOption _sortOption = SortOption.dateAdded;
  bool _sortAscending = false;

  String _searchQuery = '';
  String _statusFilter = 'All';
  final Set<String> _categoryFilters = {};
  int _activeTabIndex = 0;
  bool _isNavbarVisible = true;

  final Set<String> _selectedTaskIds =
      {}; // UI-9: Selection set for batch operations

  String? _browserUrlToLoad;

  List<DownloadTask>? _cachedFilteredTasks;
  bool _filteredTasksDirty = true;

  // ---------------------------------------------------------------------------
  // Getters
  // ---------------------------------------------------------------------------
  SortOption get sortOption => _sortOption;
  bool get sortAscending => _sortAscending;
  String get searchQuery => _searchQuery;
  String get statusFilter => _statusFilter;
  Set<String> get categoryFilters => _categoryFilters;
  String? get categoryFilter =>
      _categoryFilters.isEmpty ? null : _categoryFilters.first;
  int get activeTabIndex => _activeTabIndex;
  bool get isNavbarVisible => _isNavbarVisible;
  String? get browserUrlToLoad => _browserUrlToLoad;

  // UI-9: Multi-selection mode getters and mutators
  bool get isSelectionMode => _selectedTaskIds.isNotEmpty;
  Set<String> get selectedTaskIds => Set.unmodifiable(_selectedTaskIds);

  void toggleTaskSelection(String id) {
    if (_selectedTaskIds.contains(id)) {
      _selectedTaskIds.remove(id);
    } else {
      _selectedTaskIds.add(id);
    }
    notifyListeners();
  }

  void selectAllTasks({Iterable<String>? visibleTaskIds}) {
    _selectedTaskIds.clear();
    _selectedTaskIds.addAll(visibleTaskIds ?? filteredTasks.map((t) => t.id));
    notifyListeners();
  }

  void clearTaskSelection() {
    _selectedTaskIds.clear();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Dirty flag — usable by other mixins / host
  // ---------------------------------------------------------------------------
  bool get filteredTasksDirty => _filteredTasksDirty;
  set filteredTasksDirty(bool value) {
    _filteredTasksDirty = value;
  }

  // ---------------------------------------------------------------------------
  // Computed aggregates
  // ---------------------------------------------------------------------------
  double get currentDownloadSpeed {
    return providerTasks
        .where((task) => task.status == DownloadStatus.downloading)
        .fold(0.0, (sum, task) => sum + task.speed);
  }

  String get currentDownloadSpeedFormatted =>
      '${formatBytes(currentDownloadSpeed)}/s';

  int get downloadingTasksCount => providerTasks
      .where((task) => task.status == DownloadStatus.downloading)
      .length;

  /// Number of active downloads including seeding torrents.
  /// Used for background service and widget lifetime.
  int get activeOrSeedingCount => providerTasks
      .where((task) =>
          task.status == DownloadStatus.downloading ||
          (task.status == DownloadStatus.completed &&
              task.isTorrent &&
              task.seedingEnabled))
      .length;

  int get queuedTasksCount => providerTasks
      .where((task) => task.status == DownloadStatus.queued)
      .length;

  int get completedTasksCount => providerTasks
      .where((task) => task.status == DownloadStatus.completed)
      .length;

  int get failedTasksCount => providerTasks
      .where((task) => task.status == DownloadStatus.failed)
      .length;

  int get pausedTasksCount => providerTasks
      .where((task) => task.status == DownloadStatus.paused)
      .length;

  Map<String, int> get categoryCounts {
    final counts = _emptyCategoryCounts<int>(0);
    for (final task in providerTasks) {
      if (!counts.containsKey(task.category)) continue;
      counts[task.category] = (counts[task.category] ?? 0) + 1;
    }
    return counts;
  }

  Map<String, double> get categorySizes {
    final sizes = _emptyCategoryCounts<double>(0);
    for (final task in providerTasks) {
      if (!sizes.containsKey(task.category)) continue;
      if (task.status == DownloadStatus.failed) continue;
      if (task.status == DownloadStatus.queued) continue;
      sizes[task.category] =
          (sizes[task.category] ?? 0) + task.fileSize / (1024 * 1024);
    }
    return sizes;
  }

  // ---------------------------------------------------------------------------
  // Filtered & sorted task list (cached)
  // ---------------------------------------------------------------------------
  List<DownloadTask> get filteredTasks {
    if (!_filteredTasksDirty && _cachedFilteredTasks != null) {
      // Re-resolve live task objects from the cached filter/sort result.
      // _cachedFilteredTasks holds the stable (sorted/filtered) ID order;
      // findTaskById always returns the latest in-memory instance so progress
      // ticks are reflected without invalidating the expensive filter cache.
      return _cachedFilteredTasks!
          .map((t) => findTaskById(t.id))
          .whereType<DownloadTask>()
          .toList();
    }
    final list = providerTasks.where((task) {
      final queryLower = _searchQuery.toLowerCase();
      final matchesSearch = task.fileName.toLowerCase().contains(queryLower) ||
          task.url.toLowerCase().contains(queryLower);
      if (!matchesSearch) return false;

      if (_categoryFilters.isNotEmpty &&
          !_categoryFilters.contains(task.category)) {
        return false;
      }

      return switch (_statusFilter) {
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

    list.sort((a, b) {
      int comparison;
      switch (_sortOption) {
        case SortOption.dateAdded:
          comparison = a.createdAt.compareTo(b.createdAt);
          break;
        case SortOption.fileSize:
          comparison = a.fileSize.compareTo(b.fileSize);
          break;
        case SortOption.fileName:
          comparison = a.fileName.toLowerCase().compareTo(
                b.fileName.toLowerCase(),
              );
          break;
        case SortOption.status:
          comparison = a.status.name.compareTo(b.status.name);
          break;
        case SortOption.manual: // FIX(13)
          comparison = a.queueOrder.compareTo(b.queueOrder);
          break;
      }
      return _sortAscending ? comparison : -comparison;
    });

    _cachedFilteredTasks = list;
    _filteredTasksDirty = false;
    return list;
  }

  // ---------------------------------------------------------------------------
  // Mutators
  // ---------------------------------------------------------------------------
  void setSearchQuery(String query) {
    if (_searchQuery == query) return;
    _searchQuery = query;
    _filteredTasksDirty = true;
    notifyListeners();
  }

  void setStatusFilter(String filter) {
    if (_statusFilter == filter) return;
    _statusFilter = filter;
    _filteredTasksDirty = true;
    notifyListeners();
  }

  void setSortOption(SortOption option) {
    if (_sortOption == option) return;
    _sortOption = option;
    _filteredTasksDirty = true;
    notifyListeners();
  }

  void toggleSortDirection() {
    _sortAscending = !_sortAscending;
    _filteredTasksDirty = true;
    notifyListeners();
  }

  void setCategoryFilter(String? category) {
    _categoryFilters.clear();
    if (category != null) {
      _categoryFilters.add(category);
    }
    _filteredTasksDirty = true;
    notifyListeners();
  }

  void toggleCategoryFilter(String category) {
    if (_categoryFilters.contains(category)) {
      _categoryFilters.remove(category);
    } else {
      _categoryFilters.add(category);
    }
    _filteredTasksDirty = true;
    notifyListeners();
  }

  void clearCategoryFilters() {
    _categoryFilters.clear();
    _filteredTasksDirty = true;
    notifyListeners();
  }

  void setNavbarVisible(bool visible) {
    if (_isNavbarVisible != visible) {
      _isNavbarVisible = visible;
      notifyListeners();
    }
  }

  void setMixinActiveTabIndex(int index, {void Function()? onBrowserTab}) {
    _isNavbarVisible = true;
    if (_activeTabIndex == index) {
      notifyListeners();
      return;
    }
    _activeTabIndex = index;
    notifyListeners();
    if (index == 1) {
      onBrowserTab?.call();
    }
  }

  void openUrlInBrowser(String url) {
    _browserUrlToLoad = url;
    _activeTabIndex = 1;
    _isNavbarVisible = true;
    notifyListeners();
  }

  void clearBrowserUrlToLoad() {
    _browserUrlToLoad = null;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  static const List<String> _categories = [
    'Video',
    'Audio',
    'Document',
    'Archive',
    'APK',
    'Other'
  ];

  Map<String, T> _emptyCategoryCounts<T>(T value) {
    return {for (final cat in _categories) cat: value};
  }
}
