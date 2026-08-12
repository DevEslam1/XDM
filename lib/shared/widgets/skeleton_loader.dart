import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../mixins/pausable_loop_animation.dart';

/// // UI-4: Theme-aware shimmer loading card placeholder.
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
    with
        SingleTickerProviderStateMixin,
        WidgetsBindingObserver,
        PausableLoopAnimation<SkeletonCard> {
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = isDark ? AppTheme.surface : AppTheme.lightSurface;
    final highlightColor = isDark ? AppTheme.cardBg : Colors.grey.shade300;

    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, child) {
          return Container(
            height: widget.height,
            decoration: BoxDecoration(
              color: Color.lerp(baseColor, highlightColor, _animation.value),
              borderRadius: BorderRadius.circular(widget.borderRadius),
              border: Border.all(
                color: isDark ? AppTheme.border : AppTheme.lightBorder,
                width: 1.0,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// // UI-4: Theme-aware loading list of skeleton cards.
class SkeletonList extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: padding,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: itemCount,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, __) => SkeletonCard(height: itemHeight),
    );
  }
}
