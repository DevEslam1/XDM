import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/features/downloads/widgets/channel_progress_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChannelProgressPainter Widget Tests', () {
    testWidgets('IsolatedProgressBar renders without error',
        (WidgetTester tester) async {
      final progress = ValueNotifier<double>(0.45);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                child: IsolatedProgressBar(
                  progress: progress,
                  isDark: true,
                  isTorrent: false,
                  height: 8,
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(IsolatedProgressBar), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(IsolatedProgressBar),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );

      // Value update triggers repainting without throw
      progress.value = 0.85;
      await tester.pump();

      expect(find.byType(IsolatedProgressBar), findsOneWidget);
    });

    testWidgets(
        'ChannelProgressPainter shouldRepaint compares properties correctly',
        (WidgetTester tester) async {
      final p1 = ValueNotifier<double>(0.2);
      final p2 = ValueNotifier<double>(0.5);

      final painter1 =
          ChannelProgressPainter(progress: p1, isDark: true, isTorrent: false);
      final painter2 =
          ChannelProgressPainter(progress: p1, isDark: true, isTorrent: false);
      final painter3 =
          ChannelProgressPainter(progress: p2, isDark: true, isTorrent: false);

      expect(painter1.shouldRepaint(painter2), isFalse);
      expect(painter1.shouldRepaint(painter3), isTrue);
    });

    testWidgets(
        'shouldRepaint returns false when chunkFingerprint is equal even if '
        'chunk detail lists differ by construction',
        (WidgetTester tester) async {
      final p1 = ValueNotifier<double>(0.5);

      final painterA = ChannelProgressPainter(
        progress: p1,
        isDark: true,
        isTorrent: false,
        chunkFingerprint: 42,
        chunkDetails: const [
          ChunkDetail(
            index: 0,
            start: 0,
            end: 10,
            downloaded: 5,
            size: 10,
            ratio: 0.5,
          ),
        ],
      );
      final painterB = ChannelProgressPainter(
        progress: p1,
        isDark: true,
        isTorrent: false,
        chunkFingerprint: 42,
        chunkDetails: const [
          ChunkDetail(
            index: 0,
            start: 0,
            end: 10,
            downloaded: 8,
            size: 10,
            ratio: 0.8,
          ),
        ],
      );

      expect(painterA.shouldRepaint(painterB), isFalse);
    });

    testWidgets('shouldRepaint returns true when chunkFingerprint differs',
        (WidgetTester tester) async {
      final p1 = ValueNotifier<double>(0.5);

      final painterA = ChannelProgressPainter(
        progress: p1,
        isDark: true,
        isTorrent: false,
        chunkFingerprint: 42,
        chunkDetails: const [
          ChunkDetail(
            index: 0,
            start: 0,
            end: 10,
            downloaded: 5,
            size: 10,
            ratio: 0.5,
          ),
        ],
      );
      final painterB = ChannelProgressPainter(
        progress: p1,
        isDark: true,
        isTorrent: false,
        chunkFingerprint: 43,
        chunkDetails: const [
          ChunkDetail(
            index: 0,
            start: 0,
            end: 10,
            downloaded: 8,
            size: 10,
            ratio: 0.8,
          ),
        ],
      );

      expect(painterA.shouldRepaint(painterB), isTrue);
    });
  });
}
