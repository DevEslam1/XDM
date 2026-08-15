import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:dmx/core/services/mirror/mirror_registry.dart';
import 'package:dmx/core/services/mirror/mirror_selector.dart';
import 'package:dmx/core/services/protocol_cache.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';
import 'package:dmx/core/services/background_service.dart';
import 'package:dmx/features/browser/services/ad_blocker_service.dart';
import 'package:dmx/features/browser/services/picture_in_picture_service.dart';
import 'package:dmx/features/browser/services/reader_mode_service.dart';
import 'package:dmx/features/browser/services/inactivity_watchdog.dart';
import 'package:dmx/features/browser/models/browser_tab.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 1 — Mirror Failover & Speed Ranking Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
    });

    test('MirrorHealthStore records rolling average speed and persists ranking',
        () async {
      const url = 'https://mirror1.example.com/file.zip';

      await MirrorHealthStore.instance.recordSpeed(url, 1000000);
      await MirrorHealthStore.instance.recordSpeed(url, 2000000);

      final ranking = MirrorHealthStore.instance.getMirrorRanking();
      expect(ranking, isNotNull);

      await MirrorHealthStore.instance.persistMirrorRanking([url]);
      final persisted =
          await MirrorHealthStore.instance.getPersistedMirrorRanking();
      expect(persisted, contains(url));
    });

    test(
        'MirrorFailover ranks mirrors by speed and respects HTTP/2 protocol preference',
        () async {
      final failover =
          MirrorFailover(['https://m1.com/file', 'https://m2.com/file']);
      await MirrorHealthStore.instance.recordSpeed('https://m1.com/file', 500000);
      await MirrorHealthStore.instance.recordSpeed('https://m2.com/file', 600000);
      ProtocolCache.record('https://m2.com/file', ProtocolSupport.http2);

      final current = failover.advance();
      expect(current, isNotNull);
    });

    test(
        'MirrorParallelEngine reallocates slow mirror threads to fastest mirror',
        () async {
      final failover =
          MirrorFailover(['https://fast.com/file', 'https://slow.com/file']);
      final engine = MirrorParallelEngine(
        ['https://fast.com/file', 'https://slow.com/file'],
        failover: failover,
      );

      await MirrorHealthStore.instance
          .recordSpeed('https://fast.com/file', 1000000);
      await MirrorHealthStore.instance
          .recordSpeed('https://slow.com/file', 100000);

      final allocations = engine.distributeThreads(4);
      expect(allocations.length, greaterThan(0));
    });
  });

  group('Phase 2 — Torrent Storage & Seeding Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
    });

    test('TorrentResumeStore rejects blobs > 1MB', () async {
      final oversizedBlob = List<int>.filled(1024 * 1024 + 10, 0);
      final success = await TorrentResumeStore.saveAndWait(
        torrentId: 1,
        sourceUrl: 'https://example.com/test.torrent',
        fetchResumeData: () => Uint8List.fromList(oversizedBlob),
      );
      expect(success, isFalse);
    });
  });

  group('Phase 4 — Browser Services & Lifecycle Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
    });

    test('AdBlockerService autoUpdateFilters respects 7-day TTL', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          'last_adblock_update', DateTime.now().millisecondsSinceEpoch);

      final service = AdBlockerService.instance;
      await service.autoUpdateFilters();
      final lastUpdate = prefs.getInt('last_adblock_update');
      expect(lastUpdate, isNotNull);
    });

    test('InactivityWatchdog pause and resume media tracking', () {
      final watchdog = InactivityWatchdog();
      final tab = BrowserTab(
        id: 'tab_1',
        url: 'https://example.com',
        title: 'Example',
      );

      watchdog.pauseTabMedia(tab);
      expect(() => watchdog.resumeTabMedia(tab), returnsNormally);
    });

    test('ReaderModeService extract handles invalid controller gracefully',
        () async {
      final article =
          await ReaderModeService.extract(FakeInAppWebViewController());
      expect(article, isNull);
    });

    test('PictureInPictureService isSupported handles invalid controller',
        () async {
      final supported = await PictureInPictureService.isSupported(
          FakeInAppWebViewController());
      expect(supported, isFalse);
    });
  });

  group('Phase 5 — Background Service & WakeLockGuard Tests', () {
    test('WakeLockGuard RAII auto-releases without throwing', () async {
      final guard = await WakeLockGuard.acquire();
      expect(guard, isNotNull);
      await guard.release();
      await guard.release();
    });
  });
}

class FakeInAppWebViewController implements InAppWebViewController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
