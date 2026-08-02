import 'package:flutter/widgets.dart';

/// Motion-reduction helpers.
///
/// Respects the platform "reduce motion" accessibility setting via
/// `MediaQuery.disableAnimationsOf`. When enabled, animations are removed or
/// shortened rather than played in full.
class XdmMotion {
  XdmMotion._();

  /// Whether the user has requested reduced motion on this device.
  static bool reducedMotionEnabled(BuildContext context) {
    return MediaQuery.disableAnimationsOf(context);
  }

  /// Returns [full] when motion is enabled, otherwise [reduced] (defaults to
  /// zero so the animation simply snaps to its end state).
  static Duration duration(
    BuildContext context,
    Duration full, {
    Duration reduced = Duration.zero,
  }) {
    return reducedMotionEnabled(context) ? reduced : full;
  }

  /// A ready-to-use duration token for the given context.
  static Duration base(BuildContext context) =>
      duration(context, const Duration(milliseconds: 240));

  /// Multiplies a given duration by [factor], respecting reduced motion.
  static Duration scaled(
    BuildContext context,
    Duration duration, {
    double factor = 1.0,
  }) {
    if (reducedMotionEnabled(context)) return Duration.zero;
    return Duration(milliseconds: (duration.inMilliseconds * factor).round());
  }

  /// Whether a repeating/pulsing animation should be paused entirely.
  static bool pauseAmbient(BuildContext context) =>
      reducedMotionEnabled(context);
}
