import 'dart:async';
import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TorrentSubscriptionRegistry.instance.clear();
  });

  tearDown(() {
    TorrentSubscriptionRegistry.instance.clear();
  });

  group('TorrentSubscriptionRegistry & Handler Hardening (Sprint 1)', () {
    test('Registry tracks handler strongly and cleans up subscription on unregister', () async {
      final controller = StreamController<int>();
      final sub = controller.stream.listen((_) {});

      final handler = TorrentDownloadHandler();
      TorrentSubscriptionRegistry.instance.register(101, handler, sub);

      expect(TorrentSubscriptionRegistry.instance.getSubscription(101), equals(sub));
      expect(TorrentSubscriptionRegistry.instance.activeCountForTesting, equals(1));

      // Unregister should clean up
      TorrentSubscriptionRegistry.instance.unregister(101, handler);
      expect(TorrentSubscriptionRegistry.instance.getSubscription(101), isNull);
      expect(TorrentSubscriptionRegistry.instance.activeCountForTesting, equals(0));

      await sub.cancel();
      await controller.close();
    });

    test('Adaptive sync interval returns 30s for small torrents and 120s for huge torrents', () {
      expect(TorrentDownloadHandler.computeAdaptiveSyncInterval(500), equals(const Duration(seconds: 15)));
      expect(TorrentDownloadHandler.computeAdaptiveSyncInterval(1500), equals(const Duration(seconds: 30)));
      expect(TorrentDownloadHandler.computeAdaptiveSyncInterval(12000), equals(const Duration(seconds: 120)));
    });
  });
}
