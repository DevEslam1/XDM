import 'package:flutter/material.dart';

/// Wraps the app to handle text scaling properly.
class XdmTextScaler extends StatelessWidget {
  final Widget child;
  const XdmTextScaler({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(
          MediaQuery.of(context).textScaler.scale(1.0).clamp(0.8, 2.0),
        ),
      ),
      child: child,
    );
  }
}
