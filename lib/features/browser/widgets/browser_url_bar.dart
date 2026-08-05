import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/mixins/pausable_loop_animation.dart';
import '../../settings/provider/settings_provider.dart';

class BrowserUrlBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isFocused;
  final bool canGoBack;
  final bool canGoForward;
  final bool isLoading;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onRefresh;
  final VoidCallback onMenu;

  const BrowserUrlBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.isFocused,
    required this.canGoBack,
    required this.canGoForward,
    required this.isLoading,
    required this.onSubmitted,
    required this.onBack,
    required this.onForward,
    required this.onRefresh,
    required this.onMenu,
  });

  bool get _isSecure {
    final t = controller.text.trim().toLowerCase();
    return t.startsWith('https://');
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final green = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final muted = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    final isAmoled = settings.isAmoledMode;
    final navBg = isDark
        ? (isAmoled ? AppTheme.amoledBackground : AppTheme.surface)
        : AppTheme.lightSurface;

    return Container(
      decoration: BoxDecoration(
        color: navBg.withValues(
          alpha: isAmoled ? 1.0 : 0.95,
        ),
        border: Border(
          bottom: BorderSide(
            color: isDark
                ? (isAmoled ? AppTheme.amoledBorder : AppTheme.border)
                : AppTheme.lightBorder,
            width: 1,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.only(
              left: isRtl ? 6 : 8,
              right: isRtl ? 8 : 6,
              top: 8,
              bottom: 8,
            ),
            child: Row(
              children: [
                if (!isRtl) ...[
                  _NavButton(
                    icon: Icons.arrow_back_rounded,
                    enabled: canGoBack,
                    isDark: isDark,
                    onTap: onBack,
                  ),
                  _NavButton(
                    icon: Icons.arrow_forward_rounded,
                    enabled: canGoForward,
                    isDark: isDark,
                    onTap: onForward,
                  ),
                ],
                const SizedBox(width: 4),
                // Address field
                Expanded(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    height: 38,
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF0F0F16)
                          : const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isFocused
                            ? accent.withValues(alpha: 0.55)
                            : (isDark
                                ? const Color(0x15FFFFFF)
                                : const Color(0x0D000000)),
                        width: isFocused ? 1.4 : 0.8,
                      ),
                      boxShadow: isFocused && isDark && settings.enableGlow
                          ? [
                              BoxShadow(
                                color: accent.withValues(alpha: 0.22),
                                blurRadius: 10,
                                spreadRadius: 0.5,
                              ),
                            ]
                          : null,
                    ),
                    child: Row(
                      children: [
                        const SizedBox(width: 10),
                        // Security / state glyph
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          child: Icon(
                            isLoading
                                ? Icons.autorenew_rounded
                                : _isSecure
                                    ? Icons.lock_rounded
                                    : Icons.info_outline_rounded,
                            key: ValueKey('${isLoading}_$_isSecure'),
                            size: 15,
                            color: isLoading
                                ? accent
                                : _isSecure
                                    ? green
                                    : muted,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: controller,
                            focusNode: focusNode,
                            textDirection:
                                isRtl ? TextDirection.rtl : TextDirection.ltr,
                            style: TextStyle(
                              color: textClr,
                              fontSize: 13,
                              fontFamily: 'Inter',
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: isRtl
                                  ? 'Ø§Ø¨Ø­Ø« Ø£Ùˆ Ø£Ø¯Ø®Ù„ Ø±Ø§Ø¨Ø·'
                                  : 'Search or enter URL',
                              hintStyle: TextStyle(color: muted, fontSize: 12),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 10,
                              ),
                            ),
                            onSubmitted: onSubmitted,
                          ),
                        ),
                        // Inline refresh / stop
                        GestureDetector(
                          onTap: onRefresh,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Icon(
                              isLoading
                                  ? Icons.close_rounded
                                  : Icons.refresh_rounded,
                              size: 17,
                              color: isLoading ? accent : muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                if (isRtl) ...[
                  _NavButton(
                    icon: Icons.arrow_forward_rounded,
                    enabled: canGoForward,
                    isDark: isDark,
                    onTap: onForward,
                  ),
                  _NavButton(
                    icon: Icons.arrow_back_rounded,
                    enabled: canGoBack,
                    isDark: isDark,
                    onTap: onBack,
                  ),
                ],
                _NavButton(
                  icon: Icons.tune_rounded,
                  enabled: true,
                  isDark: isDark,
                  onTap: onMenu,
                ),
              ],
            ),
          ),
          // Loading scanline pinned to the bar's bottom edge
          AnimatedOpacity(
            opacity: isLoading ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: const _IndeterminateScanline(),
          ),
        ],
      ),
    );
  }
}

class _IndeterminateScanline extends StatefulWidget {
  const _IndeterminateScanline();
  @override
  State<_IndeterminateScanline> createState() => _IndeterminateScanlineState();
}

class _IndeterminateScanlineState extends State<_IndeterminateScanline>
    with
        SingleTickerProviderStateMixin,
        WidgetsBindingObserver,
        PausableLoopAnimation<_IndeterminateScanline> {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  AnimationController get loopController => _c;

  bool _allowed = true;

  @override
  bool get loopWanted => _allowed;

  @override
  void initState() {
    super.initState();
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
    final isDark = context.select((SettingsProvider s) => s.isDarkMode);
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final allowed = modernAnimationsAllowed(context, listen: true);
    if (allowed != _allowed) {
      _allowed = allowed;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) syncPausableLoop();
      });
    }
    // Classic / battery-saver / reduce-visuals: a static line instead of the
    // animated scanline, so nothing loops in the background to drain battery.
    if (!allowed) {
      return Container(
        height: 2,
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }
    return SizedBox(
      height: 2,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final seg = w * 0.3;
          return AnimatedBuilder(
            animation: _c,
            builder: (context, child) {
              final x = (w + seg) * _c.value - seg;
              return Stack(
                children: [
                  Positioned(
                    left: x,
                    child: Container(
                      width: seg,
                      height: 2,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [accent.withValues(alpha: 0), accent],
                        ),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final bool isDark;
  final VoidCallback onTap;

  const _NavButton({
    required this.icon,
    required this.enabled,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final active = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final disabled = (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted)
        .withValues(alpha: 0.3);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          width: 34,
          height: 34,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          alignment: Alignment.center,
          child: Icon(icon, size: 18, color: enabled ? active : disabled),
        ),
      ),
    );
  }
}
