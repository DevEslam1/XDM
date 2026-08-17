import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/browser_controller.dart';
import 'browser_menu_button.dart';
import 'smart_url_bar.dart';

/// Responsive, theme-adaptive toolbar for the in-app browser screen.
class BrowserToolbar extends StatelessWidget {
  final BrowserController controller;
  final TextEditingController urlController;
  final FocusNode focusNode;
  final bool isDark;
  final bool isRtl;
  final bool isLoading;
  final double progress;
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
  final VoidCallback onQuitPressed;
  final VoidCallback? onShieldPressed;
  final bool isHttps;
  final Widget? youtubeGrabButton;

  const BrowserToolbar({
    super.key,
    required this.controller,
    required this.urlController,
    required this.focusNode,
    required this.isDark,
    required this.isRtl,
    required this.isLoading,
    this.progress = 0.0,
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
    required this.onQuitPressed,
    this.youtubeGrabButton,
    this.onShieldPressed,
    this.isHttps = false,
  });

  @override
  Widget build(BuildContext context) {
    final isAmoled = isDark && settings.isAmoledMode;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    final toolbarBg = isDark
        ? (isAmoled ? AppTheme.amoledSurface : AppTheme.surface.withValues(alpha: 0.96))
        : AppTheme.lightSurface.withValues(alpha: 0.96);

    final toolbarBorder = isDark
        ? (isAmoled ? AppTheme.amoledBorder : AppTheme.glassBorder)
        : AppTheme.lightGlassBorder;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 360;

        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: isNarrow ? 4 : 6,
            vertical: 4,
          ),
          decoration: BoxDecoration(
            color: toolbarBg,
            border: Border(
              bottom: BorderSide(
                color: toolbarBorder,
                width: 0.8,
              ),
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                // Home button
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(
                    minWidth: isNarrow ? 30 : 34,
                    minHeight: 36,
                  ),
                  icon: Icon(
                    Icons.home_rounded,
                    size: isNarrow ? 18 : 20,
                    color: textClr,
                  ),
                  tooltip: L10n.of(context, 'browser_home_tooltip'),
                  onPressed: onNavigateHome,
                ),

                // Navigation back button
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(
                    minWidth: isNarrow ? 26 : 30,
                    minHeight: 36,
                  ),
                  icon: Icon(
                    Icons.arrow_back_ios_new,
                    size: isNarrow ? 13 : 15,
                    color: (canGoBack || !isHomeTab) ? textClr : mutedClr,
                  ),
                  onPressed: (canGoBack || !isHomeTab) ? onGoBack : null,
                ),

                // Desktop mode indicator badge
                if (desktopMode)
                  Tooltip(
                    message: 'Desktop mode active',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2.0),
                      child: Container(
                        padding: const EdgeInsets.all(3.5),
                        decoration: BoxDecoration(
                          color: AppTheme.neonBlue.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(
                          Icons.desktop_windows_rounded,
                          size: 12,
                          color: AppTheme.neonBlue,
                        ),
                      ),
                    ),
                  ),

                const SizedBox(width: 2),

                // URL address bar capsule
                Expanded(
                  child: SmartUrlBar(
                    controller: urlController,
                    focusNode: focusNode,
                    isDark: isDark,
                    isLoading: isLoading,
                    progress: progress,
                    onNavigate: onNavigate,
                    onReload: onReload,
                    onStopLoading: onStopLoading,
                    onShieldPressed: onShieldPressed,
                    isHttps: isHttps,
                  ),
                ),

                const SizedBox(width: 2),

                if (youtubeGrabButton != null) ...[
                  youtubeGrabButton!,
                  const SizedBox(width: 2),
                ],

                // Tabs button with badge counter
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(
                    minWidth: isNarrow ? 30 : 34,
                    minHeight: 36,
                  ),
                  icon: Container(
                    width: isNarrow ? 21 : 23,
                    height: isNarrow ? 21 : 23,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: textClr.withValues(alpha: 0.7),
                        width: 1.5,
                      ),
                    ),
                    child: Text(
                      '$tabCount',
                      style: TextStyle(
                        color: textClr,
                        fontSize: tabCount > 9 ? 9.5 : 10.5,
                        fontWeight: FontWeight.bold,
                        height: 1.1,
                      ),
                    ),
                  ),
                  onPressed: onShowTabSwitcher,
                ),

                // Extracted full 17-action menu button
                BrowserMenuButton(
                  controller: controller,
                  settings: settings,
                  isDark: isDark,
                  textClr: textClr,
                ),

                // Quit / Close browser button
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(
                    minWidth: isNarrow ? 28 : 32,
                    minHeight: 36,
                  ),
                  icon: Icon(
                    Icons.power_settings_new_rounded,
                    size: isNarrow ? 16 : 18,
                    color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                  ),
                  tooltip: L10n.of(context, 'browser_quit_tooltip'),
                  onPressed: onQuitPressed,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
