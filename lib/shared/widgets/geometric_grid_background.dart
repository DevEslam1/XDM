// FIX-P1: GeometricGridBackground — Pause animation when backgrounded and guard ref counting
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/app_theme.dart';
import '../../core/services/background_gate.dart';
import '../../core/services/power_monitor.dart';
import '../../features/downloads/provider/download_provider.dart';
import '../../features/settings/provider/settings_provider.dart';

/// Shared ambient animation state — one timer drives all background instances.
class AmbientProgress with WidgetsBindingObserver {
  static final AmbientProgress instance = AmbientProgress._();
  factory AmbientProgress() => instance;

  AmbientProgress._() {
    WidgetsBinding.instance.addObserver(this);
    PowerMonitor.throttleFactorNotifier.addListener(_onPowerThrottleChanged);
    PowerMonitor.screenStateStream.listen((screenOn) {
      if (!screenOn) {
        _stopTimer();
      } else if (_refCount > 0 && !_isBackgrounded) {
        _startTimer();
      }
    });
  }

  final ValueNotifier<double> progress = ValueNotifier<double>(0);
  Timer? _timer;
  int _refCount = 0;
  int get refCount => _refCount;
  final _startTime = DateTime.now();
  bool _isBackgrounded = false;

  void _onPowerThrottleChanged() {
    if (_timer != null) {
      _stopTimer();
      _startTimer();
    }
  }

  void addRef() {
    _refCount++;
    _startTimer();
  }

  void stopAll() {
    _stopTimer();
  }

  void restartIfMounted() {
    if (_refCount > 0 && !_isBackgrounded && !PowerMonitor.screenOff) {
      _startTimer();
    }
  }

  void _startTimer() {
    if (!BackgroundGate.allowHeavyOps ||
        _isBackgrounded ||
        PowerMonitor.screenOff ||
        _refCount <= 0) {
      _stopTimer();
      return;
    }
    // FIX P1-1: Reduce repaint frequency from 1s to 5s
    const int intervalMs = 5000;
    _timer ??= Timer.periodic(const Duration(milliseconds: intervalMs), (_) {
      if (!BackgroundGate.allowHeavyOps ||
          _isBackgrounded ||
          PowerMonitor.screenOff ||
          _refCount <= 0) {
        _stopTimer();
        return;
      }
      final elapsed =
          DateTime.now().difference(_startTime).inMilliseconds / 1000;
      final newVal = (elapsed / 30) % 1.0;
      if ((newVal - progress.value).abs() >= 0.01) {
        progress.value = newVal;
      }
    });
  }

  void removeRef() {
    _refCount = math.max(0, _refCount - 1);
    if (_refCount == 0) {
      _stopTimer();
    }
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _isBackgrounded = true;
      _stopTimer();
    } else if (state == AppLifecycleState.resumed) {
      _isBackgrounded = false;
      if (_refCount > 0 && !PowerMonitor.screenOff) {
        _startTimer();
      }
    }
  }
}

typedef _AmbientProgress = AmbientProgress;

class GeometricGridBackground extends StatefulWidget {
  final Widget child;

  const GeometricGridBackground({super.key, required this.child});

  @override
  State<GeometricGridBackground> createState() =>
      _GeometricGridBackgroundState();
}

