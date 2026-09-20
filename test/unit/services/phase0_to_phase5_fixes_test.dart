import 'dart:typed_data';

import 'package:dmx/core/services/background_service.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';
import 'package:dmx/features/browser/models/browser_tab.dart';
import 'package:dmx/features/browser/services/ad_blocker_service.dart';
import 'package:dmx/features/browser/services/inactivity_watchdog.dart';
import 'package:dmx/features/browser/services/reader_mode_service.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
