import 'package:flutter/material.dart';
import '../../../shared/design/dmx_design.dart';

class SettingsSectionHeader extends StatelessWidget {
  final String title;
  final Color? accentColor;
  final bool isDark;
  final EdgeInsetsGeometry padding;

  const SettingsSectionHeader({
    super.key,
    required this.title,
    this.accentColor,
    required this.isDark,
    this.padding = const EdgeInsets.only(top: 16, bottom: 8, left: 4, right: 4),
  });

  @override
  Widget build(BuildContext context) {
    return DmxSectionHeader(
      title: title,
      accentColor: accentColor,
      isDark: isDark,
      padding: padding,
    );
  }
}
