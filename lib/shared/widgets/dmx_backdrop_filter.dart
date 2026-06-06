import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../features/settings/provider/settings_provider.dart';

class DmxBackdropFilter extends StatelessWidget {
  final double sigmaX;
  final double sigmaY;
  final Widget child;

  const DmxBackdropFilter({
    super.key,
    required this.sigmaX,
    required this.sigmaY,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final reduceVisuals = Provider.of<SettingsProvider>(context).reduceVisuals;
    if (reduceVisuals) {
      return child;
    }
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: sigmaX, sigmaY: sigmaY),
      child: child,
    );
  }
}
