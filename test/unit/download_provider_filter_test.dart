import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/mixins/download_filter_mixin.dart';
import 'package:flutter_test/flutter_test.dart';

class TestFilterHost with DownloadFilterMixin {
  final List<DownloadTask> _tasksList = [];

  void addTasks(List<DownloadTask> list) {
    _tasksList.addAll(list);
    filteredTasksDirty = true;
  }

  @override
  List<DownloadTask> get providerTasks => _tasksList;

  @override
  void notifyListeners() {
    filteredTasksDirty = true;
  }

  @override
  DownloadTask? findTaskById(String id) {
    try {
      return _tasksList.firstWhere((t) => t.id == id);
    } catch (_) {
      return null;
    }
  }
}

DownloadTask makeTask({
  required String id,
  required String fileName,
  required String url,
  required DownloadStatus status,
  int fileSize = 1000,
  String category = 'Other',
  DateTime? createdAt,
}) {
  return DownloadTask(
    id: id,
    fileName: fileName,
    url: url,
    fileSize: fileSize,
    downloadedBytes: 0,
    category: category,
    status: status,
    savePath: '/tmp',
    localFilePath: '/tmp/$fileName',
    tempFilePath: '/tmp/$fileName.tmp',
    threadCount: 4,
    chunks: const [0.0],
    createdAt: createdAt ?? DateTime.now(),
    updatedAt: DateTime.now(),
  );
}

void main() {
  group('DownloadFilterMixin', () {
    test('1. setSearchQuery filters by fileName', () {
      final host = TestFilterHost();
      host.addTasks([
        makeTask(
            id: '1',
            fileName: 'ubuntu_iso.iso',
            url: 'https://a.com/1',
            status: DownloadStatus.completed),
        makeTask(
            id: '2',
            fileName: 'arch_linux.iso',
            url: 'https://a.com/2',
            status: DownloadStatus.completed),
        makeTask(
            id: '3',
            fileName: 'notes.txt',
            url: 'https://a.com/3',
            status: DownloadStatus.completed),
      ]);

      host.setSearchQuery('ubuntu');
      final filtered = host.filteredTasks;
      expect(filtered.length, equals(1));
      expect(filtered.first.id, equals('1'));
    });

    test('2. setSearchQuery filters by URL', () {
      final host = TestFilterHost();
      host.addTasks([
        makeTask(
            id: '1',
            fileName: 'file1.bin',
            url: 'https://cdn.server1.com/file1.bin',
            status: DownloadStatus.completed),
        makeTask(
            id: '2',
            fileName: 'file2.bin',
            url: 'https://mirror.org/file2.bin',
            status: DownloadStatus.completed),
      ]);

      host.setSearchQuery('cdn.server1');
      final filtered = host.filteredTasks;
      expect(filtered.length, equals(1));
      expect(filtered.first.id, equals('1'));
    });

    test('3. setStatusFilter("Downloading") shows downloading+queued', () {
      final host = TestFilterHost();
      host.addTasks([
        makeTask(
            id: '1',
            fileName: '1.bin',
            url: 'https://a.com/1',
            status: DownloadStatus.downloading),
        makeTask(
            id: '2',
            fileName: '2.bin',
            url: 'https://a.com/2',
            status: DownloadStatus.queued),
        makeTask(
            id: '3',
            fileName: '3.bin',
            url: 'https://a.com/3',
            status: DownloadStatus.completed),
      ]);

      host.setStatusFilter('Downloading');
      final filtered = host.filteredTasks;
      expect(filtered.length, equals(2));
    });

    test('4. setStatusFilter("Completed") excludes non-completed', () {
      final host = TestFilterHost();
      host.addTasks([
        makeTask(
            id: '1',
            fileName: '1.bin',
            url: 'https://a.com/1',
            status: DownloadStatus.completed),
        makeTask(
            id: '2',
            fileName: '2.bin',
            url: 'https://a.com/2',
            status: DownloadStatus.failed),
      ]);

      host.setStatusFilter('Completed');
      final filtered = host.filteredTasks;
      expect(filtered.length, equals(1));
      expect(filtered.first.id, equals('1'));
    });

    test('5. toggleCategoryFilter adds/removes category', () {
      final host = TestFilterHost();
      host.toggleCategoryFilter('Video');
      expect(host.categoryFilters.contains('Video'), isTrue);

      host.toggleCategoryFilter('Video');
      expect(host.categoryFilters.contains('Video'), isFalse);
    });

    test('6. sortOption=dateAdded sorts by createdAt', () {
      final host = TestFilterHost();
      final t1 = DateTime(2026, 1, 1);
      final t2 = DateTime(2026, 1, 2);
      host.addTasks([
        makeTask(
            id: '1',
            fileName: 'older',
            url: 'https://a.com/1',
            status: DownloadStatus.completed,
            createdAt: t1),
        makeTask(
            id: '2',
            fileName: 'newer',
            url: 'https://a.com/2',
            status: DownloadStatus.completed,
            createdAt: t2),
      ]);

      host.setSortOption(SortOption.dateAdded);
      final filtered = host.filteredTasks;
      expect(filtered.first.id, equals('2')); // Default sort is descending
    });

    test('7. sortOption=fileSize sorts by fileSize', () {
      final host = TestFilterHost();
      host.addTasks([
        makeTask(
            id: '1',
            fileName: 'small',
            url: 'https://a.com/1',
            status: DownloadStatus.completed,
            fileSize: 100),
        makeTask(
            id: '2',
            fileName: 'large',
            url: 'https://a.com/2',
            status: DownloadStatus.completed,
            fileSize: 10000),
      ]);

      host.setSortOption(SortOption.fileSize);
      final filtered = host.filteredTasks;
      expect(filtered.first.id, equals('2')); // Large first in descending
    });

    test('8. toggleSortDirection reverses order', () {
      final host = TestFilterHost();
      host.addTasks([
        makeTask(
            id: '1',
            fileName: 'small',
            url: 'https://a.com/1',
            status: DownloadStatus.completed,
            fileSize: 100),
        makeTask(
            id: '2',
            fileName: 'large',
            url: 'https://a.com/2',
            status: DownloadStatus.completed,
            fileSize: 10000),
      ]);

      host.setSortOption(SortOption.fileSize);
      host.toggleSortDirection();
      final filtered = host.filteredTasks;
      expect(filtered.first.id, equals('1')); // Small first in ascending
    });

    test('9. setMixinActiveTabIndex updates activeTabIndex and shows navbar',
        () {
      final host = TestFilterHost();
      expect(host.activeTabIndex, equals(0));

      host.setMixinActiveTabIndex(1);
      expect(host.activeTabIndex, equals(1));
      expect(host.isNavbarVisible, isTrue);

      host.setMixinActiveTabIndex(2);
      expect(host.activeTabIndex, equals(2));
    });
  });
}