class _GeometricGridBackgroundState extends State<GeometricGridBackground>
    with WidgetsBindingObserver {
  bool _isVisible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AmbientProgress.instance.addRef();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      if (_isVisible) {
        setState(() {
          _isVisible = false;
        });
      }
    } else if (state == AppLifecycleState.resumed) {
      if (!_isVisible) {
        setState(() {
          _isVisible = true;
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AmbientProgress.instance.removeRef();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).size.width == 0) return widget.child;

    final isDark = context.select((SettingsProvider s) => s.isDarkMode);
    final isAmoled = context.select((SettingsProvider s) => s.isAmoledMode);
    final classicUi = context.select((SettingsProvider s) => s.classicUi);
    final reduceVisuals =
        context.select((SettingsProvider s) => s.reduceVisuals);
    final gridOpacity = context.select((SettingsProvider s) => s.gridOpacity);
    final bgColor = AppTheme.getBackground(isDark, isAmoled: isAmoled);

    // Skip ambient animation during active downloads
    final hasActiveDownloads = context.select(
      (DownloadProvider p) => p.downloadingTasksCount > 0,
    );

    if (classicUi ||
        reduceVisuals ||
        !_isVisible ||
        !BackgroundGate.allowHeavyOps ||
        hasActiveDownloads) {
      return Container(color: bgColor, child: widget.child);
    }

    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: ValueListenableBuilder<double>(
              valueListenable: _AmbientProgress().progress,
              builder: (context, progress, _) {
                return CustomPaint(
                  painter: _AmbientBlobPainter(
                    progress: progress,
                    isDark: isDark,
                    intensity: gridOpacity / 40.0,
                    bgColor: bgColor,
                    violetClr: violetClr,
                    blueClr: blueClr,
                  ),
                  size: Size.infinite,
                );
              },
            ),
          ),
        ),
        Positioned.fill(
          child: RepaintBoundary(
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

class _AmbientBlobPainter extends CustomPainter {
  final double progress;
  final bool isDark;
  final double intensity;
  final Color bgColor;
  final Color violetClr;
  final Color blueClr;

  final Paint _blobPaint = Paint();

  _AmbientBlobPainter({
    required this.progress,
    required this.isDark,
    required this.intensity,
    required this.bgColor,
    required this.violetClr,
    required this.blueClr,
  });

  void _drawSoftBlob(
    Canvas canvas,
    Size size,
    Offset center,
    Color color,
    double alpha,
    double radius,
  ) {
    if (alpha <= 0) return;
    _blobPaint.shader = RadialGradient(
      colors: [
        color.withValues(alpha: alpha),
        color.withValues(alpha: alpha * 0.4),
        color.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.3, 1.0],
      radius: 1.0,
    ).createShader(Rect.fromCircle(center: center, radius: radius));

    canvas.drawCircle(center, radius, _blobPaint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // FIX-P1: Early return if screenOff or intensity <= 0
    if (PowerMonitor.screenOff || intensity <= 0) {
      canvas.drawRect(Offset.zero & size, Paint()..color = bgColor);
      return;
    }

    // 1. Base Background
    canvas.drawRect(Offset.zero & size, Paint()..color = bgColor);

    // 2. Soft Drifting Blobs (2 blobs for optimal GPU performance)
    final t = progress * 2 * math.pi;

    // Violet Blob (Top Left)
    final vX = size.width * 0.2 + math.sin(t) * 40;
    final vY = size.height * 0.15 + math.cos(t) * 40;
    _drawSoftBlob(
      canvas,
      size,
      Offset(vX, vY),
      violetClr,
      (isDark ? 0.12 : 0.06) * intensity,
      size.width * 0.6,
    );

    // Blue Blob (Top Right / Center)
    final bX = size.width * 0.8 + math.cos(t * 0.8) * 50;
    final bY = size.height * 0.35 + math.sin(t * 0.8) * 50;
    _drawSoftBlob(
      canvas,
      size,
      Offset(bX, bY),
      blueClr,
      (isDark ? 0.10 : 0.05) * intensity,
      size.width * 0.5,
    );

    // 3. Subtle Vignette for Dark Mode
    if (isDark) {
      final vignettePaint = Paint()
        ..shader = RadialGradient(
          center: Alignment.center,
          radius: 0.9,
          colors: [
            Colors.transparent,
            Colors.transparent,
            Colors.black.withValues(alpha: 0.5),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
      canvas.drawRect(Offset.zero & size, vignettePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _AmbientBlobPainter oldDelegate) {
    return (oldDelegate.progress - progress).abs() > 0.01 ||
        oldDelegate.intensity != intensity ||
        oldDelegate.isDark != isDark;
  }
}
