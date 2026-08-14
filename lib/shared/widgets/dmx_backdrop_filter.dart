import 'dart:math';
import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import '../../core/services/background_gate.dart';
import '../../core/services/power_monitor.dart';
import '../../features/settings/provider/settings_provider.dart';

class DmxBackdropFilter extends StatefulWidget {
  final double sigmaX;
  final double sigmaY;
  final Widget child;
  final bool forceSolid;

  const DmxBackdropFilter({
    super.key,
    required this.sigmaX,
    required this.sigmaY,
    required this.child,
    this.forceSolid = false,
  });

  static int _activeCount = 0;
  static const int _maxConcurrent = 3;

  @visibleForTesting
  static int get activeCount => _activeCount;

  @visibleForTesting
  static void resetActiveCount() => _activeCount = 0;

  @override
  State<DmxBackdropFilter> createState() => _DmxBackdropFilterState();
}

class _DmxBackdropFilterState extends State<DmxBackdropFilter> {
  bool _allocated = false;
  ImageFilter? _cachedFilter;
  double? _lastSigmaX;
  double? _lastSigmaY;

  bool get _isLowEndDevice {
    return _cachedIsLowEnd ??= _detectLowEnd();
  }
  static bool? _cachedIsLowEnd;

  static bool _detectLowEnd() {
    try {
      final scheduler = SchedulerBinding.instance;
      final view = scheduler.platformDispatcher.implicitView;
      if (view == null) return false;
      final size = view.physicalSize;
      final ratio = view.devicePixelRatio;
      if (ratio <= 0) return false;
      final logicalW = size.width / ratio;
      // Heuristic: very low resolution + low DPR = low-end
      return logicalW < 400 && ratio <= 2.0;
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _tryAllocate();
  }

  void _tryAllocate() {
    if (!kIsWeb &&
        !widget.forceSolid &&
        !_isLowEndDevice &&
        BackgroundGate.allowHeavyOps &&
        !PowerMonitor.screenOff &&
        DmxBackdropFilter._activeCount < DmxBackdropFilter._maxConcurrent) {
      DmxBackdropFilter._activeCount++;
      _allocated = true;
    }
  }

  @override
  void dispose() {
    if (_allocated) {
      DmxBackdropFilter._activeCount = max(0, DmxBackdropFilter._activeCount - 1);
      _allocated = false;
    }
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_allocated && (kIsWeb || !BackgroundGate.allowHeavyOps || PowerMonitor.screenOff)) {
      DmxBackdropFilter._activeCount = max(0, DmxBackdropFilter._activeCount - 1);
      _allocated = false;
    } else if (!_allocated && !kIsWeb && BackgroundGate.allowHeavyOps && !PowerMonitor.screenOff) {
      _tryAllocate();
    }
  }

  @override
  Widget build(BuildContext context) {
    // FIX-P4 / U-04 / P0-GPU / M-PLT-03: When on Web, low-end, PowerMonitor.screenOff, !BackgroundGate.allowHeavyOps, reduceVisuals, classicUi, or not allocated, render solid fallback
    if (kIsWeb ||
        _isLowEndDevice ||
        widget.forceSolid ||
        PowerMonitor.screenOff ||
        !BackgroundGate.allowHeavyOps ||
        !_allocated) {
      return Container(
        color: Colors.black.withValues(alpha: 0.35),
        child: widget.child,
      );
    }
    bool reduceVisuals = false;
    bool classicUi = false;
    try {
      reduceVisuals = context.select(
        (SettingsProvider s) => s.reduceVisuals,
      );
      classicUi = context.select((SettingsProvider s) => s.classicUi);
    } catch (_) {
      try {
        reduceVisuals = SettingsProvider.instance.reduceVisuals;
        classicUi = SettingsProvider.instance.classicUi;
      } catch (_) {}
    }
    if (reduceVisuals || classicUi) {
      return Container(
        color: Colors.black.withValues(alpha: 0.35),
        child: widget.child,
      );
    }
    final effectiveSigmaX = widget.sigmaX.clamp(0.0, 12.0);
    final effectiveSigmaY = widget.sigmaY.clamp(0.0, 12.0);

    // FIX M-UI-08: Cache ImageFilter instance to avoid allocation overhead on every rebuild
    if (_cachedFilter == null ||
        _lastSigmaX != effectiveSigmaX ||
        _lastSigmaY != effectiveSigmaY) {
      _cachedFilter = ImageFilter.blur(
        sigmaX: effectiveSigmaX,
        sigmaY: effectiveSigmaY,
      );
      _lastSigmaX = effectiveSigmaX;
      _lastSigmaY = effectiveSigmaY;
    }

    return BackdropFilter(
      filter: _cachedFilter!,
      child: widget.child,
    );
  }
}
