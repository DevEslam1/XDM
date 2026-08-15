import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/widgets/speed_graph_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SpeedGraphWidget', () {
    testWidgets('renders correctly with rolling samples', (tester) async {
      final samples = List.generate(100, (i) => i * 1024 * 100);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SpeedGraphWidget(
              speedHistory: samples,
              status: DownloadStatus.downloading,
            ),
          ),
        ),
      );

      expect(find.byType(SpeedGraphWidget), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.text('Download Speed (60s)'), findsOneWidget);
    });
  });
}
