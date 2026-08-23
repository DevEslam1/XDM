import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../settings/provider/settings_provider.dart';
import 'permission_request_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final PageController _pageController = PageController(viewportFraction: 1.0);
  int _currentPage = 0;
  static const int _pageCount = 5;

  late AnimationController _particleController;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _particleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat(reverse: true);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3500),
    )..repeat(reverse: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _particleController.stop();
      _pulseController.stop();
    } else if (state == AppLifecycleState.resumed) {
      _particleController.repeat(reverse: true);
      _pulseController.repeat(reverse: true);
    }
  }

  void _triggerHaptic(SettingsProvider settings) {
    if (settings.vibration) {
      HapticFeedback.lightImpact();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    _particleController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Color _getAccentColor(bool isDark, int page) {
    switch (page) {
      case 0:
        return isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
      case 1:
        return isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
      case 2:
        return isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
      case 3:
        return isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
      case 4:
        return isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
      default:
        return isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final secClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final currentAccent = _getAccentColor(isDark, _currentPage);

    return GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Directionality(
          textDirection:
              L10n.isRtl(context) ? TextDirection.rtl : TextDirection.ltr,
          child: SafeArea(
            child: Column(
              children: [
                // ─── Animated Header ───
                _buildHeader(settings, isDark, secClr, currentAccent),

                // ─── Floating Particles Layer ───
                Expanded(
                  child: Stack(
                    children: [
                      // Ambient floating particles
                      AnimatedBuilder(
                        animation: _particleController,
                        builder: (context, _) {
                          return CustomPaint(
                            size: Size.infinite,
                            painter: _FloatingParticlesPainter(
                              progress: _particleController.value,
                              color: currentAccent,
                              isDark: isDark,
                            ),
                          );
                        },
                      ),

                      // Ambient glow orb behind content
                      AnimatedBuilder(
                        animation: _pulseController,
                        builder: (context, _) {
                          return Center(
                            child: Container(
                              width: 260 + (_pulseController.value * 40),
                              height: 260 + (_pulseController.value * 40),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: RadialGradient(
                                  colors: [
                                    currentAccent.withValues(alpha: 0.08),
                                    currentAccent.withValues(alpha: 0.02),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),

                      // ─── Main PageView ───
                      PageView(
                        controller: _pageController,
                        physics: const BouncingScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics(),
                        ),
                        onPageChanged: (page) {
                          setState(() => _currentPage = page);
                          _triggerHaptic(settings);
                          if (settings.vibration) {
                            HapticFeedback.selectionClick();
                          }
                        },
                        children: [
                          _buildPage(
                            title: L10n.of(context, 'onboarding_title_0'),
                            subtitle: L10n.of(context, 'onboarding_sub_0'),
                            accentColor: currentAccent,
                            pageIndex: 0,
                            graphic: _QuickSetupCard(
                              accentColor: currentAccent,
                            ),
                            tagline: 'PERSONALIZE',
                          ),
                          _buildPage(
                            title: L10n.of(context, 'onboarding_title_1'),
                            subtitle: L10n.of(context, 'onboarding_sub_1'),
                            accentColor: currentAccent,
                            pageIndex: 1,
                            graphic: const _SpeedometerGraphic(),
                            tagline: 'MULTI-THREADED ENGINE',
                          ),
                          _buildPage(
                            title: L10n.of(context, 'onboarding_title_2'),
                            subtitle: L10n.of(context, 'onboarding_sub_2'),
                            accentColor: currentAccent,
                            pageIndex: 2,
                            graphic: const _PlatformGridGraphic(),
                            tagline: 'YOUTUBE & BEYOND',
                          ),
                          _buildPage(
                            title: L10n.of(context, 'onboarding_title_3'),
                            subtitle: L10n.of(context, 'onboarding_sub_3'),
                            accentColor: currentAccent,
                            pageIndex: 3,
                            graphic: const _TorrentGraphic(),
                            tagline: 'BITTORRENT POWER',
                          ),
                          _buildPage(
                            title: L10n.of(context, 'onboarding_title_4'),
                            subtitle: L10n.of(context, 'onboarding_sub_4'),
                            accentColor: currentAccent,
                            pageIndex: 4,
                            graphic: const _ControlPanelGraphic(),
                            tagline: 'FULL CONTROL',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // ─── Bottom Controls ───
                _buildBottomControls(settings, isDark, currentAccent),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(
    SettingsProvider settings,
    bool isDark,
    Color secClr,
    Color accent,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Logo + Brand
          Row(
            children: [
              // Animated logo mark
              AnimatedBuilder(
                animation: _pulseController,
                builder: (context, _) {
                  return Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [accent, accent.withValues(alpha: 0.6)],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: accent.withValues(
                            alpha: 0.3 + (_pulseController.value * 0.2),
                          ),
                          blurRadius: 8 + (_pulseController.value * 4),
                          spreadRadius: 0,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.bolt_rounded,
                      color: Colors.white,
                      size: 16,
                    ),
                  );
                },
              ),
              const SizedBox(width: 10),
              ShaderMask(
                shaderCallback: (bounds) => LinearGradient(
                  colors: [
                    accent,
                    isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                  ],
                ).createShader(bounds),
                child: const Text(
                  'XDM',
                  style: TextStyle(
                    color: Colors.white,
                    fontFamily: 'Space Grotesk',
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2.0,
                    fontSize: 16,
                  ),
                ),
              ),
            ],
          ),

          // Skip button
          if (_currentPage < _pageCount - 1)
            Semantics(
              button: true,
              label: 'Skip onboarding',
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () {
                  _triggerHaptic(settings);
                  settings.setShowOnboarding(false);
                  if (mounted) {
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (_) => const PermissionRequestScreen(),
                      ),
                    );
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: secClr.withValues(alpha: 0.3),
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    L10n.of(context, 'onboarding_skip'),
                    style: TextStyle(
                      color: secClr,
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBottomControls(
    SettingsProvider settings,
    bool isDark,
    Color accent,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20.0),
      child: Column(
        children: [
          // ─── Progress Bar (thin, elegant) ───
          AnimatedBuilder(
            animation: _pageController,
            builder: (context, _) {
              final page = _pageController.hasClients
                  ? (_pageController.page ?? _currentPage.toDouble())
                  : _currentPage.toDouble();
              return ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: SizedBox(
                  height: 3,
                  child: LinearProgressIndicator(
                    value: (page + 1) / _pageCount,
                    backgroundColor:
                        (isDark ? AppTheme.border : AppTheme.lightBorder)
                            .withValues(alpha: 0.3),
                    valueColor: AlwaysStoppedAnimation<Color>(accent),
                    minHeight: 3,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 20),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // ─── Page Indicators (dots + counter) ───
              Semantics(
                value: 'Page ${_currentPage + 1} of $_pageCount',
                container: true,
                child: Row(
                  children: [
                    // Dots
                    ...List.generate(_pageCount, (index) {
                      final isActive = _currentPage == index;

                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeOutCubic,
                        width: isActive ? 28 : 8,
                        height: 8,
                        margin: const EdgeInsetsDirectional.only(end: 6.0),
                        decoration: BoxDecoration(
                          color: isActive
                              ? accent
                              : (isDark
                                      ? AppTheme.border
                                      : AppTheme.lightBorder)
                                  .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(4),
                          boxShadow: isActive
                              ? [
                                  BoxShadow(
                                    color: accent.withValues(alpha: 0.4),
                                    blurRadius: 6,
                                    spreadRadius: 0,
                                  ),
                                ]
                              : [
                                  const BoxShadow(
                                    color: Colors.transparent,
                                    blurRadius: 0,
                                    spreadRadius: 0,
                                  ),
                                ],
                        ),
                      );
                    }),
                    const SizedBox(width: 12),
                    // Page counter
                    Text(
                      '${_currentPage + 1}/$_pageCount',
                      style: TextStyle(
                        fontFamily: 'Space Grotesk',
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: (isDark
                                ? AppTheme.textMuted
                                : AppTheme.lightTextMuted)
                            .withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),

              // ─── Next / Start Button ───
              Flexible(
                child: NeonGlowButton(
                  isFilled: true,
                  color: _currentPage == _pageCount - 1
                      ? (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
                      : accent,
                  onPressed: () {
                    _triggerHaptic(settings);
                    if (_currentPage < _pageCount - 1) {
                      _pageController.nextPage(
                        duration: const Duration(milliseconds: 500),
                        curve: Curves.easeInOutCubicEmphasized,
                      );
                    } else {
                      settings.setShowOnboarding(false);
                      if (mounted) {
                        Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                            builder: (_) => const PermissionRequestScreen(),
                          ),
                        );
                      }
                    }
                  },
                  text: _currentPage == _pageCount - 1
                      ? L10n.of(context, 'onboarding_start')
                      : L10n.of(context, 'onboarding_next'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPage({
    required String title,
    required String subtitle,
    required Color accentColor,
    required int pageIndex,
    required Widget graphic,
    required String tagline,
  }) {
    final isDark = Provider.of<SettingsProvider>(context).isDarkMode;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    return AnimatedBuilder(
      animation: _pageController,
      builder: (context, _) {
        final page = _pageController.hasClients
            ? (_pageController.page ?? _currentPage.toDouble())
            : _currentPage.toDouble();
        final parallaxOffset = (page - pageIndex) * 60;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // ─── Tagline Badge ───
              Transform.translate(
                offset: Offset(0, parallaxOffset * 0.3),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: accentColor.withValues(alpha: 0.4),
                      width: 1,
                    ),
                    color: accentColor.withValues(alpha: 0.06),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: accentColor,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: accentColor.withValues(alpha: 0.6),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        tagline,
                        style: TextStyle(
                          fontFamily: 'Space Grotesk',
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                          color: accentColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // ─── Graphic Card with Parallax ───
              Expanded(
                child: Center(
                  child: Transform.translate(
                    offset: Offset(0, parallaxOffset * 0.5),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: DmxBackdropFilter(
                        sigmaX: 12,
                        sigmaY: 12,
                        child: Container(
                          width: double.infinity,
                          constraints: const BoxConstraints(maxHeight: 260),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: accentColor.withValues(alpha: 0.15),
                              width: 1,
                            ),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                (isDark ? Colors.white : Colors.black)
                                    .withValues(
                                  alpha: isDark ? 0.04 : 0.02,
                                ),
                                accentColor.withValues(alpha: 0.03),
                                (isDark ? Colors.white : Colors.black)
                                    .withValues(
                                  alpha: isDark ? 0.02 : 0.01,
                                ),
                              ],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: accentColor.withValues(alpha: 0.08),
                                blurRadius: 30,
                                spreadRadius: -5,
                              ),
                            ],
                          ),
                          child: Center(child: graphic),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 32),

              // ─── Title with Gradient ───
              Transform.translate(
                offset: Offset(0, parallaxOffset * 0.7),
                child: ShaderMask(
                  shaderCallback: (bounds) => LinearGradient(
                    colors: [textClr, textClr.withValues(alpha: 0.8)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ).createShader(bounds),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                          fontSize: 22,
                          height: 1.3,
                        ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),

              const SizedBox(height: 14),

              // ─── Subtitle ───
              Transform.translate(
                offset: Offset(0, parallaxOffset * 0.8),
                child: Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: secClr,
                        fontSize: 13.5,
                        height: 1.6,
                        letterSpacing: 0.2,
                      ),
                  textAlign: TextAlign.center,
                ),
              ),

              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }
}

// ──────────────────────────────────────────────────────────────
// Floating Particles Background Painter
// ──────────────────────────────────────────────────────────────
class _ParticleData {
  final double baseX;
  final double baseY;
  final double speed;
  final double radius;
  final double phase;
  final double baseOpacity;

  const _ParticleData({
    required this.baseX,
    required this.baseY,
    required this.speed,
    required this.radius,
    required this.phase,
    required this.baseOpacity,
  });
}

class _LineData {
  final double x1;
  final double y1;
  final double x2;
  final double y2;
  const _LineData(this.x1, this.y1, this.x2, this.y2);
}

class _FloatingParticlesPainter extends CustomPainter {
  final double progress;
  final Color color;
  final bool isDark;

  static final List<_ParticleData> _particles = () {
    final random = Random(42);
    return List.generate(18, (_) {
      return _ParticleData(
        baseX: random.nextDouble(),
        baseY: random.nextDouble(),
        speed: 0.3 + random.nextDouble() * 0.7,
        radius: 1.0 + random.nextDouble() * 2.5,
        phase: random.nextDouble() * pi * 2,
        baseOpacity: 0.1 + random.nextDouble() * 0.25,
      );
    });
  }();

  static final List<_LineData> _lines = () {
    final random = Random(42);
    return List.generate(5, (_) {
      final x1 = random.nextDouble();
      final y1 = random.nextDouble();
      final dx = (random.nextDouble() - 0.5) * 0.3;
      final dy = (random.nextDouble() - 0.5) * 0.3;
      return _LineData(x1, y1, x1 + dx, y1 + dy);
    });
  }();

  _FloatingParticlesPainter({
    required this.progress,
    required this.color,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!size.isFinite || size.width <= 0 || size.height <= 0) return;

    for (final p in _particles) {
      final baseX = p.baseX * size.width;
      final baseY = p.baseY * size.height;
      final speed = p.speed;
      final radius = p.radius;
      final phase = p.phase;

      // Animate position
      final x = baseX + sin(progress * pi * 2 * speed + phase) * 20;
      final y = baseY - (progress * size.height * speed * 0.15) % size.height;
      final adjustedY = y < 0 ? y + size.height : y;

      final opacity = p.baseOpacity *
          (isDark ? 1.0 : 0.6) *
          (0.5 + 0.5 * sin(progress * pi * 2 + phase));

      final paint = Paint()
        ..color = color.withValues(alpha: opacity.clamp(0.0, 1.0))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.5);

      canvas.drawCircle(Offset(x, adjustedY), radius, paint);
    }

    // Draw a few connecting lines between nearby particles
    final linePaint = Paint()
      ..color = color.withValues(alpha: 0.04)
      ..strokeWidth = 0.5;

    for (int i = 0; i < _lines.length; i++) {
      final l = _lines[i];
      final animOffset = sin(progress * pi * 2 + i) * 10;
      canvas.drawLine(
        Offset(l.x1 * size.width + animOffset, l.y1 * size.height),
        Offset(l.x2 * size.width + animOffset, l.y2 * size.height),
        linePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ──────────────────────────────────────────────────────────────
// Graphic 1: Speedometer (multi-threaded engine) — ENHANCED
// ──────────────────────────────────────────────────────────────
class _SpeedometerGraphic extends StatefulWidget {
  const _SpeedometerGraphic();

  @override
  State<_SpeedometerGraphic> createState() => _SpeedometerGraphicState();
}

class _SpeedometerGraphicState extends State<_SpeedometerGraphic>
    with TickerProviderStateMixin {
  late AnimationController _speedController;
  late AnimationController _threadController;
  late AnimationController _glowController;

  @override
  void initState() {
    super.initState();
    _speedController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..repeat(reverse: true);

    _threadController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _speedController.dispose();
    _threadController.dispose();
    _glowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<SettingsProvider>(context).isDarkMode;
    final baseColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return Stack(
      alignment: Alignment.center,
      children: [
        // Thread activity indicators (orbiting dots)
        AnimatedBuilder(
          animation: _threadController,
          builder: (context, _) {
            return CustomPaint(
              size: const Size(200, 200),
              painter: _ThreadOrbitsPainter(
                progress: _threadController.value,
                color: baseColor,
                isDark: isDark,
              ),
            );
          },
        ),

        // Main speedometer
        AnimatedBuilder(
          animation: Listenable.merge([_speedController, _glowController]),
          builder: (context, _) {
            return CustomPaint(
              size: const Size(180, 180),
              painter: _SpeedometerPainter(
                animationValue: _speedController.value,
                glowValue: _glowController.value,
                color: baseColor,
                isDark: isDark,
              ),
            );
          },
        ),
      ],
    );
  }
}

class _ThreadOrbitsPainter extends CustomPainter {
  final double progress;
  final Color color;
  final bool isDark;

  _ThreadOrbitsPainter({
    required this.progress,
    required this.color,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const threadCount = 8;

    for (int i = 0; i < threadCount; i++) {
      final angle = (progress * pi * 2) + (i * (pi * 2 / threadCount));
      final orbitRadius = 85.0 + (i % 3) * 8.0;
      final x = center.dx + orbitRadius * cos(angle);
      final y = center.dy + orbitRadius * sin(angle);
      final dotSize = 2.0 + (i % 3) * 1.0;
      final opacity = 0.3 + 0.4 * sin(progress * pi * 4 + i).abs();

      // Trail
      final trailPaint = Paint()
        ..color = color.withValues(alpha: opacity * 0.2)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      canvas.drawCircle(Offset(x, y), dotSize + 2, trailPaint);

      // Dot
      final dotPaint = Paint()..color = color.withValues(alpha: opacity);
      canvas.drawCircle(Offset(x, y), dotSize, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _SpeedometerPainter extends CustomPainter {
  final double animationValue;
  final double glowValue;
  final Color color;
  final bool isDark;

  _SpeedometerPainter({
    required this.animationValue,
    required this.glowValue,
    required this.color,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 20;
    const startAngle = pi * 0.75;
    const sweepAngle = pi * 1.5;

    // Outer glow ring
    final outerGlow = Paint()
      ..color = color.withValues(alpha: 0.05 + glowValue * 0.05)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 16.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius + 4),
      startAngle,
      sweepAngle,
      false,
      outerGlow,
    );

    // Background track arc
    final bgPaint = Paint()
      ..color = (isDark ? AppTheme.border : AppTheme.lightBorder).withValues(
        alpha: 0.3,
      )
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      bgPaint,
    );

    // Gradient active arc (simulate with segments)
    final activeSweep = sweepAngle * animationValue;
    const segments = 30;
    for (int i = 0; i < segments; i++) {
      final segStart = startAngle + (activeSweep * i / segments);
      final segSweep = activeSweep / segments + 0.01;
      final segOpacity = 0.4 + 0.6 * (i / segments);

      final segPaint = Paint()
        ..color = color.withValues(alpha: segOpacity)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 6.0;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        segStart,
        segSweep,
        false,
        segPaint,
      );
    }

    // Needle
    final needleAngle = startAngle + activeSweep;
    final needleLength = radius - 25;
    final needleTip = Offset(
      center.dx + needleLength * cos(needleAngle),
      center.dy + needleLength * sin(needleAngle),
    );

    final needlePaint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, needleTip, needlePaint);

    // Needle tip glow
    final tipGlow = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawCircle(needleTip, 4, tipGlow);

    // Center hub
    final hubPaint = Paint()..color = color;
    canvas.drawCircle(center, 5, hubPaint);
    final hubInner = Paint()..color = isDark ? Colors.black : Colors.white;
    canvas.drawCircle(center, 2.5, hubInner);

    // Tick marks
    final tickPaint = Paint()
      ..color = (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted)
          .withValues(alpha: 0.35)
      ..strokeWidth = 1.2;

    for (int i = 0; i <= 24; i++) {
      final angle = startAngle + sweepAngle * (i / 24);
      final isMajor = i % 6 == 0;
      final innerR = radius - (isMajor ? 14 : 10);
      final outerR = radius - 6;

      canvas.drawLine(
        Offset(
          center.dx + innerR * cos(angle),
          center.dy + innerR * sin(angle),
        ),
        Offset(
          center.dx + outerR * cos(angle),
          center.dy + outerR * sin(angle),
        ),
        tickPaint..strokeWidth = isMajor ? 1.8 : 1.0,
      );
    }

    // Digital readout
    final speed = (animationValue * 124.8);
    final textPainter = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(
            text: speed.toStringAsFixed(1),
            style: TextStyle(
              color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
              fontFamily: 'Space Grotesk',
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
          TextSpan(
            text: '\nMB/S',
            style: TextStyle(
              color: color.withValues(alpha: 0.8),
              fontFamily: 'Space Grotesk',
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();

    textPainter.paint(
      canvas,
      Offset(center.dx - textPainter.width / 2, center.dy + 18),
    );

    // Thread count label
    final threadText = TextPainter(
      text: TextSpan(
        text: '${(animationValue * 16).ceil()} THREADS',
        style: TextStyle(
          color: (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted)
              .withValues(alpha: 0.6),
          fontFamily: 'Space Grotesk',
          fontSize: 8,
          fontWeight: FontWeight.w600,
          letterSpacing: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    threadText.paint(
      canvas,
      Offset(center.dx - threadText.width / 2, center.dy - 35),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ──────────────────────────────────────────────────────────────
// Graphic 2: Platform grid — ENHANCED with staggered reveal
// ──────────────────────────────────────────────────────────────
class _PlatformGridGraphic extends StatefulWidget {
  const _PlatformGridGraphic();

  @override
  State<_PlatformGridGraphic> createState() => _PlatformGridGraphicState();
}

class _PlatformGridGraphicState extends State<_PlatformGridGraphic>
    with TickerProviderStateMixin {
  late AnimationController _revealController;
  late AnimationController _floatController;

  final List<_PlatformInfo> _platforms = const [
    _PlatformInfo(Icons.play_circle_filled, 'YouTube', 0xFF),
    _PlatformInfo(Icons.facebook, 'Facebook', 0xFF),
    _PlatformInfo(Icons.alternate_email, 'Twitter/X', 0xFF),
    _PlatformInfo(Icons.music_video, 'TikTok', 0xFF),
    _PlatformInfo(Icons.camera_alt_outlined, 'Instagram', 0xFF),
    _PlatformInfo(Icons.videocam_outlined, 'Vimeo', 0xFF),
    _PlatformInfo(Icons.language, 'Web', 0xFF),
    _PlatformInfo(Icons.videogame_asset_outlined, 'Twitch', 0xFF),
  ];

  @override
  void initState() {
    super.initState();
    _revealController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat();

    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _revealController.dispose();
    _floatController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<SettingsProvider>(context).isDarkMode;
    final color = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;

    return AnimatedBuilder(
      animation: Listenable.merge([_revealController, _floatController]),
      builder: (context, child) {
        final progress = _revealController.value;
        final floatY = _floatController.value * 4;

        return Transform.translate(
          offset: Offset(0, -floatY),
          child: SizedBox(
            width: 230,
            height: 210,
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 0.85,
              ),
              itemCount: _platforms.length,
              itemBuilder: (context, index) {
                final revealAt = index / (_platforms.length + 2);
                final fadeProgress = ((progress - revealAt) / 0.2).clamp(
                  0.0,
                  1.0,
                );
                final scale = 0.6 + fadeProgress * 0.4;
                final isActive = (progress * _platforms.length).floor() %
                        _platforms.length ==
                    index;

                return Transform.scale(
                  scale: scale,
                  child: Opacity(
                    opacity: fadeProgress,
                    child: Container(
                      decoration: BoxDecoration(
                        color: isActive
                            ? color.withValues(alpha: 0.15)
                            : color.withValues(alpha: fadeProgress * 0.06),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isActive
                              ? color.withValues(alpha: 0.7)
                              : color.withValues(alpha: fadeProgress * 0.25),
                          width: isActive ? 1.2 : 0.7,
                        ),
                        boxShadow: isActive
                            ? [
                                BoxShadow(
                                  color: color.withValues(alpha: 0.2),
                                  blurRadius: 8,
                                  spreadRadius: -2,
                                ),
                              ]
                            : null,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _platforms[index].icon,
                            color: isActive
                                ? color
                                : color.withValues(alpha: fadeProgress * 0.8),
                            size: isActive ? 24 : 20,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _platforms[index].label,
                            style: TextStyle(
                              fontFamily: 'Space Grotesk',
                              fontSize: 7,
                              fontWeight: FontWeight.w700,
                              color: (isDark
                                      ? AppTheme.textSecondary
                                      : AppTheme.lightTextSecondary)
                                  .withValues(alpha: fadeProgress),
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _PlatformInfo {
  final IconData icon;
  final String label;
  final int colorVal;
  const _PlatformInfo(this.icon, this.label, this.colorVal);
}

// ──────────────────────────────────────────────────────────────
// Graphic 3: Torrent — ENHANCED with network visualization
// ──────────────────────────────────────────────────────────────
class _TorrentGraphic extends StatefulWidget {
  const _TorrentGraphic();

  @override
  State<_TorrentGraphic> createState() => _TorrentGraphicState();
}

class _TorrentGraphicState extends State<_TorrentGraphic>
    with TickerProviderStateMixin {
  late AnimationController _networkController;
  late AnimationController _progressController;

  @override
  void initState() {
    super.initState();
    _networkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat();

    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    )..repeat();
  }

  @override
  void dispose() {
    _networkController.dispose();
    _progressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<SettingsProvider>(context).isDarkMode;
    final color = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;

    return AnimatedBuilder(
      animation: Listenable.merge([_networkController, _progressController]),
      builder: (context, child) {
        final netProgress = _networkController.value;
        final dlProgress = _progressController.value;

        return SizedBox(
          width: 250,
          height: 210,
          child: Column(
            children: [
              // Network visualization
              SizedBox(
                height: 75,
                child: CustomPaint(
                  size: const Size(250, 75),
                  painter: _TorrentNetworkPainter(
                    progress: netProgress,
                    color: color,
                    isDark: isDark,
                  ),
                ),
              ),

              const SizedBox(height: 8),

              // Stats row
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildStatChip(
                    Icons.arrow_upward_rounded,
                    '${(netProgress * 42).floor()}',
                    'SEEDS',
                    color,
                    isDark,
                  ),
                  const SizedBox(width: 12),
                  _buildStatChip(
                    Icons.arrow_downward_rounded,
                    '${(netProgress * 28).floor()}',
                    'PEERS',
                    color,
                    isDark,
                  ),
                  const SizedBox(width: 12),
                  _buildStatChip(
                    Icons.speed_rounded,
                    (netProgress * 18.4).toStringAsFixed(1),
                    'MB/S',
                    color,
                    isDark,
                  ),
                ],
              ),

              const SizedBox(height: 8),

              // Download progress bar
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: color.withValues(alpha: 0.15),
                    width: 0.8,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.insert_drive_file_rounded,
                              color: color,
                              size: 14,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'ubuntu_24.04.iso',
                              style: TextStyle(
                                fontFamily: 'Space Grotesk',
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                                color: isDark
                                    ? AppTheme.textPrimary
                                    : AppTheme.lightTextPrimary,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          '${(dlProgress * 100).toStringAsFixed(0)}%',
                          style: TextStyle(
                            fontFamily: 'Space Grotesk',
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Progress bar
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: SizedBox(
                        height: 5,
                        child: LinearProgressIndicator(
                          value: dlProgress,
                          backgroundColor: color.withValues(alpha: 0.1),
                          valueColor: AlwaysStoppedAnimation<Color>(color),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${(dlProgress * 4.7).toStringAsFixed(1)} / 4.7 GB',
                          style: TextStyle(
                            fontFamily: 'Space Grotesk',
                            fontSize: 8,
                            color: (isDark
                                    ? AppTheme.textMuted
                                    : AppTheme.lightTextMuted)
                                .withValues(alpha: 0.7),
                          ),
                        ),
                        Text(
                          'ETA: ${((1 - dlProgress) * 12).toStringAsFixed(0)} min',
                          style: TextStyle(
                            fontFamily: 'Space Grotesk',
                            fontSize: 8,
                            color: (isDark
                                    ? AppTheme.textMuted
                                    : AppTheme.lightTextMuted)
                                .withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatChip(
    IconData icon,
    String value,
    String label,
    Color color,
    bool isDark,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2), width: 0.7),
      ),
      child: Column(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 10),
              const SizedBox(width: 3),
              Text(
                value,
                style: TextStyle(
                  fontFamily: 'Space Grotesk',
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color:
                      isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Space Grotesk',
              fontSize: 6.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
              color: (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted)
                  .withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _TorrentNetworkPainter extends CustomPainter {
  final double progress;
  final Color color;
  final bool isDark;

  _TorrentNetworkPainter({
    required this.progress,
    required this.color,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final random = Random(7);

    // Central node (you)
    final centerPaint = Paint()
      ..color = color
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawCircle(center, 6, centerPaint);

    final innerPaint = Paint()..color = isDark ? Colors.black : Colors.white;
    canvas.drawCircle(center, 3, innerPaint);

    // Peer nodes
    const peerCount = 10;
    final peers = <Offset>[];

    for (int i = 0; i < peerCount; i++) {
      final angle = (i / peerCount) * pi * 2 + progress * pi * 0.5;
      final dist = 30.0 + random.nextDouble() * 35.0;
      final peerPos = Offset(
        center.dx + dist * cos(angle),
        center.dy + dist * sin(angle) * 0.7,
      );
      peers.add(peerPos);

      // Connection line with data pulse
      final lineOpacity = 0.15 + 0.15 * sin(progress * pi * 4 + i).abs();
      final linePaint = Paint()
        ..color = color.withValues(alpha: lineOpacity)
        ..strokeWidth = 0.8;
      canvas.drawLine(center, peerPos, linePaint);

      // Data packet traveling along line
      final packetPos = (progress * 3 + i * 0.3) % 1.0;
      final packetX = center.dx + (peerPos.dx - center.dx) * packetPos;
      final packetY = center.dy + (peerPos.dy - center.dy) * packetPos;
      final packetPaint = Paint()
        ..color = color.withValues(alpha: 0.7)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
      canvas.drawCircle(Offset(packetX, packetY), 2, packetPaint);

      // Peer dot
      final peerPaint = Paint()
        ..color = color.withValues(
          alpha: 0.5 + 0.3 * sin(progress * pi * 2 + i),
        );
      canvas.drawCircle(peerPos, 3, peerPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ──────────────────────────────────────────────────────────────
// Graphic 4: Control Panel — ENHANCED
// ──────────────────────────────────────────────────────────────
class _ControlPanelGraphic extends StatefulWidget {
  const _ControlPanelGraphic();

  @override
  State<_ControlPanelGraphic> createState() => _ControlPanelGraphicState();
}

class _ControlPanelGraphicState extends State<_ControlPanelGraphic>
    with TickerProviderStateMixin {
  late AnimationController _cycleController;
  late AnimationController _toggleController;

  final List<_ControlItem> _controls = const [
    _ControlItem(Icons.dark_mode_rounded, 'Theme'),
    _ControlItem(Icons.schedule_rounded, 'Schedule'),
    _ControlItem(Icons.speed_rounded, 'Speed Limit'),
    _ControlItem(Icons.category_rounded, 'Auto-Sort'),
  ];

  final List<IconData> _categoryIcons = [
    Icons.movie_rounded,
    Icons.audiotrack_rounded,
    Icons.description_rounded,
    Icons.folder_zip_rounded,
    Icons.image_rounded,
  ];

  @override
  void initState() {
    super.initState();
    _cycleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    )..repeat();

    _toggleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _cycleController.dispose();
    _toggleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<SettingsProvider>(context).isDarkMode;
    final color = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final secClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    return AnimatedBuilder(
      animation: Listenable.merge([_cycleController, _toggleController]),
      builder: (context, child) {
        final progress = _cycleController.value;
        final toggleVal = _toggleController.value;

        return SizedBox(
          width: 250,
          height: 210,
          child: Column(
            children: [
              // Feature pills row
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(_controls.length, (index) {
                    final isActive = (progress * _controls.length).floor() %
                            _controls.length ==
                        index;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: isActive
                              ? color.withValues(alpha: 0.15)
                              : color.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isActive
                                ? color.withValues(alpha: 0.6)
                                : color.withValues(alpha: 0.15),
                            width: isActive ? 1.0 : 0.6,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _controls[index].icon,
                              color: isActive
                                  ? color
                                  : secClr.withValues(alpha: 0.5),
                              size: 10,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              _controls[index].label,
                              style: TextStyle(
                                fontFamily: 'Space Grotesk',
                                fontSize: 7,
                                fontWeight: FontWeight.w700,
                                color: isActive
                                    ? color
                                    : secClr.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
              ),

              const SizedBox(height: 14),

              // Main control panel card
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: color.withValues(alpha: 0.12),
                      width: 0.8,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Category icons with sequential highlight
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: List.generate(_categoryIcons.length, (index) {
                          final highlightStart = index * 0.18;
                          final highlightEnd = highlightStart + 0.15;
                          final isHighlighted = progress >= highlightStart &&
                              progress <= highlightEnd;

                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.all(7),
                            decoration: BoxDecoration(
                              color: isHighlighted
                                  ? color.withValues(alpha: 0.15)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isHighlighted
                                    ? color.withValues(alpha: 0.5)
                                    : color.withValues(alpha: 0.08),
                                width: 0.8,
                              ),
                              boxShadow: isHighlighted
                                  ? [
                                      BoxShadow(
                                        color: color.withValues(alpha: 0.15),
                                        blurRadius: 6,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Icon(
                              _categoryIcons[index],
                              color: isHighlighted
                                  ? color
                                  : (isDark
                                          ? AppTheme.textMuted
                                          : AppTheme.lightTextMuted)
                                      .withValues(alpha: 0.4),
                              size: 16,
                            ),
                          );
                        }),
                      ),

                      const SizedBox(height: 12),

                      // Toggle rows
                      _buildToggleRow(
                        Icons.wifi_rounded,
                        'Wi-Fi only',
                        toggleVal > 0.5,
                        color,
                        isDark,
                      ),
                      const SizedBox(height: 8),
                      _buildToggleRow(
                        Icons.nightlight_rounded,
                        'Night: 11PM – 7AM',
                        toggleVal <= 0.5,
                        color,
                        isDark,
                      ),
                      const SizedBox(height: 8),
                      _buildToggleRow(
                        Icons.fingerprint_rounded,
                        'Biometric lock',
                        true,
                        color,
                        isDark,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildToggleRow(
    IconData icon,
    String label,
    bool isOn,
    Color color,
    bool isDark,
  ) {
    return Row(
      children: [
        Icon(icon, color: color.withValues(alpha: 0.7), size: 13),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Space Grotesk',
              fontSize: 9,
              fontWeight: FontWeight.w500,
              color:
                  isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
            ),
          ),
        ),
        // Mini toggle
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 28,
          height: 15,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: isOn
                ? color.withValues(alpha: 0.3)
                : (isDark ? AppTheme.border : AppTheme.lightBorder).withValues(
                    alpha: 0.3,
                  ),
            border: Border.all(
              color: isOn
                  ? color.withValues(alpha: 0.5)
                  : (isDark ? AppTheme.border : AppTheme.lightBorder)
                      .withValues(alpha: 0.3),
              width: 0.8,
            ),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 300),
            alignment: isOn ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isOn
                    ? color
                    : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ControlItem {
  final IconData icon;
  final String label;
  const _ControlItem(this.icon, this.label);
}

// ──────────────────────────────────────────────────────────────
// Onboarding Quick Setup: language / theme / interface selectors
// Rendered as the graphic of the first onboarding page. Wires
// directly to SettingsProvider so choices apply live (the screen
// watches the provider and rebuilds).
// ──────────────────────────────────────────────────────────────
class _QuickSetupCard extends StatelessWidget {
  final Color accentColor;
  const _QuickSetupCard({required this.accentColor});

  void _haptic(SettingsProvider settings) {
    if (settings.vibration) HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final labelClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    return SizedBox(
      width: double.infinity,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ─── Language ───
              _buildLabel(
                L10n.of(context, 'onboarding_setup_language'),
                labelClr,
              ),
              const SizedBox(height: 6),
              _SegmentedSelector(
                accent: accentColor,
                isDark: isDark,
                selectedValue: settings.languageCode,
                options: const [
                  _SegmentOption(value: 'en', label: 'English'),
                  _SegmentOption(value: 'ar', label: 'العربية'),
                ],
                onSelected: (v) {
                  settings.setLanguageCode(v);
                  _haptic(settings);
                },
              ),
              const SizedBox(height: 10),
              // ─── Theme ───
              _buildLabel(L10n.of(context, 'onboarding_setup_theme'), labelClr),
              const SizedBox(height: 6),
              _SegmentedSelector(
                accent: accentColor,
                isDark: isDark,
                selectedValue: settings.themeMode,
                options: [
                  _SegmentOption(
                    value: 'light',
                    label: L10n.of(context, 'onboarding_theme_light'),
                    icon: Icons.wb_sunny_rounded,
                  ),
                  _SegmentOption(
                    value: 'dark',
                    label: L10n.of(context, 'onboarding_theme_dark'),
                    icon: Icons.nightlight_round,
                  ),
                  _SegmentOption(
                    value: 'amoled',
                    label: L10n.of(context, 'onboarding_theme_amoled'),
                    icon: Icons.contrast_rounded,
                  ),
                  _SegmentOption(
                    value: 'system',
                    label: L10n.of(context, 'onboarding_theme_system'),
                    icon: Icons.brightness_auto_rounded,
                  ),
                ],
                onSelected: (v) {
                  settings.setThemeMode(v);
                  _haptic(settings);
                },
              ),
              const SizedBox(height: 10),
              // ─── Interface mode ───
              _buildLabel(L10n.of(context, 'onboarding_setup_mode'), labelClr),
              const SizedBox(height: 6),
              _SegmentedSelector(
                accent: accentColor,
                isDark: isDark,
                selectedValue: settings.classicUi ? 'classic' : 'modern',
                options: [
                  _SegmentOption(
                    value: 'modern',
                    label: L10n.of(context, 'onboarding_mode_modern'),
                    icon: Icons.auto_awesome_rounded,
                  ),
                  _SegmentOption(
                    value: 'classic',
                    label: L10n.of(context, 'onboarding_mode_classic'),
                    icon: Icons.crop_square_rounded,
                  ),
                ],
                onSelected: (v) {
                  settings.setClassicUi(v == 'classic');
                  _haptic(settings);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLabel(String text, Color color) {
    return Text(
      text,
      style: TextStyle(
        fontFamily: 'Space Grotesk',
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
        color: color,
      ),
    );
  }
}

class _SegmentOption {
  final String value;
  final String label;
  final IconData? icon;
  const _SegmentOption({required this.value, required this.label, this.icon});
}

class _SegmentedSelector extends StatelessWidget {
  final List<_SegmentOption> options;
  final String selectedValue;
  final ValueChanged<String> onSelected;
  final Color accent;
  final bool isDark;

  const _SegmentedSelector({
    required this.options,
    required this.selectedValue,
    required this.onSelected,
    required this.accent,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final unselectedClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: (isDark ? Colors.white : Colors.black).withValues(
          alpha: isDark ? 0.04 : 0.03,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.15), width: 1),
      ),
      child: Row(
        children: options.map((o) {
          final selected = o.value == selectedValue;
          return Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onSelected(o.value),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: selected
                      ? accent.withValues(alpha: 0.9)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.4),
                            blurRadius: 8,
                            spreadRadius: -2,
                          ),
                        ]
                      : null,
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (o.icon != null) ...[
                        Icon(
                          o.icon,
                          size: 13,
                          color: selected
                              ? Colors.white
                              : unselectedClr.withValues(alpha: 0.7),
                        ),
                        const SizedBox(width: 5),
                      ],
                      Text(
                        o.label,
                        style: TextStyle(
                          fontFamily: 'Space Grotesk',
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: selected ? Colors.white : unselectedClr,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
