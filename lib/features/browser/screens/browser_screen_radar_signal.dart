part of 'browser_screen.dart';

class _RadarSweep extends StatefulWidget {
  final Color color;
  final bool active;
  const _RadarSweep({required this.color, required this.active});
  @override
  State<_RadarSweep> createState() => _RadarSweepState();
}

class _RadarSweepState extends State<_RadarSweep>
    with
        SingleTickerProviderStateMixin,
        WidgetsBindingObserver,
        PausableLoopAnimation<_RadarSweep> {
  late AnimationController _c;
  @override
  AnimationController get loopController => _c;
  bool _allowed = true;
  @override
  bool get loopWanted => widget.active && _allowed;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 3));
    _allowed = modernAnimationsAllowed(context, respectSystemMotion: false);
    startPausableLoop();
  }

  @override
  void didUpdateWidget(_RadarSweep old) {
    super.didUpdateWidget(old);
    syncPausableLoop();
  }

  @override
  void dispose() {
    stopPausableLoop();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allowed = modernAnimationsAllowed(context, listen: true);
    if (allowed != _allowed) {
      _allowed = allowed;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) syncPausableLoop();
      });
    }

    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => CustomPaint(
        size: const Size(72, 72),
        painter: _RadarPainter(
          sweep: allowed ? _c.value * 2 * pi : 0,
          color: widget.color,
          active: widget.active,
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final double sweep;
  final Color color;
  final bool active;
  _RadarPainter(
      {required this.sweep, required this.color, required this.active});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2;
    final ringPaint = Paint()
      ..color = color.withValues(alpha: active ? 0.25 : 0.1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    for (final r in [maxR * 0.4, maxR * 0.7, maxR]) {
      canvas.drawCircle(center, r, ringPaint);
    }
    canvas.drawLine(Offset(center.dx - maxR, center.dy),
        Offset(center.dx + maxR, center.dy), ringPaint);
    canvas.drawLine(Offset(center.dx, center.dy - maxR),
        Offset(center.dx, center.dy + maxR), ringPaint);

    if (active) {
      final sweepPaint = Paint()
        ..shader = SweepGradient(
          startAngle: sweep - 0.9,
          endAngle: sweep,
          colors: [Colors.transparent, color.withValues(alpha: 0.35)],
        ).createShader(Rect.fromCircle(center: center, radius: maxR));
      canvas.drawArc(Rect.fromCircle(center: center, radius: maxR), sweep - 0.9,
          0.9, true, sweepPaint);

      final linePaint = Paint()
        ..color = color.withValues(alpha: 0.8)
        ..strokeWidth = 1.2;
      canvas.drawLine(
          center,
          Offset(center.dx + maxR * cos(sweep), center.dy + maxR * sin(sweep)),
          linePaint);

      final blipPaint = Paint()
        ..color = color.withValues(alpha: 0.7)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);
      canvas.drawCircle(
          Offset(center.dx + maxR * 0.55 * cos(sweep - 0.5),
              center.dy + maxR * 0.55 * sin(sweep - 0.5)),
          2,
          blipPaint);
      canvas.drawCircle(
          Offset(center.dx + maxR * 0.8 * cos(sweep - 1.2),
              center.dy + maxR * 0.8 * sin(sweep - 1.2)),
          1.5,
          blipPaint);
    }

    final dotPaint = Paint()
      ..color = color.withValues(alpha: active ? 0.9 : 0.3);
    canvas.drawCircle(center, 2.5, dotPaint);
  }

  @override
  bool shouldRepaint(covariant _RadarPainter old) =>
      old.sweep != sweep || old.active != active;
}

