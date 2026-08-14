// FIX-P4: BackdropFilter GPU overload — Limit concurrent BackdropFilters
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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

  @override
  State<DmxBackdropFilter> createState() => _DmxBackdropFilterState();
}

class _DmxBackdropFilterState extends State<DmxBackdropFilter> {
  bool _allocated = false;

  @override
  void initState() {
    super.initState();
    // FIX-P4: If _activeCount >= 3, skip BackdropFilter and render solid background
    if (!widget.forceSolid &&
        DmxBackdropFilter._activeCount < DmxBackdropFilter._maxConcurrent) {
      DmxBackdropFilter._activeCount++;
      _allocated = true;
    }
  }

  @override
  void dispose() {
    // FIX-P4: Decrement counter in dispose
    if (_allocated) {
      DmxBackdropFilter._activeCount--;
      _allocated = false;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // FIX-P4 / U-04: When PowerMonitor.screenOff or reduceVisuals or classicUi or not allocated, render solid fallback
    if (widget.forceSolid || PowerMonitor.screenOff || !_allocated) {
      return Container(
        color: Colors.black.withValues(alpha: 0.35),
        child: widget.child,
      );
    }
    final reduceVisuals = context.select(
      (SettingsProvider s) => s.reduceVisuals,
    );
    final classicUi = context.select((SettingsProvider s) => s.classicUi);
    if (reduceVisuals || classicUi) {
      return Container(
        color: Colors.black.withValues(alpha: 0.35),
        child: widget.child,
      );
    }
    final effectiveSigmaX = widget.sigmaX.clamp(0.0, 12.0);
    final effectiveSigmaY = widget.sigmaY.clamp(0.0, 12.0);
    return BackdropFilter(
      filter:
          ImageFilter.blur(sigmaX: effectiveSigmaX, sigmaY: effectiveSigmaY),
      child: widget.child,
    );
  }
}
