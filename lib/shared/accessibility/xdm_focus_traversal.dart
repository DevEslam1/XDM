import 'package:flutter/material.dart';

/// Custom focus traversal policy that respects RTL and logical grouping.
class XdmFocusTraversalPolicy extends ReadingOrderTraversalPolicy {}

/// Wraps a section with a focus scope for logical grouping.
class XdmFocusGroup extends StatelessWidget {
  final Widget child;
  final String? label;

  const XdmFocusGroup({super.key, required this.child, this.label});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: label,
      child: FocusTraversalGroup(
        policy: XdmFocusTraversalPolicy(),
        child: child,
      ),
    );
  }
}
