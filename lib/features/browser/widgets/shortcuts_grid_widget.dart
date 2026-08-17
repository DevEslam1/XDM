import 'package:dmx/core/app_theme.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/material.dart';

class ShortcutsGridWidget extends StatelessWidget {
  final List<Map<String, String>> customShortcuts;
  final bool isDark;
  final bool isRtl;
  final SettingsProvider settings;
  final VoidCallback onOpenBookmarks;
  final VoidCallback onOpenHistory;
  final VoidCallback onOpenScripts;
  final VoidCallback? onAddShortcut;
  final Function(Map<String, String>) onRemoveShortcut;
  final Function(String url) onNavigate;

  const ShortcutsGridWidget({
    super.key,
    required this.customShortcuts,
    required this.isDark,
    required this.isRtl,
    required this.settings,
    required this.onOpenBookmarks,
    required this.onOpenHistory,
    required this.onOpenScripts,
    this.onAddShortcut,
    required this.onRemoveShortcut,
    required this.onNavigate,
  });

  Widget _buildShortcutCard(
    BuildContext context, {
    required String title,
    required String url,
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap ?? () => onNavigate(url),
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.surface : AppTheme.lightSurface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 20, color: color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.of(context).size.shortestSide > 600;
    return GridView.count(
      crossAxisCount: isTablet ? 3 : 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: isTablet ? 3.0 : 2.5,
      children: [
        _buildShortcutCard(
          context,
          title: isRtl ? 'العلامات' : 'Bookmarks',
          url: '',
          icon: Icons.bookmark_rounded,
          color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          onTap: onOpenBookmarks,
        ),
        _buildShortcutCard(
          context,
          title: isRtl ? 'السجل' : 'History',
          url: '',
          icon: Icons.history_rounded,
          color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
          onTap: onOpenHistory,
        ),
        _buildShortcutCard(
          context,
          title: isRtl ? 'السكريبتات' : 'Scripts',
          url: '',
          icon: Icons.code_rounded,
          color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
          onTap: onOpenScripts,
        ),
        if (onAddShortcut != null)
          _buildShortcutCard(
            context,
            title: isRtl ? 'إضافة اختصار' : 'Add Shortcut',
            url: '',
            icon: Icons.add_rounded,
            color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
            onTap: onAddShortcut,
          ),
        ...customShortcuts.map((sc) {
          return _buildShortcutCard(
            context,
            title: sc['title'] ?? 'Shortcut',
            url: sc['url'] ?? '',
            icon: Icons.link,
            color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
            onLongPress: () => onRemoveShortcut(sc),
          );
        }),
      ],
    );
  }
}
