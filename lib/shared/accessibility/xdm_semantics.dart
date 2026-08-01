import 'package:flutter/material.dart';

/// Centralized accessibility helpers for XDM.
/// All interactive widgets SHOULD use these wrappers.
class XdmSemantics {
  XdmSemantics._();

  /// Wraps a tappable element with proper semantics.
  static Widget button({
    required Widget child,
    required String label,
    String? hint,
    bool enabled = true,
    VoidCallback? onTap,
  }) {
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      hint: hint,
      onTap: onTap,
      child: child,
    );
  }

  /// Wraps a progress indicator with live-region semantics.
  static Widget progress({
    required Widget child,
    required double value, // 0.0 to 1.0
    required String label,
  }) {
    final clamped = value.clamp(0.0, 1.0);
    final pct = (clamped * 100).toStringAsFixed(0);
    return Semantics(
      label: '$label: $pct percent',
      value: '$pct%',
      liveRegion: true,
      child: child,
    );
  }

  /// Wraps a status chip with proper role.
  static Widget statusChip({
    required Widget child,
    required String status,
  }) {
    return Semantics(
      label: 'Status: $status',
      container: true,
      child: child,
    );
  }

  /// Wraps a text field with proper form semantics.
  static Widget textField({
    required Widget child,
    required String label,
    String? hint,
    bool isRequired = false,
  }) {
    final effectiveLabel = isRequired ? '$label (Required)' : label;
    return Semantics(
      textField: true,
      label: effectiveLabel,
      hint: hint,
      child: child,
    );
  }

  /// Wraps a toggle/switch with proper semantics.
  static Widget toggle({
    required Widget child,
    required String label,
    required bool value,
    String? hint,
  }) {
    return Semantics(
      toggled: value,
      label: label,
      hint: hint ?? (value ? 'On' : 'Off'),
      child: child,
    );
  }

  /// Wraps a list item with proper traversal.
  static Widget listItem({
    required Widget child,
    required String label,
    String? hint,
    VoidCallback? onTap,
  }) {
    return Semantics(
      container: true,
      label: label,
      hint: hint,
      onTap: onTap,
      child: child,
    );
  }

  /// Wraps a heading for screen reader navigation.
  static Widget heading({
    required Widget child,
    required String label,
    int level = 1,
  }) {
    return Semantics(
      header: true,
      label: label,
      child: child,
    );
  }
}
