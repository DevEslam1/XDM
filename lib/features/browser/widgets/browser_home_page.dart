import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../settings/provider/settings_provider.dart';

/// The browser start page — calm, readable, and focused on the search
/// console with quick-action buttons for Bookmarks, History, and Downloads.
class BrowserHomePage extends StatefulWidget {
  final VoidCallback onSearchTap;
  final VoidCallback onBookmarksTap;
  final VoidCallback onHistoryTap;
  final VoidCallback? onDownloadsTap;

  const BrowserHomePage({
    super.key,
    required this.onSearchTap,
    required this.onBookmarksTap,
    required this.onHistoryTap,
    this.onDownloadsTap,
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
          const SizedBox(height: 18),

          // ── Large interactive search bar ─────────────────────────
          _stagger(
            0.15,
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: widget.onSearchTap,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.black.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isDark
                          ? AppTheme.glassBorder
                          : AppTheme.lightGlassBorder,
                      width: 0.8,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.search_rounded, size: 20, color: accent),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          isRtl
                              ? 'ابحث في الويب أو أدخل عنوان URL...'
                              : 'Search the web or type URL...',
                          style: TextStyle(
                            fontSize: 14,
                            color: muted,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.arrow_forward_rounded,
                            size: 14, color: accent),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ── Quick action buttons (D6, U1) ─────────────────────────
          _stagger(
            0.25,
            Row(
              children: [
                Expanded(
                  child: _QuickActionButton(
                    icon: Icons.bookmark_rounded,
                    label: isRtl ? 'العلامات' : 'Bookmarks',
                    color: accent,
                    isDark: isDark,
                    onTap: widget.onBookmarksTap,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _QuickActionButton(
                    icon: Icons.history_rounded,
                    label: isRtl ? 'السجل' : 'History',
                    color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                    isDark: isDark,
                    onTap: widget.onHistoryTap,
                  ),
                ),
                if (widget.onDownloadsTap != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _QuickActionButton(
                      icon: Icons.download_rounded,
                      label: isRtl ? 'التنزيلات' : 'Downloads',
                      color: green,
                      isDark: isDark,
                      onTap: widget.onDownloadsTap!,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool isDark;
  final VoidCallback onTap;

  const _QuickActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: color.withValues(alpha: 0.2),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
