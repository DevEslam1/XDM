import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import 'xdm_motion.dart';

/// Wraps [child] with a high-visibility focus ring so keyboard and
/// screen-reader users always know where focus is. The ring is a 2px border
/// that fades in/out smoothly (honoring reduced-motion settings).
class XdmFocus extends StatefulWidget {
  final Widget child;
  final bool isDark;
  final double borderRadius;
  final EdgeInsetsGeometry padding;

  const XdmFocus({
    super.key,
    required this.child,
    required this.isDark,
    this.borderRadius = 14,
    this.padding = const EdgeInsets.all(2),
  });

  @override
  State<XdmFocus> createState() => _XdmFocusState();
}

class _XdmFocusState extends State<XdmFocus> {
  final FocusNode _focusNode = FocusNode();
  bool _focused = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ringColor =
        widget.isDark ? AppTheme.focusRing : AppTheme.lightFocusRing;
    final duration = XdmMotion.duration(
      context,
      const Duration(milliseconds: 160),
    );
    return Focus(
      focusNode: _focusNode,
      onFocusChange: (hasFocus) => setState(() => _focused = hasFocus),
      child: AnimatedContainer(
        duration: duration,
        padding: widget.padding,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          border: _focused
              ? Border.all(color: ringColor, width: 2)
              : Border.all(color: Colors.transparent, width: 2),
        ),
        child: widget.child,
      ),
    );
  }
}
