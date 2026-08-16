import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../core/services/background_gate.dart';
import '../../core/services/power_monitor.dart';
import '../../features/settings/provider/settings_provider.dart';

/// Whether "modern" looping/decorative animations should run, given the user's
/// interface preferences.
///
/// Returns `false` in classic mode, battery-saver mode (which forces classic),
/// or when the user asked to reduce visuals — so callers can render a static
/// variant and skip continuous animations to save battery and CPU.
///
/// Pass `listen: true` from a `build` method to rebuild when the preference
/// changes; keep the default `false` when reading outside of build
/// (e.g. `initState`).
bool modernAnimationsAllowed(
  BuildContext context, {
  bool listen = false,
  bool respectSystemMotion = true,
}) {
  final settings = Provider.of<SettingsProvider>(context, listen: listen);
  // Respect the system "reduce motion" accessibility setting. Pass
  // `respectSystemMotion: false` when called from `initState`, where
  // inherited-widget lookups are not allowed yet.
  if (respectSystemMotion &&
      (MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
    return false;
  }
  return !settings.effectiveClassicUi &&
      !settings.reduceVisuals &&
      BackgroundGate.allowHeavyOps;
}

/// Mixin for [State] classes that drive a continuously looping
/// [AnimationController] (shimmer, radar sweep, pulse ring, …).
///
/// It exists to save battery and CPU:
///
/// * The loop is **paused whenever the app leaves the foreground**
///   (`inactive` / `paused` / `detached`) and resumed on `resumed`, so these
///   "modern" browser animations don't keep spinning while the app is in the
///   background — e.g. during background downloads.
/// * The host decides whether the loop is wanted at all via [loopWanted]
///   (used to keep animations static in classic / battery-saver mode).
///
/// Usage from a host `State`:
/// ```dart
/// class _FooState extends State<Foo>
///     with SingleTickerProviderStateMixin, WidgetsBindingObserver,
///         PausableLoopAnimation<Foo> {
///   late final AnimationController _c = AnimationController(vsync: this, ...);
///   @override
///   AnimationController get loopController => _c;
///   @override
///   bool get loopWanted => widget.active && animationsAllowed(context);
///   @override
///   void initState() { super.initState(); startPausableLoop(); }
///   @override
///   void didUpdateWidget(Foo old) { super.didUpdateWidget(old); syncPausableLoop(); }
///   @override
///   void dispose() { stopPausableLoop(); _c.dispose(); super.dispose(); }
/// }
/// ```
mixin PausableLoopAnimation<T extends StatefulWidget>
    on State<T>, WidgetsBindingObserver {
  /// The looping controller owned by the host state.
  AnimationController get loopController;

  /// Whether the loop should run while the app is in the foreground.
  /// Override to gate on classic/battery-saver mode, `widget.active`, etc.
  bool get loopWanted {
    try {
      if (SettingsProvider.instance.batterySaverMode) return false;
    } catch (e) {
      assert(() {
        debugPrint('[PausableLoopAnimation] SettingsProvider not ready: $e');
        return true;
      }());
    }
    return true;
  }

  bool _foreground = true;
  StreamSubscription<bool>? _screenSub;

  /// Registers the lifecycle observer and starts the loop if wanted.
  /// Call once from `initState` after the controller is created.
  void startPausableLoop() {
    WidgetsBinding.instance.addObserver(this);
    _screenSub = PowerMonitor.screenStateStream.listen((_) => _sync());
    _sync();
  }

  /// Re-evaluates whether the loop should be running. Call whenever
  /// [loopWanted] may have changed (e.g. from `didUpdateWidget`).
  void syncPausableLoop() => _sync();

  /// Removes the lifecycle observer. Call from `dispose` before disposing
  /// the controller.
  void stopPausableLoop() {
    WidgetsBinding.instance.removeObserver(this);
    _screenSub?.cancel();
  }

  void _sync() {
    if (!mounted) return;
    bool batterySaver = false;
    try {
      batterySaver = SettingsProvider.instance.batterySaverMode;
    } catch (e) {
      assert(() {
        debugPrint('[PausableLoopAnimation] SettingsProvider not ready: $e');
        return true;
      }());
    }
    final shouldRun = _foreground &&
        loopWanted &&
        !batterySaver &&
        !PowerMonitor.screenOff &&
        BackgroundGate.allowHeavyOps;
    try {
      if (shouldRun) {
        if (!loopController.isAnimating) loopController.repeat();
      } else {
        if (loopController.isAnimating) loopController.stop();
      }
    } catch (e) {
      assert(() {
        debugPrint(
            '[PausableLoopAnimation] Controller disposed or ticker removed: $e');
        return true;
      }());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (!mounted) return;
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }
}
