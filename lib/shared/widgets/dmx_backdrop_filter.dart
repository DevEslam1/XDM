import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/power_monitor.dart';
import '../../features/settings/provider/settings_provider.dart';

class DmxBackdropFilter extends StatefulWidget {
  final double sigmaX;
  final double sigmaY;
  final Widget child;

  const DmxBackdropFilter({
    super.key,
    required this.sigmaX,
    required this.sigmaY,
    required this.child,
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
    if (DmxBackdropFilter._activeCount < DmxBackdropFilter._maxConcurrent) {
      DmxBackdropFilter._activeCount++;
      _allocated = true;
    }
  }

  @override
  void dispose() {
    if (_allocated) {
      DmxBackdropFilter._activeCount--;
      _allocated = false;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (PowerMonitor.screenOff || !_allocated) {
      return widget.child;
    }
    final reduceVisuals = context.select(
      (SettingsProvider s) => s.reduceVisuals,
    );
    final classicUi = context.select((SettingsProvider s) => s.classicUi);
    if (reduceVisuals || classicUi) {
      return widget.child;
    }
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: widget.sigmaX, sigmaY: widget.sigmaY),
      child: widget.child,
    );
  }
}
