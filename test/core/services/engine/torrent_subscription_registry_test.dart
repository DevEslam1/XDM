import 'dart:async';

import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../test/helpers/fake_torrent_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TorrentSubscriptionRegistry & Ownership (M1)', () {
    late FakeITorrentService fakeService;

    setUp(() {
      TorrentSubscriptionRegistry.instance.clear();
      fakeService = FakeITorrentService();
    });

    // Regression: M1
    test('re-register cancels previous subscription', () async {
      final handler = TorrentDownloadHandler(torrentService: fakeService);
      final controller = StreamController<void>.broadcast();

      final sub1 = controller.stream.listen((_) {});
      final sub2 = controller.stream.listen((_) {});

      TorrentSubscriptionRegistry.instance.register(1, handler, sub1);
      expect(TorrentSubscriptionRegistry.instance.getSubscription(1),
          equals(sub1));

      // Re-register replaces and cancels sub1
      TorrentSubscriptionRegistry.instance.register(1, handler, sub2);
      expect(TorrentSubscriptionRegistry.instance.getSubscription(1),
          equals(sub2));

      await sub2.cancel();
      await controller.close();
    });

    // Regression: M1
    test('unregister with foreign handler is a no-op', () async {
      final handler1 = TorrentDownloadHandler(torrentService: fakeService);
      final handler2 = TorrentDownloadHandler(torrentService: fakeService);
      final controller = StreamController<void>();
      final sub = controller.stream.listen((_) {});

      TorrentSubscriptionRegistry.instance.register(10, handler1, sub);

      // Attempt unregister with foreign handler2
      TorrentSubscriptionRegistry.instance.unregister(10, handler2);
      expect(TorrentSubscriptionRegistry.instance.getSubscription(10),
          equals(sub));

      // Unregister with owning handler1 succeeds
      TorrentSubscriptionRegistry.instance.unregister(10, handler1);
      expect(TorrentSubscriptionRegistry.instance.getSubscription(10), isNull);

      await sub.cancel();
      await controller.close();
    });

    // Regression: M1
    test('unregisterAll removes and cancels all subscriptions for a handler',
        () async {
      final handler = TorrentDownloadHandler(torrentService: fakeService);
      final controller1 = StreamController<void>();
      final controller2 = StreamController<void>();
      final sub1 = controller1.stream.listen((_) {});
      final sub2 = controller2.stream.listen((_) {});

      TorrentSubscriptionRegistry.instance.register(101, handler, sub1);
      TorrentSubscriptionRegistry.instance.register(102, handler, sub2);

      expect(TorrentSubscriptionRegistry.instance.activeCountForTesting,
          equals(2));

      TorrentSubscriptionRegistry.instance.unregisterAll(handler);
      expect(TorrentSubscriptionRegistry.instance.activeCountForTesting,
          equals(0));

      await controller1.close();
      await controller2.close();
    });
  });
}
