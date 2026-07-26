import 'package:flutter/material.dart';
import '../../core/app_theme.dart';

enum SlideFrom { up, down, left, right }

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
  State<FadeInSlide> createState() => _FadeInSlideState();
}

class _FadeInSlideState extends State<FadeInSlide>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fade;
  late Animation<Offset> _slide;

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
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _fade = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: widget.curve));
    _slide = Tween<Offset>(
      begin: _begin,
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: widget.curve));
    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}
