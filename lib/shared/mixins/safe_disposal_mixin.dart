import 'dart:async';
import 'package:flutter/widgets.dart';

/// Mixin for [State] classes to ensure comprehensive and leak-free disposal
/// of [StreamSubscription], [Timer], [AnimationController], [ChangeNotifier],
/// and other resource handles.
mixin SafeDisposalMixin<T extends StatefulWidget> on State<T> {
  final List<StreamSubscription<dynamic>> _safeSubscriptions = [];
  final List<Timer> _safeTimers = [];
  final List<AnimationController> _safeControllers = [];
  final List<ChangeNotifier> _safeNotifiers = [];

  /// Registers a [StreamSubscription] to be automatically cancelled on [dispose].
  S trackSubscription<S extends StreamSubscription<dynamic>>(S subscription) {
    _safeSubscriptions.add(subscription);
    return subscription;
  }

  /// Registers a [Timer] to be automatically cancelled on [dispose].
  Timer trackTimer(Timer timer) {
    _safeTimers.add(timer);
    return timer;
  }

  /// Registers an [AnimationController] to be automatically disposed on [dispose].
  AnimationController trackController(AnimationController controller) {
    _safeControllers.add(controller);
    return controller;
  }

  /// Registers a [ChangeNotifier] or [ValueNotifier] to be disposed on [dispose].
  N trackNotifier<N extends ChangeNotifier>(N notifier) {
    _safeNotifiers.add(notifier);
    return notifier;
  }

  @override
  void dispose() {
    for (final sub in _safeSubscriptions) {
      try {
        sub.cancel();
      } catch (_) {}
    }
    _safeSubscriptions.clear();

    for (final timer in _safeTimers) {
      try {
        timer.cancel();
      } catch (_) {}
    }
    _safeTimers.clear();

    for (final controller in _safeControllers) {
      try {
        controller.dispose();
      } catch (_) {}
    }
    _safeControllers.clear();

    for (final notifier in _safeNotifiers) {
      try {
        notifier.dispose();
      } catch (_) {}
    }
    _safeNotifiers.clear();

    super.dispose();
  }
}
