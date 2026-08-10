import 'package:flutter/material.dart';
import '../../../core/app_theme.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';

/// Reusable sheet scaffold wrapper providing glassmorphism backdrop,
/// drag handle, header title, and actions for browser bottom sheets.
class BrowserSheetScaffold extends StatelessWidget {
  final String title;
  final Widget child;
  final bool isDark;
  final IconData? icon;
  final Widget? trailing;
  final double initialChildSize;
  final double maxChildSize;
  final double minChildSize;

  const BrowserSheetScaffold({
    super.key,
    required this.title,
    required this.child,
    required this.isDark,
    this.icon,
    this.trailing,
    this.initialChildSize = 0.75,
    this.maxChildSize = 0.92,
    this.minChildSize = 0.4,
  });

  @override
  Widget build(BuildContext context) {
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: initialChildSize,
      maxChildSize: maxChildSize,
      minChildSize: minChildSize,
      builder: (context, controller) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: DmxBackdropFilter(
            sigmaX: 15,
            sigmaY: 15,
            child: Container(
              decoration: BoxDecoration(
                color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
                    .withValues(alpha: 0.95),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border(
                  top: BorderSide(
                    color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                    width: 0.8,
                  ),
                ),
              ),
              child: SafeArea(
                child: Column(
                  children: [
                    // Drag Handle Indicator
                    const SizedBox(height: 10),
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: (isDark ? Colors.white : Colors.black)
                            .withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Header Row
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                      child: Row(
                        children: [
                          if (icon != null) ...[
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(icon, color: accent, size: 18),
                            ),
                            const SizedBox(width: 12),
                          ],
                          Text(
                            title,
                            style: TextStyle(
                              color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const Spacer(),
                          if (trailing != null) trailing!,
                        ],
                      ),
                    ),
                    const Divider(height: 1),

                    // Sheet Body
                    Expanded(child: child),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
