import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/app_theme.dart';
import '../../core/utils/localization.dart';
import '../../features/settings/provider/settings_provider.dart';

/// A crafted, animated snackbar: colored signal rail, popping status icon,
/// a one-shot shimmer sweep, optional action, and a dismiss control.
///
/// The static [show] signature is backward-compatible with every existing
/// call site; new optional parameters are additive.
class ThemedSnackbar {
  ThemedSnackbar._();

  static String? _lastMessage;
  static DateTime _lastShown = DateTime.fromMillisecondsSinceEpoch(0);

  static void show(
    BuildContext context, {
    required String message,
    required Color color,
    IconData? icon,
    bool? isDarkMode,
    String? subtitle,
    Duration duration = const Duration(milliseconds: 2600),
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    if (!context.mounted) return;
    final now = DateTime.now();
    final dedupKey = '$message:${subtitle ?? ''}';
    if (_lastMessage == dedupKey &&
        now.difference(_lastShown).inMilliseconds < 800) {
      return; // debounce duplicate identical message
    }
    _lastMessage = dedupKey;
    _lastShown = now;
    final isDark =
        isDarkMode ?? Theme.of(context).brightness == Brightness.dark;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        behavior: SnackBarBehavior.floating,
        duration: duration,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 14),
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        content: _SnackbarBody(
          message: message,
          subtitle: subtitle,
          color: color,
          icon: icon,
          isDark: isDark,
          actionLabel: actionLabel,
          onAction: onAction,
          onClose: () {
            try {
              messenger.hideCurrentSnackBar();
            } catch (e) {
              assert(() {
                debugPrint('[ThemedSnackbar] hideCurrentSnackBar expected: $e');
                return true;
              }());
            }
          },
        ),
      ),
    );
  }

  // ── Convenience wrappers ──────────────────────────────────────
  static void success(
    BuildContext context,
    String message, {
    bool? isDarkMode,
    String? subtitle,
  }) {
    show(
      context,
      message: message,
      subtitle: subtitle,
      color: isDarkMode == false ? AppTheme.lightNeonGreen : AppTheme.neonGreen,
      icon: Icons.check_circle_rounded,
      isDarkMode: isDarkMode,
    );
  }

  static void error(
    BuildContext context,
    String message, {
    bool? isDarkMode,
    String? subtitle,
  }) {
    show(
      context,
      message: message,
      subtitle: subtitle,
      color: isDarkMode == false ? AppTheme.lightNeonRed : AppTheme.neonRed,
      icon: Icons.error_outline,
      isDarkMode: isDarkMode,
      duration: const Duration(milliseconds: 3400),
    );
  }

  static void info(
    BuildContext context,
    String message, {
    bool? isDarkMode,
    String? subtitle,
  }) {
    show(
      context,
      message: message,
      subtitle: subtitle,
      color: isDarkMode == false ? AppTheme.lightNeonBlue : AppTheme.neonBlue,
      icon: Icons.info_outline_rounded,
      isDarkMode: isDarkMode,
    );
  }
}

class _SnackbarBody extends StatefulWidget {
  final String message;
  final String? subtitle;
  final Color color;
  final IconData? icon;
  final bool isDark;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onClose;

  const _SnackbarBody({
    required this.message,
    required this.color,
    required this.isDark,
    required this.onClose,
    this.subtitle,
    this.icon,
    this.actionLabel,
    this.onAction,
  });

  @override
  State<_SnackbarBody> createState() => _SnackbarBodyState();
}

class _SnackbarBodyState extends State<_SnackbarBody>
    with TickerProviderStateMixin {
  late final AnimationController _iconPop;
  late final AnimationController _shimmer;

  @override
  void initState() {
    super.initState();
    _iconPop = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    )..forward();
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..forward();
  }

  @override
  void dispose() {
    _iconPop.dispose();
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final color = widget.color;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final mutedClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final reduceVisuals =
        context.select((SettingsProvider s) => s.reduceVisuals);

    return Material(
      color: Colors.transparent,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(
            alpha: 0.97,
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.35), width: 1),
          boxShadow: [
            AppTheme.glow(
              color,
              alpha: isDark ? 0.16 : 0.10,
              blur: 18,
              spread: -4,
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.10),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Stack(
          children: [
            // One-shot shimmer sweep across the surface (gated by reduceVisuals)
            if (!reduceVisuals)
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _shimmer,
                  builder: (context, child) {
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final w = constraints.maxWidth;
                        final x = (w + 140) * _shimmer.value - 140;
                        return Stack(
                          children: [
                            Positioned(
                              left: x,
                              top: 0,
                              bottom: 0,
                              child: Container(
                                width: 90,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      color.withValues(alpha: 0),
                                      color.withValues(
                                        alpha: isDark ? 0.07 : 0.05,
                                      ),
                                      color.withValues(alpha: 0),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            IntrinsicHeight(
              child: Row(
                children: [
                  // Signal rail
                  Container(width: 4, color: color),
                  // Icon chip
                  if (widget.icon != null)
                    Padding(
                      padding: const EdgeInsets.only(
                        left: 12,
                        top: 12,
                        bottom: 12,
                      ),
                      child: ScaleTransition(
                        scale: CurvedAnimation(
                          parent: _iconPop,
                          curve: Curves.elasticOut,
                        ),
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: color.withValues(
                              alpha: isDark ? 0.14 : 0.10,
                            ),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: color.withValues(alpha: 0.30),
                              width: 0.8,
                            ),
                          ),
                          child: Icon(widget.icon, color: color, size: 18),
                        ),
                      ),
                    ),
                  // Message
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 11,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.message,
                            style: TextStyle(
                              fontFamily: AppTheme.fontBody,
                              color: textClr,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              height: 1.35,
                            ),
                          ),
                          if (widget.subtitle != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              widget.subtitle!,
                              style: TextStyle(
                                fontFamily: AppTheme.fontBody,
                                color: mutedClr,
                                fontSize: 11,
                                height: 1.3,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  // Optional action
                  if (widget.actionLabel != null && widget.onAction != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: color,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          minimumSize: const Size(64, 48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: () {
                          widget.onAction!();
                          widget.onClose();
                        },
                        child: Text(
                          widget.actionLabel!,
                          style: const TextStyle(
                            fontFamily: AppTheme.fontDisplay,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                    ),
                  // Dismiss
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 4),
                    child: Semantics(
                      button: true,
                      label: L10n.of(context, 'close_btn'),
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: widget.onClose,
                          child: Center(
                            child: Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: mutedClr,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
