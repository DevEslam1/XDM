import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';

import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';

/// ViewModel managing state, metrics caching, and speed history for the Details screen.
class DetailsViewModel extends ChangeNotifier {
  final String taskId;
  final DownloadProvider downloadProvider;

  DateTime _lastSpeedUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  List<FlSpot> _downloadSpots = const [];
  List<FlSpot> _uploadSpots = const [];
  int _maxGraphLen = 1;

  DetailsViewModel({
    required this.taskId,
    required this.downloadProvider,
  });

  DownloadTask? get task {
    final matches = downloadProvider.tasks.where((t) => t.id == taskId);
    return matches.isNotEmpty ? matches.first : null;
  }

  List<FlSpot> get downloadSpots => _downloadSpots;
  List<FlSpot> get uploadSpots => _uploadSpots;
  int get maxGraphLen => _maxGraphLen;

  void updateSpeedSpots() {
    final now = DateTime.now();
    if (now.difference(_lastSpeedUpdate) >= const Duration(milliseconds: 1000) ||
        _downloadSpots.isEmpty) {
      _lastSpeedUpdate = now;
      final speedHistory = downloadProvider.getSpeedHistory(taskId);
      final uploadHistory = downloadProvider.getUploadSpeedHistory(taskId);

      final List<FlSpot> dl = List.generate(speedHistory.length, (i) {
        return FlSpot(i.toDouble(), speedHistory[i]);
      });
      if (dl.length == 1) {
        dl.add(FlSpot(1.0, dl[0].y));
      }

      final List<FlSpot> ul = List.generate(uploadHistory.length, (i) {
        return FlSpot(i.toDouble(), uploadHistory[i]);
      });
      if (ul.length == 1) {
        ul.add(FlSpot(1.0, ul[0].y));
      }

      _downloadSpots = dl;
      _uploadSpots = ul;
      _maxGraphLen = math.max(dl.length, ul.isNotEmpty ? ul.length : 1);
      notifyListeners();
    }
  }
}
