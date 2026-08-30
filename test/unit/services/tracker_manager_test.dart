import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/tracker_manager.dart';
import 'package:dmx/core/services/torrent_models.dart';

void main() {
  group('TrackerManager', () {
    late TrackerManager trackerManager;

    setUp(() {
      trackerManager = TrackerManager();
    });

    test('addTracker accepts valid URLs and notifies listeners', () {
      bool notified = false;
      trackerManager.addListener(() => notified = true);

      final added = trackerManager.addTracker(
        1,
        'udp://tracker.opentrackr.org:1337/announce',
      );

      expect(added, isTrue);
      expect(notified, isTrue);

      final trackers = trackerManager.getTrackers(1);
      expect(trackers.length, equals(1));
      expect(trackers.first.url,
          equals('udp://tracker.opentrackr.org:1337/announce'));
      expect(trackers.first.status, equals(TrackerStatus.updating));
    });

    test('addTracker rejects invalid scheme or duplicate URLs', () {
      final addedInvalid =
          trackerManager.addTracker(1, 'ftp://invalid-scheme.com');
      expect(addedInvalid, isFalse);

      trackerManager.addTracker(1, 'http://tracker1.org/announce');
      final addedDuplicate =
          trackerManager.addTracker(1, 'http://tracker1.org/announce');
      expect(addedDuplicate, isFalse);
    });

    test('removeTracker removes existing tracker', () {
      trackerManager.addTracker(1, 'http://tracker1.org/announce');
      expect(trackerManager.getTrackers(1).length, equals(1));

      trackerManager.removeTracker(1, 'http://tracker1.org/announce');
      expect(trackerManager.getTrackers(1).isEmpty, isTrue);
    });

    test('reannounce sets status to updating for all trackers', () {
      trackerManager.addTracker(1, 'http://tracker1.org/announce');
      trackerManager.reannounce(1);

      final trackers = trackerManager.getTrackers(1);
      expect(trackers.first.status, equals(TrackerStatus.updating));
      expect(trackers.first.message, contains('Manual announce queued'));
    });
  });
}
