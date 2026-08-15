import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/services/download_engine.dart';
import '../../core/services/power_monitor.dart';
import '../mixins/pausable_loop_animation.dart';

/// Inherited provider for a single shared shimmer animation across all skeleton children.
class SkeletonShimmerScope extends InheritedWidget {
  final Animation<double> animation;

  const SkeletonShimmerScope({
    super.key,
    required this.animation,
    required super.child,
  });

  static Animation<double>? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<SkeletonShimmerScope>()
        ?.animation;
  }

  @override
  bool updateShouldNotify(SkeletonShimmerScope oldWidget) =>
      animation != oldWidget.animation;
}

/// Standalone or scope-aware skeleton card placeholder.
class SkeletonCard extends StatefulWidget {
  final double height;
  final double borderRadius;

  const SkeletonCard({
    super.key,
    this.height = 90.0,
    this.borderRadius = 14.0,
  });

  @override
  State<SkeletonCard> createState() => _SkeletonCardState();
}

class _SkeletonCardState extends State<SkeletonCard>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver, PausableLoopAnimation<SkeletonCard> {
  AnimationController? _localController;
  Animation<double>? _localAnimation;

  @override
  AnimationController get loopController =>
      _localController ?? AnimationController(vsync: this);

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final parentAnimation = SkeletonShimmerScope.maybeOf(context);
    if (parentAnimation == null && _localController == null) {
      _localController = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1200),
      );
      _localAnimation = Tween<double>(begin: 0.3, end: 0.7).animate(
        CurvedAnimation(parent: _localController!, curve: Curves.easeInOut),
      );
      startPausableLoop();
    }
  }

  @override
  void dispose() {
    if (_localController != null) {
      stopPausableLoop();
      _localController!.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sharedAnimation = SkeletonShimmerScope.maybeOf(context);
    final animation = sharedAnimation ?? _localAnimation;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = isDark ? AppTheme.surface : AppTheme.lightSurface;
    final highlightColor = isDark ? AppTheme.cardBg : Colors.grey.shade300;

    final borderColor = isDark ? AppTheme.border : AppTheme.lightBorder;

    if (animation == null || PowerMonitor.screenOff || DownloadEngine.isInBackground) {
      return Container(
        height: widget.height,
        decoration: BoxDecoration(
          color: baseColor,
          borderRadius: BorderRadius.circular(widget.borderRadius),
          border: Border.all(color: borderColor, width: 1.0),
        ),
      );
    }

    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          return Container(
            height: widget.height,
            decoration: BoxDecoration(
              color: Color.lerp(baseColor, highlightColor, animation.value),
              borderRadius: BorderRadius.circular(widget.borderRadius),
              border: Border.all(
                color: borderColor,
                width: 1.0,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Theme-aware loading list of skeleton cards backed by a single shared animation driver.
class SkeletonList extends StatefulWidget {
  final int itemCount;
  final double itemHeight;
  final EdgeInsetsGeometry padding;

  const SkeletonList({
    super.key,
    this.itemCount = 4,
    this.itemHeight = 90.0,
    this.padding = const EdgeInsets.all(16.0),
  });

  @override
  State<SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<SkeletonList>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver, PausableLoopAnimation<SkeletonList> {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  AnimationController get loopController => _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _animation = Tween<double>(begin: 0.3, end: 0.7).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
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
    return SkeletonShimmerScope(
      animation: _animation,
      child: RepaintBoundary(
        child: ListView.separated(
          padding: widget.padding,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: widget.itemCount,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (_, __) => SkeletonCard(height: widget.itemHeight),
        ),
      ),
    );
  }
}
