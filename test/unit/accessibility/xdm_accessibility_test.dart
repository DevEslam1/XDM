import 'package:dmx/shared/accessibility/xdm_announcer.dart';
import 'package:dmx/shared/accessibility/xdm_motion.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('XdmMotion', () {
    Widget host({required bool disableAnimations, required Widget child}) {
      return MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: child,
      );
    }

    testWidgets('duration collapses to zero under reduced motion',
        (tester) async {
      const full = Duration(milliseconds: 240);
      Duration? measured;
      await tester.pumpWidget(
        host(
          disableAnimations: true,
          child: Builder(
            builder: (context) {
              measured = XdmMotion.duration(context, full);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(measured, Duration.zero);
    });

    testWidgets('duration keeps full value when motion is enabled',
        (tester) async {
      const full = Duration(milliseconds: 240);
      Duration? measured;
      await tester.pumpWidget(
        host(
          disableAnimations: false,
          child: Builder(
            builder: (context) {
              measured = XdmMotion.duration(context, full);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(measured, full);
    });

    testWidgets('pauseAmbient reflects the reduce-motion setting',
        (tester) async {
      bool? paused;
      await tester.pumpWidget(
        host(
          disableAnimations: true,
          child: Builder(
            builder: (context) {
              paused = XdmMotion.pauseAmbient(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(paused, isTrue);
    });
  });

  group('XdmAnnouncer', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final log = <String>[];

    setUp(() {
      log.clear();
      XdmAnnouncer.flush();
      messenger.setMockMessageHandler(
        'flutter/accessibility',
        (message) async {
          final decoded = const StandardMessageCodec().decodeMessage(message);
          if (decoded is Map && decoded['data'] is Map) {
            final data = decoded['data'] as Map;
            log.add(data['message']?.toString() ?? '');
          }
          return null;
        },
      );
    });

    tearDown(() {
      XdmAnnouncer.flush();
      messenger.setMockMessageHandler('flutter/accessibility', null);
    });

    test('announces immediately when idle', () {
      XdmAnnouncer.announce('Download complete');
      expect(log, contains('Download complete'));
    });

    test('coalesces rapid messages into the latest one', () {
      fakeAsync((async) {
        XdmAnnouncer.announce('Download complete');
        XdmAnnouncer.announce('Download progress 10%');
        XdmAnnouncer.announce('Download progress 90%');
        async.elapse(const Duration(milliseconds: 900));
        expect(log, contains('Download complete'));
        expect(log, contains('Download progress 90%'));
        // The two intermediate announcements were coalesced away.
        expect(log, isNot(contains('Download progress 10%')));
      });
    });

    test('flush drops a pending announcement', () {
      fakeAsync((async) {
        XdmAnnouncer.announce('Download complete');
        XdmAnnouncer.announce('Queued message');
        XdmAnnouncer.flush();
        async.elapse(const Duration(seconds: 2));
        expect(log, isNot(contains('Queued message')));
      });
    });

    test('empty messages are ignored', () {
      XdmAnnouncer.announce('');
      XdmAnnouncer.announceNow('');
      expect(log, isEmpty);
    });
  });
}
