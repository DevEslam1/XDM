part of 'browser_screen.dart';

class _LiveDot extends StatefulWidget {
  final Color color;
  const _LiveDot({required this.color});
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200));
    // Fix #18: Use repeat(reverse: true) for continuous pulsing.
    // The old approach chained 2 cycles then stopped, making the dot appear frozen.
    _c.repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: 0.3 + _c.value * 0.4),
              blurRadius: 4 + _c.value * 4,
            ),
          ],
        ),
      ),
    );
  }
}

class _PulsingIconBadge extends StatefulWidget {
  final IconData icon;
  final Color color;
  final bool isDark;
  const _PulsingIconBadge(
      {required this.icon, required this.color, required this.isDark});
  @override
  State<_PulsingIconBadge> createState() => _PulsingIconBadgeState();
}

class _PulsingIconBadgeState extends State<_PulsingIconBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1600));
    // Fix #18: Use repeat(reverse: true) for continuous pulsing.
    // The old _runTwoCycles() ran exactly 2 cycles and then froze.
    _c.repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 44 + _c.value * 10,
            height: 44 + _c.value * 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: widget.color.withValues(alpha: 0.35 * (1 - _c.value)),
                width: 1.2,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(widget.icon, color: widget.color, size: 20),
          ),
        ],
      ),
    );
  }
}

class _CornerBracketBox extends StatelessWidget {
  final Widget child;
  final Color color;
  final bool isDark;
  const _CornerBracketBox(
      {required this.child, required this.color, required this.isDark});
  @override
  Widget build(BuildContext context) {
    final bracket = BorderSide(color: color.withValues(alpha: 0.6), width: 1.5);
    return Stack(
      children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.all(6),
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: (isDark ? AppTheme.background : AppTheme.lightBackground)
                .withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color:
                    isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                width: 0.7),
          ),
          child: child,
        ),
        Positioned(
            top: 0,
            left: 0,
            child: _Corner(side: _CornerSide.tl, border: bracket)),
        Positioned(
            top: 0,
            right: 0,
            child: _Corner(side: _CornerSide.tr, border: bracket)),
        Positioned(
            bottom: 0,
            left: 0,
            child: _Corner(side: _CornerSide.bl, border: bracket)),
        Positioned(
            bottom: 0,
            right: 0,
            child: _Corner(side: _CornerSide.br, border: bracket)),
      ],
    );
  }
}

enum _CornerSide { tl, tr, bl, br }

class _Corner extends StatelessWidget {
  final _CornerSide side;
  final BorderSide border;
  const _Corner({required this.side, required this.border});
  @override
  Widget build(BuildContext context) {
    const s = 12.0;
    return CustomPaint(
        size: const Size(s, s),
        painter: _CornerPainter(side: side, border: border));
  }
}

class _CornerPainter extends CustomPainter {
  final _CornerSide side;
  final BorderSide border;
  _CornerPainter({required this.side, required this.border});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = border.toPaint();
    final w = size.width;
    final h = size.height;
    switch (side) {
      case _CornerSide.tl:
        canvas.drawLine(Offset(0, h), const Offset(0, 0), paint);
        canvas.drawLine(const Offset(0, 0), Offset(w, 0), paint);
        break;
      case _CornerSide.tr:
        canvas.drawLine(Offset(w, h), Offset(w, 0), paint);
        canvas.drawLine(Offset(w, 0), const Offset(0, 0), paint);
        break;
      case _CornerSide.bl:
        canvas.drawLine(const Offset(0, 0), Offset(0, h), paint);
        canvas.drawLine(Offset(0, h), Offset(w, h), paint);
        break;
      case _CornerSide.br:
        canvas.drawLine(Offset(w, 0), Offset(w, h), paint);
        canvas.drawLine(Offset(w, h), Offset(0, h), paint);
        break;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ScanlineProgress extends StatefulWidget {
  final double progress;
  final bool isDark;
  const _ScanlineProgress({required this.progress, required this.isDark});
  @override
  State<_ScanlineProgress> createState() => _ScanlineProgressState();
}

class _ScanlineProgressState extends State<_ScanlineProgress>
    with
        SingleTickerProviderStateMixin,
        WidgetsBindingObserver,
        PausableLoopAnimation<_ScanlineProgress> {
  late AnimationController _c;
  @override
  AnimationController get loopController => _c;
  bool _allowed = true;
  @override
  bool get loopWanted => _allowed;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    _allowed = modernAnimationsAllowed(context, respectSystemMotion: false);
    startPausableLoop();
  }

  @override
  void dispose() {
    stopPausableLoop();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final allowed = modernAnimationsAllowed(context, listen: true);
    if (allowed != _allowed) {
      _allowed = allowed;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) syncPausableLoop();
      });
    }

    if (!allowed) {
      return LinearProgressIndicator(
        value: widget.progress,
        minHeight: 3,
        backgroundColor: Colors.transparent,
        color: accent.withValues(alpha: 0.85),
      );
    }

    return SizedBox(
      height: 3,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) => Stack(
          children: [
            LinearProgressIndicator(
              value: widget.progress,
              minHeight: 3,
              backgroundColor: Colors.transparent,
              color: accent.withValues(alpha: 0.85),
            ),
            Positioned(
              left: (widget.progress *
                      MediaQuery.of(context).size.width *
                      _c.value) -
                  30,
              child: Container(
                width: 30,
                height: 3,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    Colors.transparent,
                    accent.withValues(alpha: 0.9)
                  ]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
