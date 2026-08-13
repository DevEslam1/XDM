import 'package:flutter/foundation.dart';
import '../models/download_task.dart';
import 'download_list_provider.dart';

enum SortMode { name, dateAdded, size, progress, manual }

typedef SortOption = SortMode;

/// Single-responsibility provider managing search, filtering, and sorting state.
class DownloadFilterProvider extends ChangeNotifier {
  final DownloadListProvider _listProvider;

  String _searchQuery = '';
  String _statusFilter = 'All';
  Set<String> _categoryFilters = {};
  SortMode _sortMode = SortMode.dateAdded;
  bool _ascending = false;

  DownloadFilterProvider(this._listProvider) {
    _listProvider.addListener(_onListChanged);
  }

  void _onListChanged() => notifyListeners();

  String get searchQuery => _searchQuery;
  String get statusFilter => _statusFilter;
  Set<String> get categoryFilters => Set.unmodifiable(_categoryFilters);
  SortMode get sortMode => _sortMode;
  bool get ascending => _ascending;

  List<DownloadTask> get filteredTasks => applyFilter(_listProvider.tasks);

  List<DownloadTask> applyFilter(List<DownloadTask> tasks) {
    final result = tasks.where((task) {
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        if (!task.fileName.toLowerCase().contains(q) &&
            !task.url.toLowerCase().contains(q)) {
          return false;
        }
      }
      if (_categoryFilters.isNotEmpty &&
          !_categoryFilters.contains(task.category)) {
        return false;
      }
      switch (_statusFilter) {
        case 'Downloading':
          return task.status == DownloadStatus.downloading ||
              task.status == DownloadStatus.queued;
        case 'Completed':
          return task.status == DownloadStatus.completed;
        case 'Failed':
          return task.status == DownloadStatus.failed;
        case 'Paused':
          return task.status == DownloadStatus.paused;
        case 'Torrents':
          return task.isTorrent;
        default:
          return true;
      }
    }).toList();

    result.sort((a, b) {
      int cmp = 0;
      switch (_sortMode) {
        case SortMode.name:
          cmp = a.fileName.compareTo(b.fileName);
          break;
        case SortMode.dateAdded:
          cmp = a.createdAt.compareTo(b.createdAt);
          break;
        case SortMode.size:
          cmp = a.fileSize.compareTo(b.fileSize);
          break;
        case SortMode.progress:
          cmp = a.progress.compareTo(b.progress);
          break;
        case SortMode.manual:
          cmp = 0;
          break;
      }
      return _ascending ? cmp : -cmp;
    });
    return result;
  }

  void setSearch(String q) {
    _searchQuery = q;
    notifyListeners();
  }

  void setSearchQuery(String q) => setSearch(q);

  void setStatus(String s) {
    _statusFilter = s;
    notifyListeners();
  }

  void setStatusFilter(String s) => setStatus(s);

  void setCategories(Set<String> cats) {
    _categoryFilters = cats;
    notifyListeners();
  }

  void toggleCategoryFilter(String category) {
    final next = Set<String>.from(_categoryFilters);
    if (next.contains(category)) {
      next.remove(category);
    } else {
      next.add(category);
    }
    setCategories(next);
  }

  void setSort(SortMode mode, {bool? ascending}) {
    _sortMode = mode;
    if (ascending != null) _ascending = ascending;
    notifyListeners();
  }

  void setSortOption(SortOption option, {bool? ascending}) =>
      setSort(option, ascending: ascending);

  @override
  void dispose() {
    _listProvider.removeListener(_onListChanged);
    super.dispose();
  }
}
