import 'package:flutter/foundation.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';

/// ViewModel for categories aggregation, caching statistics and pie sections.
class CategoriesViewModel extends ChangeNotifier {
  final DownloadProvider downloadProvider;

  CategoriesViewModel({required this.downloadProvider});

  List<DownloadTask> get tasks => downloadProvider.tasks;

  Map<String, int> get categoryCounts {
    final map = <String, int>{};
    for (final task in tasks) {
      final cat = task.category.isNotEmpty ? task.category : 'Other';
      map[cat] = (map[cat] ?? 0) + 1;
    }
    return map;
  }

  Map<String, int> get categorySizes {
    final map = <String, int>{};
    for (final task in tasks) {
      final cat = task.category.isNotEmpty ? task.category : 'Other';
      map[cat] = (map[cat] ?? 0) +
          (task.fileSize > 0 ? task.fileSize : task.downloadedBytes);
    }
    return map;
  }
}
