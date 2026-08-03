import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../settings/provider/settings_provider.dart';

/// The browser start page — calm, readable, and focused on the search
/// console. Only the entrance is animated; nothing loops indefinitely.
class BrowserHomePage extends StatefulWidget {
  final VoidCallback onSearchTap;
  final VoidCallback onBookmarksTap;
  final VoidCallback onHistoryTap;

  const BrowserHomePage({
    super.key,
    required this.onSearchTap,
    required this.onBookmarksTap,
    required this.onHistoryTap,
  });

  @override
  State<BrowserHomePage> createState() => _BrowserHomePageState();
}

class _BrowserHomePageState extends State<BrowserHomePage>
    with SingleTickerProviderStateMixin {
  AnimationController? _reveal;

  @override
  void initState() {
    super.initState();
    _reveal = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _reveal!.forward();
  }

  @override
  void dispose() {
    _reveal?.dispose();
    super.dispose();
  }

  Widget _stagger(double start, Widget child) {
    if (_reveal == null) return child;
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: _reveal!,
        curve: Interval(
          start,
          (start + 0.4).clamp(0.0, 1.0),
          curve: Curves.easeOut,
        ),
      ),
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero)
            .animate(
          CurvedAnimation(
            parent: _reveal!,
            curve: Interval(
              start,
              (start + 0.4).clamp(0.0, 1.0),
              curve: Curves.easeOutCubic,
            ),
          ),
        ),
        child: child,
      ),
    );
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Brand + status ───────────────────────────────────────
          _stagger(
            0.0,
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: accent.withValues(alpha: 0.25),
                      width: 0.8,
                    ),
                  ),
                  child: Icon(Icons.language_rounded, color: accent, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isRtl ? 'متصفح XDM' : 'XDM Browser',
                        style: TextStyle(
                          fontFamily: 'Space Grotesk',
                          fontWeight: FontWeight.w800,
                          fontSize: 22,
                          color: textClr,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: green,
                            ),
                          ),
                          const SizedBox(width: 7),
                          Text(
                            isRtl ? 'المحرك جاهز' : 'Engine ready',
                            style: TextStyle(
                              fontFamily: 'Space Grotesk',
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: muted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
