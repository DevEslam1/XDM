import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
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

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accentClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final surfaceClr = isDark ? AppTheme.surface : AppTheme.lightSurface;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;

    return Container(
      padding: EdgeInsets.only(
        left: isRtl ? 0 : 8,
        right: isRtl ? 8 : 0,
        top: 4,
        bottom: 4,
      ),
      color: isDark
          ? AppTheme.background.withValues(alpha: 0.95)
          : AppTheme.lightBackground.withValues(alpha: 0.95),
      child: Row(
        children: [
          if (!isRtl) ...[
            _NavButton(
              icon: Icons.arrow_back_rounded,
              enabled: canGoBack,
              onTap: onBack,
              isDark: isDark,
            ),
            _NavButton(
              icon: Icons.arrow_forward_rounded,
              enabled: canGoForward,
              onTap: onForward,
              isDark: isDark,
            ),
          ],
          Expanded(
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: surfaceClr,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isFocused ? accentClr.withValues(alpha: 0.5) : (isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder),
                  width: isFocused ? 1.2 : 0.6,
                ),
              ),
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
                style: TextStyle(
                  color: textClr,
                  fontSize: 12,
                ),
                decoration: InputDecoration(
                  hintText: isRtl ? 'ابحث أو أدخل رابط' : 'Search or enter URL',
                  hintStyle: TextStyle(
                    color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                    fontSize: 12,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
                onSubmitted: onSubmitted,
              ),
            ),
          ),
          GestureDetector(
            onTap: onRefresh,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Icon(
                isLoading ? Icons.close_rounded : Icons.refresh_rounded,
                size: 20,
                color: textClr,
              ),
            ),
          ),
          if (isRtl) ...[
            _NavButton(
              icon: Icons.arrow_back_rounded,
              enabled: canGoForward,
              onTap: onForward,
              isDark: isDark,
            ),
            _NavButton(
              icon: Icons.arrow_forward_rounded,
              enabled: canGoBack,
              onTap: onBack,
              isDark: isDark,
            ),
          ],
          GestureDetector(
            onTap: onMenu,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Icon(
                Icons.more_vert_rounded,
                size: 20,
                color: textClr,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;
  final bool isDark;

  const _NavButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.all(8),
        child: Icon(
          icon,
          size: 18,
          color: enabled
              ? (isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary)
              : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted).withValues(alpha: 0.3),
        ),
      ),
    );
  }
}
