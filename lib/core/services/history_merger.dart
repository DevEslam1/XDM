/// Pure, dependency-free merge of raw Hive browser-history entries, deduplicated
/// by URL. Kept separate from [DatabaseService] so the merge rules can be unit
/// tested in isolation.
library;

/// A deduplicated browser-history item aggregated from raw Hive values.
class MergedHistoryItem {
  MergedHistoryItem({
    required this.url,
    required this.title,
    required this.visitedAt,
    required this.visitCount,
    this.faviconUrl,
  });

  final String url;
  String title;
  int visitedAt;
  int visitCount;
  String? faviconUrl;
}

/// Deduplicates raw history values by URL.
///
/// Returns `(mergedItems, failedItems)`. Values that are not `Map`s, or that
/// fail to parse, are returned in [failedItems] without aborting the merge.
({List<MergedHistoryItem> merged, List<dynamic> failed}) mergeHistoryEntries(
  Iterable<dynamic> values,
) {
  final mergedByUrl = <String, MergedHistoryItem>{};
  final failed = <dynamic>[];

  for (final val in values) {
    if (val is Map) {
      try {
        final url = val['url'] as String? ?? '';
        if (url.isEmpty) continue;
        final title = val['title'] as String? ?? url;
        final visitedAt = (val['visitedAt'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch;
        final faviconUrl = val['faviconUrl'] as String?;

        final existing = mergedByUrl[url];
        if (existing == null) {
          mergedByUrl[url] = MergedHistoryItem(
            url: url,
            title: title,
            visitedAt: visitedAt,
            visitCount: 1,
            faviconUrl: faviconUrl,
          );
        } else {
          existing.visitCount += 1;
          if (visitedAt > existing.visitedAt) {
            existing.visitedAt = visitedAt;
            existing.title = title;
          }
          if (faviconUrl != null) {
            existing.faviconUrl = faviconUrl;
          }
        }
      } catch (_) {
        failed.add(val);
      }
    } else {
      failed.add(val);
    }
  }

  return (merged: mergedByUrl.values.toList(), failed: failed);
}
