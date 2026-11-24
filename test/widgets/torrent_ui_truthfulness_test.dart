import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/services/torrent/fake_torrent_native.dart';
import 'package:dmx/core/services/torrent/libtorrent_native_impl.dart';
import 'package:dmx/core/services/torrent_service_ffi.dart';
import 'package:dmx/features/details/widgets/torrent_stats_dashboard.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_helpers.dart';

/// Verifies UI truthfulness on both the real libtorrent 2.0.11 native bridge
/// (exact piece bitfields & full resume/priorities/web-seeds/create support)
/// and degraded bridges (FakeTorrentNative v192).
void main() {
  tearDown(() {
    TorrentService.setNativeForTesting(LibtorrentNativeImpl());
  });

  TorrentUpdateInfo buildStats({
    double distributedCopies = 7.77,
    int piecesHave = 10,
    int piecesTotal = 100,
  }) {
    return TorrentUpdateInfo(
      id: 1,
      name: 'sample',
      progress: 0.45,
      downloadRate: 0,
      uploadRate: 0,
      totalDone: 0,
      totalWanted: 100,
      totalWantedDone: 45,
      hasMetadata: true,
      stateLabel: 'Downloading',
      distributedCopies: distributedCopies,
      piecesHave: piecesHave,
      piecesTotal: piecesTotal,
    );
  }

  group('TorrentStatsDashboard truthfulness', () {
    testWidgets('labels exact piece counts on libtorrent 2.0.11',
        (tester) async {
      TorrentService.setNativeForTesting(LibtorrentNativeImpl());

      await tester.pumpWidget(createTestApp(
        child: TorrentStatsDashboard(
          task: createTestTask(isTorrent: true),
          stats: buildStats(),
          isDark: true,
        ),
      ));

      expect(find.text('Pieces'), findsOneWidget);
      expect(find.text('10/100'), findsOneWidget);
    });

    testWidgets('labels piece counts as estimated on degraded bridges',
        (tester) async {
      TorrentService.setNativeForTesting(FakeTorrentNative());

      await tester.pumpWidget(createTestApp(
        child: TorrentStatsDashboard(
          task: createTestTask(isTorrent: true),
          stats: buildStats(),
          isDark: true,
        ),
      ));

      expect(find.text('Pieces (est.)'), findsOneWidget);
      expect(find.textContaining('~10/100'), findsOneWidget);
    });

    testWidgets('never surfaces fabricated distributed-copies / availability',
        (tester) async {
      await tester.pumpWidget(createTestApp(
        child: TorrentStatsDashboard(
          task: createTestTask(isTorrent: true),
          stats: buildStats(distributedCopies: 7.77),
          isDark: true,
        ),
      ));

      expect(find.textContaining('7.77'), findsNothing);
      expect(find.textContaining('Distributed'), findsNothing);
      expect(find.textContaining('Availability'), findsNothing);
    });

    testWidgets('omits the pieces row when no piece data is known',
        (tester) async {
      await tester.pumpWidget(createTestApp(
        child: TorrentStatsDashboard(
          task: createTestTask(isTorrent: true),
          stats: buildStats(piecesHave: 0, piecesTotal: 0),
          isDark: true,
        ),
      ));

      expect(find.text('Pieces'), findsNothing);
      expect(find.text('Pieces (est.)'), findsNothing);
    });
  });

  group('Torrent capability flags on libtorrent_dart 1.2.0 (2.0.11)', () {
    test('supported features report true and unexposed features report false',
        () {
      TorrentService.setNativeForTesting(LibtorrentNativeImpl());
      expect(TorrentService.resumeDataSupported, isTrue);
      expect(TorrentService.fileProgressSupported, isTrue);
      expect(TorrentService.filePrioritiesSupported, isTrue);
      expect(TorrentService.webSeedsSupported, isTrue);
      expect(TorrentService.proxySupported, isTrue);
      expect(TorrentService.sequentialDownloadSupported, isTrue);
      expect(TorrentService.createTorrentSupported, isTrue);
      expect(TorrentService.sslSupported, isFalse);
      expect(TorrentService.ipFilterSupported, isFalse);
    });
  });
}
