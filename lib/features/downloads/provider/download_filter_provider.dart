import 'package:flutter/foundation.dart';
import 'package:dmx/features/downloads/models/download_task.dart';

enum SortMode {
  name,
  dateAdded,
  size,
  progress,
}

class DownloadFilterProvider extends ChangeNotifier {
  String _searchQuery = '';
  String? _selectedCategory;
  DownloadStatus? _statusFilter;
  SortMode _sortMode = SortMode.dateAdded;
  bool _sortAscending = false;

  String get searchQuery => _searchQuery;
  String? get selectedCategory => _selectedCategory;
  DownloadStatus? get statusFilter => _statusFilter;
  SortMode get sortMode => _sortMode;
  bool get sortAscending => _sortAscending;

  void setSearchQuery(String query) {
    _searchQuery = query.trim().toLowerCase();
    notifyListeners();
  }

  void setCategory(String? category) {
    _selectedCategory = category;
    notifyListeners();
  }

  void setStatusFilter(DownloadStatus? status) {
    _statusFilter = status;
    notifyListeners();
  }

  void setSortMode(SortMode mode, {bool? ascending}) {
    _sortMode = mode;
    if (ascending != null) _sortAscending = ascending;
    notifyListeners();
  }

  List<DownloadTask> applyFilter(List<DownloadTask> tasks) {
    final result = tasks.where((task) {
      if (_searchQuery.isNotEmpty) {
        final nameMatch = task.fileName.toLowerCase().contains(_searchQuery);
        final urlMatch = task.url.toLowerCase().contains(_searchQuery);
        if (!nameMatch && !urlMatch) return false;
      }
      if (_selectedCategory != null && task.category != _selectedCategory) {
        return false;
      }
      if (_statusFilter != null && task.status != _statusFilter) {
        return false;
      }
      return true;
    }).toList();

    result.sort((a, b) {
      int comp;
      switch (_sortMode) {
        case SortMode.name:
          comp = a.fileName.compareTo(b.fileName);
          break;
        case SortMode.dateAdded:
          comp = a.createdAt.compareTo(b.createdAt);
          break;
        case SortMode.size:
          comp = a.fileSize.compareTo(b.fileSize);
          break;
        case SortMode.progress:
          comp = a.progress.compareTo(b.progress);
          break;
      }
      return _sortAscending ? comp : -comp;
    });

    return result;
  }
}
