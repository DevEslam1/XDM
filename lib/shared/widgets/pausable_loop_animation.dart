import 'package:flutter/material.dart';
import '../../core/services/power_monitor.dart';

/// U-03: A widget that manages a looping animation controller with automatic
/// lifecycle and power awareness (pausing on background/inactive/screenOff and resuming on foreground).
class PausableLoopAnimation extends StatefulWidget {
  final Duration duration;
  final Widget Function(BuildContext context, double value, Widget? child)
      builder;
  final Widget? child;
  final bool autoStart;

  const PausableLoopAnimation({
    super.key,
    required this.duration,
    required this.builder,
    this.child,
    this.autoStart = true,
  });

  @override
  State<PausableLoopAnimation> createState() => _PausableLoopAnimationState();
}

class _PausableLoopAnimationState extends State<PausableLoopAnimation>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  bool _isBackgrounded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );

    if (widget.autoStart && !PowerMonitor.screenOff) {
      _controller.repeat();
    }

    PowerMonitor.screenStateStream.listen((screenOn) {
      if (!mounted) return;
      if (!screenOn) {
        _controller.stop(canceled: false);
      } else if (!_isBackgrounded && widget.autoStart) {
        _controller.repeat();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isBackgrounded = (state != AppLifecycleState.resumed);
    if (_isBackgrounded) {
      _controller.stop(canceled: false);
    } else if (!PowerMonitor.screenOff && widget.autoStart) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
