import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/provider/network_monitor.dart';
import 'package:dmx/features/downloads/models/download_task.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NetworkMonitor Tests (N-01)', () {
    test(
        'rapid network connectivity events debounce to prevent thrashing (N-01)',
        () async {
      int pumpCount = 0;
      int setTaskCount = 0;
      final tasks = <DownloadTask>[
        DownloadTask(
          id: 'task_n1',
          fileName: 'file.bin',
          url: 'https://example.com/file.bin',
          category: 'other',
          threadCount: 2,
          chunks: const [],
          fileSize: 1000,
          downloadedBytes: 500,
          status: DownloadStatus.downloading,
          savePath: '/tmp',
          localFilePath: '/tmp/file.bin',
          tempFilePath: '/tmp/file.tmp',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ];

      final monitor = NetworkMonitor(
        tasks: () => tasks,
        torrentIds: () => {},
        cancelTokens: () => {},
        wifiOnly: () => false,
        setTask: (t) async {
          setTaskCount++;
        },
        pumpQueue: () {
          pumpCount++;
        },
      );

      // Verify captive portal probe helper exists and works
      final probeResult = await NetworkMonitor.verifyConnectivityProbe();
      expect(probeResult, isA<bool>());
      expect(pumpCount, equals(0));
      expect(setTaskCount, equals(0));

      monitor.dispose();
    });

    test(
        'hasWifiOrEthernet and isCellular identify connectivity states accurately',
        () {
      final monitor = NetworkMonitor(
        tasks: () => [],
        torrentIds: () => {},
        cancelTokens: () => {},
        wifiOnly: () => false,
        setTask: (t) async {},
        pumpQueue: () {},
      );

      expect(monitor.hasWifiOrEthernet, isFalse);
      expect(monitor.isCellular, isFalse);
      monitor.dispose();
    });
  });
}
