import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/app_theme.dart';
import '../../core/services/power_monitor.dart';
import '../../features/settings/provider/settings_provider.dart';

/// Shared ambient animation state — one timer drives all background instances.
class _AmbientProgress with WidgetsBindingObserver {
  static final _instance = _AmbientProgress._();
  factory _AmbientProgress() => _instance;

  _AmbientProgress._() {
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

  void _startTimer() {
    if (_isBackgrounded || PowerMonitor.screenOff) {
      _stopTimer();
      return;
    }
    final int intervalMs = (PowerMonitor.throttleFactor < 0.8) ? 66 : 33;
    _timer ??= Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      final elapsed =
          DateTime.now().difference(_startTime).inMilliseconds / 1000;
      progress.value = (elapsed / 20) % 1.0;
    });
  }

  void removeRef() {
    _refCount--;
    if (_refCount <= 0) {
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
        state == AppLifecycleState.inactive) {
      _isBackgrounded = true;
      _stopTimer();
    } else if (state == AppLifecycleState.resumed) {
      _isBackgrounded = false;
      if (_refCount > 0) {
        _startTimer();
      }
    }
  }
}

class GeometricGridBackground extends StatefulWidget {
  final Widget child;

  const GeometricGridBackground({super.key, required this.child});

  @override
  State<GeometricGridBackground> createState() =>
      _GeometricGridBackgroundState();
}

class _GeometricGridBackgroundState extends State<GeometricGridBackground> {
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _AmbientProgress().addRef();
    _AmbientProgress().progress.addListener(_onProgress);
    _progress = _AmbientProgress().progress.value;
  }

  @override
  void dispose() {
    _AmbientProgress().progress.removeListener(_onProgress);
    _AmbientProgress().removeRef();
    super.dispose();
  }

  void _onProgress() {
    if (mounted) setState(() => _progress = _AmbientProgress().progress.value);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.select((SettingsProvider s) => s.isDarkMode);
    final isAmoled = context.select((SettingsProvider s) => s.isAmoledMode);
    final classicUi = context.select((SettingsProvider s) => s.classicUi);
    final gridOpacity = context.select((SettingsProvider s) => s.gridOpacity);
    final bgColor = AppTheme.getBackground(isDark, isAmoled: isAmoled);

    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;

    return Stack(
      children: [
        Positioned.fill(
          child: classicUi
              ? Container(color: bgColor)
              : RepaintBoundary(
                  child: CustomPaint(
                    painter: _AmbientBlobPainter(
                      progress: _progress,
                      isDark: isDark,
                      intensity: gridOpacity / 40.0,
                      bgColor: bgColor,
                      violetClr: violetClr,
                      blueClr: blueClr,
                      greenClr: greenClr,
                    ),
                    size: Size.infinite,
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
  final Color greenClr;

  final Paint _blobPaint = Paint();

  _AmbientBlobPainter({
    required this.progress,
    required this.isDark,
    required this.intensity,
    required this.bgColor,
    required this.violetClr,
    required this.blueClr,
    required this.greenClr,
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
      stops: const [0.0, 0.3, 1.0], // Very soft falloff
      radius: 1.0,
    ).createShader(Rect.fromCircle(center: center, radius: radius));

    canvas.drawCircle(center, radius, _blobPaint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Base Background
    canvas.drawRect(Offset.zero & size, Paint()..color = bgColor);

    if (intensity <= 0) return;

    // 2. Soft Drifting Blobs (Easy on the eyes)
    // Using sin/cos for smooth, continuous circular movement
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

    // Green Blob (Bottom Left)
    final gX = size.width * 0.3 + math.sin(t * 1.2) * 30;
    final gY = size.height * 0.85 + math.cos(t * 1.2) * 30;
    _drawSoftBlob(
      canvas,
      size,
      Offset(gX, gY),
      greenClr,
      (isDark ? 0.08 : 0.04) * intensity,
      size.width * 0.45,
    );

    // 3. Subtle Vignette for Dark Mode (focuses the eye to the center)
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
