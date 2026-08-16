import 'dart:async';

import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TorrentSubscriptionRegistry & Handler Isolation (P0-2)', () {
    setUp(() {
      TorrentSubscriptionRegistry.instance.clear();
    });

    test(
        'Two handler instances maintain isolated subscriptions and do not trample each other',
        () async {
      final handler1 = TorrentDownloadHandler();
      final handler2 = TorrentDownloadHandler();

      final controller1 = StreamController<void>();
      final controller2 = StreamController<void>();

      final sub1 = controller1.stream.listen((_) {});
      final sub2 = controller2.stream.listen((_) {});

      // Register sub1 to handler1 for torrent 101
      TorrentSubscriptionRegistry.instance.register(101, handler1, sub1);
      // Register sub2 to handler2 for torrent 202
      TorrentSubscriptionRegistry.instance.register(202, handler2, sub2);

      expect(TorrentSubscriptionRegistry.instance.getSubscription(101),
          equals(sub1));
      expect(TorrentSubscriptionRegistry.instance.getSubscription(202),
          equals(sub2));

      // Unregister handler1 should not affect handler2
      TorrentSubscriptionRegistry.instance.unregister(101, handler1);
      expect(TorrentSubscriptionRegistry.instance.getSubscription(101), isNull);
      expect(TorrentSubscriptionRegistry.instance.getSubscription(202),
          equals(sub2));

      // Attempting to unregister 202 using wrong handler (handler1) must not remove handler2 sub
      TorrentSubscriptionRegistry.instance.unregister(202, handler1);
      expect(TorrentSubscriptionRegistry.instance.getSubscription(202),
          equals(sub2));

      // Correct unregister
      TorrentSubscriptionRegistry.instance.unregister(202, handler2);
      expect(TorrentSubscriptionRegistry.instance.getSubscription(202), isNull);

      await sub1.cancel();
      await sub2.cancel();
      await controller1.close();
      await controller2.close();
    });

    test(
        'Removing active torrent from one handler does not mutate another handler state',
        () {
      final handlerA = TorrentDownloadHandler();
      final handlerB = TorrentDownloadHandler();

      handlerA.removeActiveTorrent(1);
      expect(handlerA.activeSubsForTesting, isEmpty);
      expect(handlerB.activeSubsForTesting, isEmpty);
    });

    test('dispose cancels the subscription and drops the entry immediately',
        () async {
      final handler = TorrentDownloadHandler();
      final controller = StreamController<void>();
      var events = 0;
      final sub = controller.stream.listen((_) => events++);

      TorrentSubscriptionRegistry.instance.register(303, handler, sub);
      expect(TorrentSubscriptionRegistry.instance.getSubscription(303),
          equals(sub));

      // Explicit dispose must cancel the subscription and remove the entry.
      TorrentSubscriptionRegistry.instance.dispose(303);
      expect(TorrentSubscriptionRegistry.instance.getSubscription(303), isNull);
      expect(controller.hasListener, isFalse);

      // No further events after dispose.
      controller.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(events, equals(0));

      await controller.close();
    });
  });
}
