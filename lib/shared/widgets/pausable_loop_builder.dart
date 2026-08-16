import 'package:flutter/widgets.dart';
import '../mixins/pausable_loop_animation.dart';

/// A wrapper widget that provides a looping [AnimationController] to a builder,
/// using the [PausableLoopAnimation] mixin to automatically pause/resume
/// based on app lifecycle and power state.
class PausableLoopBuilder extends StatefulWidget {
  final Duration duration;
  final Widget Function(BuildContext context, double value, Widget? child)
      builder;
  final Widget? child;

  const PausableLoopBuilder({
    super.key,
    required this.duration,
    required this.builder,
    this.child,
  });

  @override
  State<PausableLoopBuilder> createState() => _PausableLoopBuilderState();
}

class _PausableLoopBuilderState extends State<PausableLoopBuilder>
    with
        SingleTickerProviderStateMixin,
        WidgetsBindingObserver,
        PausableLoopAnimation<PausableLoopBuilder> {
  late final AnimationController _controller;

  @override
  AnimationController get loopController => _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );
    startPausableLoop();
  }

  @override
  void dispose() {
    stopPausableLoop();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) =>
          widget.builder(context, _controller.value, child),
      child: widget.child,
    );
  }
}
