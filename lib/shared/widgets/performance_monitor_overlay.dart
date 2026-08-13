import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../core/services/performance_monitor.dart';
import '../../core/services/power_monitor.dart';

class PerformanceMonitorOverlay extends StatefulWidget {
  final Widget child;

  const PerformanceMonitorOverlay({super.key, required this.child});

  @override
  State<PerformanceMonitorOverlay> createState() =>
      _PerformanceMonitorOverlayState();
}

class _PerformanceMonitorOverlayState
    extends State<PerformanceMonitorOverlay> {
  Timer? _timer;
  double _fps = 60.0;
  bool _screenOff = false;

  @override
  void initState() {
    super.initState();
    if (kDebugMode) {
      _timer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (mounted) {
          setState(() {
            _fps = PerformanceMonitor.instance.currentFps;
            _screenOff = PowerMonitor.screenOff;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return widget.child;

    return Stack(
      children: [
        widget.child,
        Positioned(
          top: 40,
          right: 12,
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(200),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.cyan.withAlpha(150)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'FPS: ${_fps.toStringAsFixed(1)}',
                    style: const TextStyle(
                        color: Colors.cyanAccent,
                        fontSize: 11,
                        fontFamily: 'monospace'),
                  ),
                  Text(
                    'Screen: ${_screenOff ? "OFF" : "ON"}',
                    style: TextStyle(
                        color: _screenOff ? Colors.orangeAccent : Colors.greenAccent,
                        fontSize: 11,
                        fontFamily: 'monospace'),
                  ),
                  Text(
                    'BattSaver: ${PowerMonitor.batterySaverMode.name}',
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                        fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
