import 'package:dmx/core/services/torrent_service.dart';
import 'package:dmx/features/details/widgets/torrent_stats_dashboard.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_helpers.dart';

/// Guards the "honest degrade" contract for torrent UI on the libtorrent 1.9.2
/// bridge, where native symbols are stubbed and several stat fields are
/// synthetic (distributedCopies hardcoded 0.0, pieces estimated from size).
/// These tests fail if any widget starts presenting fabricated data as real or
/// if a capability that the bridge cannot honor is re-flagged as supported.
void main() {
  // A distributedCopies value distinct from every other stat the dashboard can
  // render, so a match on "7.77" can only mean the fabricated field leaked
  // into the UI. The 1.9.2 bridge always reports 0.0; we force non-zero here to
  // prove the widget drops it regardless.
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
    testWidgets('labels piece counts as estimated', (tester) async {
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

      expect(find.text('Pieces (est.)'), findsNothing);
    });
  });

  group('Torrent capability flags gated false on the 1.9.2 bridge', () {
    // Locks the honest-degrade gating: these features map to logged no-ops in
    // the native bridge, so the UI hides their controls. If a future build
    // wires them up, flip the flag AND drop the UI guard together.
    test('advanced and creation features report unsupported', () {
      expect(TorrentService.webSeedsSupported, isFalse);
      expect(TorrentService.proxySupported, isFalse);
      expect(TorrentService.sslSupported, isFalse);
      expect(TorrentService.ipFilterSupported, isFalse);
      expect(TorrentService.sequentialDownloadSupported, isFalse);
      expect(TorrentService.createTorrentSupported, isFalse);
    });
  });
}
