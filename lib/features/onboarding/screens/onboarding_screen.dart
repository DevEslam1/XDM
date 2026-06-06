import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../../shared/widgets/main_navigation_container.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../settings/provider/settings_provider.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  void _triggerHaptic(SettingsProvider settings) {
    if (settings.vibration) {
      HapticFeedback.lightImpact();
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    return GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Directionality(
          textDirection: L10n.isRtl(context) ? TextDirection.rtl : TextDirection.ltr,
          child: SafeArea(
            child: Column(
              children: [
                // Header (Branding & Skip button)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'DMX // CORE INIT',
                        style: TextStyle(
                          color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                          fontFamily: 'Space Grotesk',
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                          fontSize: 14,
                        ),
                      ),
                      if (_currentPage < 2)
                        TextButton(
                          onPressed: () {
                            _triggerHaptic(settings);
                            settings.setShowOnboarding(false);
                            if (mounted) {
                              Navigator.of(context).pushReplacement(
                                MaterialPageRoute(
                                  builder: (_) => const MainNavigationContainer(),
                                ),
                              );
                            }
                          },
                          child: Text(
                            L10n.of(context, 'clipboard_ignore'),
                            style: TextStyle(
                              color: secClr,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                // Main PageView area
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    onPageChanged: (page) {
                      setState(() {
                        _currentPage = page;
                      });
                      _triggerHaptic(settings);
                    },
                    children: [
                      _buildPage(
                        title: L10n.of(context, 'onboarding_title_1'),
                        subtitle: L10n.of(context, 'onboarding_sub_1'),
                        accentColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                        graphic: const _SpeedometerGraphic(),
                      ),
                      _buildPage(
                        title: L10n.of(context, 'onboarding_title_2'),
                        subtitle: L10n.of(context, 'onboarding_sub_2'),
                        accentColor: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                        graphic: const _CategoryGridGraphic(),
                      ),
                      _buildPage(
                        title: L10n.of(context, 'onboarding_title_3'),
                        subtitle: L10n.of(context, 'onboarding_sub_3'),
                        accentColor: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                        graphic: const _TelemetryGraphic(),
                      ),
                    ],
                  ),
                ),

                // Pagination Indicator & Next controls
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 24.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Page Indicators
                      Row(
                        children: List.generate(3, (index) {
                          final isActive = _currentPage == index;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            width: isActive ? 24 : 8,
                            height: 8,
                            margin: const EdgeInsets.only(right: 6.0),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue)
                                  : (isDark ? AppTheme.border : AppTheme.lightBorder),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          );
                        }),
                      ),

                      // Next/Start Button
                      NeonGlowButton(
                        isFilled: true,
                        color: _currentPage == 2
                            ? (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
                            : (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue),
                        onPressed: () {
                          _triggerHaptic(settings);
                          if (_currentPage < 2) {
                            _pageController.nextPage(
                              duration: const Duration(milliseconds: 400),
                              curve: Curves.easeInOutCubic,
                            );
                          } else {
                            settings.setShowOnboarding(false);
                            if (mounted) {
                              Navigator.of(context).pushReplacement(
                                MaterialPageRoute(
                                  builder: (_) => const MainNavigationContainer(),
                                ),
                              );
                            }
                          }
                        },
                        text: _currentPage == 2
                            ? L10n.of(context, 'onboarding_start')
                            : L10n.of(context, 'onboarding_next'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPage({
    required String title,
    required String subtitle,
    required Color accentColor,
    required Widget graphic,
  }) {
    final isDark = Provider.of<SettingsProvider>(context).isDarkMode;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Graphic Box
          Expanded(
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: DmxBackdropFilter(
                  sigmaX: 10,
                  sigmaY: 10,
                  child: Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 280),
                    decoration: AppTheme.glassDecoration(
                      borderRadius: 28,
                      tintColor: accentColor,
                      tintOpacity: 0.03,
                      isDark: isDark,
                    ),
                    child: Center(child: graphic),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 40),
          // Texts
          Text(
            title,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: textClr,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                  fontSize: 20,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: secClr,
                  fontSize: 13,
                  height: 1.5,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

// Graphic Component 1: Speedometer animation
class _SpeedometerGraphic extends StatefulWidget {
  const _SpeedometerGraphic();

  @override
  State<_SpeedometerGraphic> createState() => _SpeedometerGraphicState();
}

class _SpeedometerGraphicState extends State<_SpeedometerGraphic>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<SettingsProvider>(context).isDarkMode;
    final baseColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          size: const Size(180, 180),
          painter: _SpeedometerPainter(
            animationValue: _controller.value,
            color: baseColor,
            isDark: isDark,
          ),
        );
      },
    );
  }
}

class _SpeedometerPainter extends CustomPainter {
  final double animationValue;
  final Color color;
  final bool isDark;

  _SpeedometerPainter({
    required this.animationValue,
    required this.color,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 16;

    // Background track arc
    final bgPaint = Paint()
      ..color = (isDark ? AppTheme.border : AppTheme.lightBorder).withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      3.14 * 0.85,
      3.14 * 1.3,
      false,
      bgPaint,
    );

    // Active speed arc
    final activePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 8.0;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      3.14 * 0.85,
      3.14 * 1.3 * animationValue,
      false,
      activePaint,
    );

    // Speed indicator glow
    if (isDark) {
      final glowPaint = Paint()
        ..color = color.withValues(alpha: 0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 20.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        3.14 * 0.85,
        3.14 * 1.3 * animationValue,
        false,
        glowPaint,
      );
    }

    // Dial ticking dashes
    final tickPaint = Paint()
      ..color = (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted).withValues(alpha: 0.4)
      ..strokeWidth = 1.5;

    for (int i = 0; i <= 20; i++) {
      final angle = (3.14 * 0.85) + (3.14 * 1.3) * (i / 20);
      final offsetInner = Offset(
        center.dx + (radius - 14) * cos(angle),
        center.dy + (radius - 14) * sin(angle),
      );
      final offsetOuter = Offset(
        center.dx + (radius - 6) * cos(angle),
        center.dy + (radius - 6) * sin(angle),
      );
      canvas.drawLine(offsetInner, offsetOuter, tickPaint);
    }

    // Core digital speed readout mock
    final textPainter = TextPainter(
      text: TextSpan(
        text: '${(animationValue * 96.5).toStringAsFixed(1)}\nMB/S',
        style: TextStyle(
          color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
          fontFamily: 'Space Grotesk',
          fontSize: 16,
          fontWeight: FontWeight.bold,
          height: 1.2,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(center.dx - textPainter.width / 2, center.dy - textPainter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// Graphic Component 2: Categories mock
class _CategoryGridGraphic extends StatefulWidget {
  const _CategoryGridGraphic();

  @override
  State<_CategoryGridGraphic> createState() => _CategoryGridGraphicState();
}

class _CategoryGridGraphicState extends State<_CategoryGridGraphic>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<SettingsProvider>(context).isDarkMode;
    final color = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final progress = _controller.value;
        return Container(
          width: 220,
          height: 160,
          padding: const EdgeInsets.all(12),
          child: GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 1.0,
            ),
            itemCount: 6,
            itemBuilder: (context, index) {
              final activeIndex = (progress * 6).floor();
              final isActive = index == activeIndex;
              final itemColor = isActive
                  ? color
                  : (isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder);

              return Container(
                decoration: BoxDecoration(
                  color: isActive ? color.withValues(alpha: 0.1) : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: itemColor, width: isActive ? 1.5 : 0.8),
                  boxShadow: isActive && isDark
                      ? [
                          BoxShadow(
                            color: color.withValues(alpha: 0.15),
                            blurRadius: 8.0,
                          ),
                        ]
                      : null,
                ),
                child: Center(
                  child: Icon(
                    _getIconForIndex(index),
                    color: isActive
                        ? color
                        : (isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary),
                    size: 20,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  IconData _getIconForIndex(int index) {
    switch (index) {
      case 0:
        return Icons.movie_outlined;
      case 1:
        return Icons.audiotrack_outlined;
      case 2:
        return Icons.description_outlined;
      case 3:
        return Icons.folder_zip_outlined;
      case 4:
        return Icons.android_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }
}

// Graphic Component 3: Telemetry lines animation
class _TelemetryGraphic extends StatefulWidget {
  const _TelemetryGraphic();

  @override
  State<_TelemetryGraphic> createState() => _TelemetryGraphicState();
}

class _TelemetryGraphicState extends State<_TelemetryGraphic>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<SettingsProvider>(context).isDarkMode;
    final textColor = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final panelBg = isDark ? AppTheme.background : AppTheme.lightBackground;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final progress = _controller.value;
        return Container(
          width: 240,
          height: 180,
          margin: const EdgeInsets.symmetric(vertical: 20),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: panelBg.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
              width: 0.8,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTelemetryRow('SYS.BOOT.LOADED', 'OK', 0.1, progress, textColor),
              _buildTelemetryRow('DB.CLIENT.INIT', 'ONLINE', 0.25, progress, textColor),
              _buildTelemetryRow('NET.ISOLATE.RUN', 'ACTIVE', 0.45, progress, textColor),
              _buildTelemetryRow('SCHEDULER.START', 'SUCCESS', 0.65, progress, textColor),
              _buildTelemetryRow('CHANNELS.READY', '100%', 0.85, progress, textColor),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'STATUS: ACTIVE',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                  ),
                  _buildBlinkingDot(textColor),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTelemetryRow(
    String label,
    String value,
    double threshold,
    double progress,
    Color activeColor,
  ) {
    final show = progress >= threshold;
    if (!show) return const SizedBox(height: 18);

    final textStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 10,
      fontWeight: FontWeight.bold,
      color: show ? activeColor : Colors.transparent,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0),
      child: DefaultTextStyle(
        style: textStyle,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('// $label'),
            Text(value),
          ],
        ),
      ),
    );
  }

  Widget _buildBlinkingDot(Color color) {
    final isBlinking = (_controller.value * 8).floor() % 2 == 0;
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: isBlinking ? color : Colors.transparent,
        shape: BoxShape.circle,
      ),
    );
  }
}
