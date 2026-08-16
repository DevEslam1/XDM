import 'package:flutter/material.dart';

/// Detects platform high-contrast setting and exposes it to downstream builders.
class HighContrastDetector extends StatelessWidget {
  final Widget Function(BuildContext context, bool isHighContrast) builder;

  const HighContrastDetector({super.key, required this.builder});

  static bool isActive(BuildContext context) {
    return MediaQuery.maybeHighContrastOf(context) ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final isHighContrast = isActive(context);
    return builder(context, isHighContrast);
  }
}
