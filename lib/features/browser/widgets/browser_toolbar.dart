import 'package:flutter/material.dart';
import '../../../core/app_theme.dart';
import '../../settings/provider/settings_provider.dart';
import 'smart_url_bar.dart';

/// Extracted toolbar component for the in-app browser screen.
class BrowserToolbar extends StatelessWidget {
  final TextEditingController urlController;
  final FocusNode focusNode;
  final bool isDark;
  final bool isRtl;
  final bool isLoading;
  final bool canGoBack;
  final bool isHomeTab;
  final int tabCount;
  final bool desktopMode;
  final Color textClr;
  final SettingsProvider settings;
  final VoidCallback onGoBack;
  final VoidCallback onShowTabSwitcher;
  final VoidCallback onNavigateHome;
  final ValueChanged<String> onNavigate;
  final VoidCallback onReload;
  final VoidCallback onStopLoading;
  final PopupMenuItemBuilder<String> menuItemBuilder;
  final PopupMenuItemSelected<String> onMenuSelected;
  final VoidCallback onQuitPressed;
  final Widget? youtubeGrabButton;

  const BrowserToolbar({
    super.key,
    required this.urlController,
    required this.focusNode,
    required this.isDark,
    required this.isRtl,
    required this.isLoading,
    required this.canGoBack,
    required this.isHomeTab,
    required this.tabCount,
    required this.desktopMode,
    required this.textClr,
    required this.settings,
    required this.onGoBack,
    required this.onShowTabSwitcher,
    required this.onNavigateHome,
    required this.onNavigate,
    required this.onReload,
    required this.onStopLoading,
    required this.menuItemBuilder,
    required this.onMenuSelected,
    required this.onQuitPressed,
    this.youtubeGrabButton,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
            .withValues(alpha: 0.95),
        border: Border(
          bottom: BorderSide(
            color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
            width: 0.6,
          ),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            // Home button
            IconButton(
              icon: Icon(
                Icons.home_outlined,
                size: 20,
                color: textClr,
              ),
              tooltip: isRtl ? 'الصفحة الرئيسية' : 'Home',
              onPressed: onNavigateHome,
            ),

            // Navigation back button
            IconButton(
              icon: Icon(
                Icons.arrow_back_ios_new,
                size: 15,
                color: (canGoBack || !isHomeTab)
                    ? textClr
                    : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted),
              ),
              onPressed: (canGoBack || !isHomeTab) ? onGoBack : null,
            ),

            // Desktop mode indicator indicator icon
            if (desktopMode)
              const Tooltip(
                message: 'Desktop mode active',
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4.0),
                  child: Icon(
                    Icons.desktop_windows_rounded,
                    size: 14,
                    color: AppTheme.neonBlue,
                  ),
                ),
              ),

            // URL address bar
            Expanded(
              child: SmartUrlBar(
                controller: urlController,
                focusNode: focusNode,
                isDark: isDark,
                isLoading: isLoading,
                onNavigate: onNavigate,
                onReload: onReload,
                onStopLoading: onStopLoading,
              ),
            ),

            if (youtubeGrabButton != null) ...[
              const SizedBox(width: 4),
              youtubeGrabButton!,
              const SizedBox(width: 4),
            ],

            // Tabs button
            IconButton(
              icon: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    Icons.crop_square_rounded,
                    size: 22,
                    color: textClr,
                  ),
                  Text(
                    '$tabCount',
                    style: TextStyle(
                      color: textClr,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              onPressed: onShowTabSwitcher,
            ),

            // Overflow menu button
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, size: 18, color: textClr),
              color: isDark ? AppTheme.surface : AppTheme.lightSurface,
              onSelected: onMenuSelected,
              itemBuilder: menuItemBuilder,
            ),

            // Quit browser button
            IconButton(
              icon: Icon(
                Icons.power_settings_new_rounded,
                size: 18,
                color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
              ),
              tooltip: isRtl ? 'إنهاء المتصفح' : 'Quit browser',
              onPressed: onQuitPressed,
            ),
          ],
        ),
      ),
    );
  }
}
