import 'package:flutter/foundation.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';

/// ViewModel for History Screen caching filtered completed downloads.
class HistoryViewModel extends ChangeNotifier {
  final DownloadProvider downloadProvider;
  String _searchQuery = '';

  HistoryViewModel({required this.downloadProvider});

  String get searchQuery => _searchQuery;

  void setSearchQuery(String query) {
    if (_searchQuery != query) {
      _searchQuery = query;
      notifyListeners();
    }
  }

  List<DownloadTask> get completedTasks {
    final list = downloadProvider.tasks.where((t) => t.status == DownloadStatus.completed).toList();
    if (_searchQuery.isEmpty) return list;
    final q = _searchQuery.toLowerCase();
    return list
        .where(
          (t) =>
              t.fileName.toLowerCase().contains(q) ||
              t.url.toLowerCase().contains(q),
        )
        .toList();
  }
}
