import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../features/settings/provider/settings_provider.dart';

/// Wraps the app to handle text scaling properly.
class XdmTextScaler extends StatelessWidget {
  final Widget child;
  const XdmTextScaler({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final mediaQuery = MediaQuery.of(context);
    return MediaQuery(
      data: mediaQuery.copyWith(
        textScaler: TextScaler.linear(
          (mediaQuery.textScaler.scale(1.0) * settings.textScaleFactor)
              .clamp(0.8, 2.5),
        ),
      ),
      child: child,
    );
  }
}