class _SnifferRadarCard extends StatelessWidget {
  final SettingsProvider settings;
  final bool isEnabled;
  final ValueChanged<bool> onToggle;
  const _SnifferRadarCard(
      {required this.settings,
      required this.isEnabled,
      required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final green = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final statusClr = isEnabled
        ? green
        : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted);

    return GlassCard(
      borderRadius: 20,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      isDarkMode: isDark,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _RadarSweep(color: isEnabled ? green : accent, active: isEnabled),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isRtl ? 'كاشف الملفات (Sniffer)' : 'Stream sniffer',
                  style: TextStyle(
                      fontFamily: 'Space Grotesk',
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      letterSpacing: 0.3,
                      color: accent),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    _LiveDot(color: statusClr),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isEnabled
                            ? (isRtl
                                ? 'الاعتراض التلقائي نشط'
                                : 'AUTO-INTERCEPT ACTIVE')
                            : (isRtl
                                ? 'الاعتراض التلقائي متوقف'
                                : 'AUTO-INTERCEPT DEACTIVATED'),
                        style: TextStyle(
                            fontFamily: 'Space Grotesk',
                            fontWeight: FontWeight.w800,
                            color: isDark
                                ? AppTheme.textPrimary
                                : AppTheme.lightTextPrimary,
                            fontSize: 12.5,
                            letterSpacing: 0.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  isRtl
                      ? 'يكتشف روابط التحميل المباشرة والوسائط تلقائياً'
                      : 'Sniffs media files and documents dynamically',
                  style: TextStyle(
                      fontFamily: 'Inter',
                      color:
                          isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                      fontSize: 10.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Transform.scale(
            scale: 0.82,
            child: Switch(
              value: isEnabled,
              activeThumbColor: Colors.white,
              activeTrackColor: green,
              inactiveThumbColor:
                  isDark ? const Color(0xFF7F7F90) : const Color(0xFF94A3B8),
              inactiveTrackColor:
                  isDark ? const Color(0x1AFFFFFF) : const Color(0x0D000000),
              trackOutlineColor: WidgetStateProperty.resolveWith(
                  (states) => Colors.transparent),
              onChanged: onToggle,
            ),
          ),
        ],
      ),
    );
  }
}

class _SignalFab extends StatefulWidget {
  final Color color;
  final IconData icon;
  final String label;
  final bool pulse;
  final bool isDark;
  final VoidCallback onPressed;
  final Object? heroTag;
  const _SignalFab(
      {required this.color,
      required this.icon,
      required this.label,
      required this.pulse,
      required this.isDark,
      required this.onPressed,
      this.heroTag});
  @override
  State<_SignalFab> createState() => _SignalFabState();
}

class _SignalFabState extends State<_SignalFab>
    with
        SingleTickerProviderStateMixin,
        WidgetsBindingObserver,
        PausableLoopAnimation<_SignalFab> {
  late AnimationController _c;
  @override
  AnimationController get loopController => _c;
  bool _allowed = true;
  @override
  bool get loopWanted => widget.pulse && _allowed;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400));
    _allowed = modernAnimationsAllowed(context, respectSystemMotion: false);
    startPausableLoop();
  }

  @override
  void didUpdateWidget(_SignalFab old) {
    super.didUpdateWidget(old);
    syncPausableLoop();
  }

  @override
  void dispose() {
    stopPausableLoop();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allowed = modernAnimationsAllowed(context, listen: true);
    if (allowed != _allowed) {
      _allowed = allowed;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) syncPausableLoop();
      });
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        if (widget.pulse && allowed)
          AnimatedBuilder(
            animation: _c,
            builder: (context, child) => Container(
              width: 52 + _c.value * 22,
              height: 52 + _c.value * 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: widget.color.withValues(alpha: 0.5 * (1 - _c.value)),
                  width: 1.5,
                ),
              ),
            ),
          ),
        FloatingActionButton.extended(
          heroTag: widget.heroTag,
          backgroundColor: widget.color,
          foregroundColor: Colors.white,
          elevation: 4,
          onPressed: widget.onPressed,
          icon: Icon(widget.icon),
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                    fontFamily: 'Space Grotesk',
                    fontSize: 12)),
          ),
        ),
      ],
    );
  }
}
