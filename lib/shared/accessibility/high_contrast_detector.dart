import 'package:flutter/material.dart';

/// Detects platform high-contrast setting and exposes it to downstream builders.
class HighContrastDetector extends StatelessWidget {
  final Widget Function(BuildContext context, bool isHighContrast) builder;

  const HighContrastDetector({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    final isHighContrast = MediaQuery.of(context).highContrast;
    return builder(context, isHighContrast);
  }
}
