import 'package:flutter/material.dart';
import '../../core/app_theme.dart';

enum SlideFrom { up, down, left, right }

/// Provides a shared [AnimationController] for multiple child [FadeInSlide] widgets (FIX 21: U-08).
class FadeInSlideScope extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final Curve curve;

  const FadeInSlideScope({
    super.key,
    required this.child,
    this.duration = AppTheme.motionReveal,
    this.curve = AppTheme.motionCurve,
  });

  static FadeInSlideScopeInherited? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<FadeInSlideScopeInherited>();
  }

  @override
  State<FadeInSlideScope> createState() => FadeInSlideScopeState();
}

class FadeInSlideScopeState extends State<FadeInSlideScope>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();
    controller = AnimationController(vsync: this, duration: widget.duration);
    controller.forward();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeInSlideScopeInherited(
      controller: controller,
      curve: widget.curve,
      child: widget.child,
    );
  }
}

class FadeInSlideScopeInherited extends InheritedWidget {
  final AnimationController controller;
  final Curve curve;

  const FadeInSlideScopeInherited({
    super.key,
    required this.controller,
    required this.curve,
    required super.child,
  });

  @override
  bool updateShouldNotify(FadeInSlideScopeInherited oldWidget) =>
      controller != oldWidget.controller || curve != oldWidget.curve;
}

class FadeInSlide extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final Duration delay;
  final Offset offset;
  final SlideFrom from;
  final Curve curve;

  const FadeInSlide({
    super.key,
    required this.child,
    this.duration = AppTheme.motionReveal,
    this.delay = Duration.zero,
    this.offset = const Offset(0.0, 0.08),
    this.from = SlideFrom.up,
    this.curve = AppTheme.motionCurve,
  });

  @override
  State<FadeInSlide> createState() => FadeInSlideState();
}

class FadeInSlideState extends State<FadeInSlide>
    with SingleTickerProviderStateMixin {
  AnimationController? _localController;
  Animation<double>? _fade;
  Animation<Offset>? _slide;

  AnimationController? get activeLocalController => _localController;

  Offset get _begin {
    switch (widget.from) {
      case SlideFrom.up:
        return Offset(0, widget.offset.dy);
      case SlideFrom.down:
        return Offset(0, -widget.offset.dy);
      case SlideFrom.left:
        return Offset(-widget.offset.dx.abs() - 0.04, 0);
      case SlideFrom.right:
        return Offset(widget.offset.dx.abs() + 0.04, 0);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = FadeInSlideScope.maybeOf(context);
    if (scope != null) {
      _localController?.dispose();
      _localController = null;
      _fade = Tween<double>(
        begin: 0.0,
        end: 1.0,
      ).animate(CurvedAnimation(parent: scope.controller, curve: scope.curve));
      _slide = Tween<Offset>(
        begin: _begin,
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: scope.controller, curve: scope.curve));
    } else if (_localController == null) {
      _localController = AnimationController(
        vsync: this,
        duration: widget.duration,
      );
      _fade = Tween<double>(
        begin: 0.0,
        end: 1.0,
      ).animate(
          CurvedAnimation(parent: _localController!, curve: widget.curve));
      _slide = Tween<Offset>(
        begin: _begin,
        end: Offset.zero,
      ).animate(
          CurvedAnimation(parent: _localController!, curve: widget.curve));
      if (widget.delay == Duration.zero) {
        _localController!.forward();
      } else {
        Future.delayed(widget.delay, () {
          if (mounted && _localController != null) _localController!.forward();
        });
      }
    }
  }

  @override
  void dispose() {
    _localController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }
    if (_fade == null || _slide == null) {
      return widget.child;
    }
    return FadeTransition(
      opacity: _fade!,
      child: SlideTransition(position: _slide!, child: widget.child),
    );
  }
}
