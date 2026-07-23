import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../settings/provider/settings_provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';

class BrowserHomePage extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accentClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return Container(
      color: isDark ? AppTheme.background : AppTheme.lightBackground,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.public, size: 64, color: accentClr.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            Text(
              isRtl ? 'متصفح XDM' : 'XDM Browser',
              style: TextStyle(
                color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                fontSize: 18,
                fontWeight: FontWeight.w300,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _QuickAction(
                  icon: Icons.search_rounded,
                  label: isRtl ? 'بحث' : 'Search',
                  color: accentClr,
                  onTap: onSearchTap,
                ),
                const SizedBox(width: 24),
                _QuickAction(
                  icon: Icons.bookmark_rounded,
                  label: isRtl ? 'علامات' : 'Bookmarks',
                  color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                  onTap: onBookmarksTap,
                ),
                const SizedBox(width: 24),
                _QuickAction(
                  icon: Icons.history_rounded,
                  label: isRtl ? 'سجل' : 'History',
                  color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                  onTap: onHistoryTap,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _QuickAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: color.withValues(alpha: 0.2), width: 0.6),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
