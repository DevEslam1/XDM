import 'package:flutter/material.dart';

import '../../core/utils/localization.dart';

/// Centralized accessibility helpers for XDM.
/// All interactive widgets SHOULD use these wrappers.
class XdmSemantics {
  XdmSemantics._();

  // FIX: These static helpers have no BuildContext, so strings are localized
  // via L10n.currentLang (settings language) instead of hardcoded English.
  static String _t(String key, [Map<String, dynamic>? args]) =>
      L10n.translate(L10n.currentLang, key, args: args);

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
    final clamped =
        (value.isNaN || value.isInfinite) ? 0.0 : value.clamp(0.0, 1.0);
    final pct = (clamped * 100).toStringAsFixed(0);
    return Semantics(
      label: label,
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
      label: _t('semantics_status', {'status': status}),
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
    final effectiveLabel =
        isRequired ? '$label ${_t('semantics_required')}' : label;
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
      hint: hint ?? _t(value ? 'semantics_on' : 'semantics_off'),
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
