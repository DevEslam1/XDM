import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/bookmark.dart';
import '../models/browser_tab.dart';
import '../screens/browser_settings_screen.dart';
import '../services/browser_controller.dart';
import '../services/screenshot_service.dart';
import 'bookmark_manager_screen.dart';
import 'browser_history_sheet.dart';
import 'browser_misc_dialogs.dart';

/// Full-featured, hardened overflow menu button for the browser toolbar.
class BrowserMenuButton extends StatelessWidget {
  static final _log = Logger('BrowserMenuButton');
  final BrowserController controller;
  final SettingsProvider settings;
  final bool isDark;
  final Color textClr;

  const BrowserMenuButton({
    super.key,
    required this.controller,
    required this.settings,
    required this.isDark,
    required this.textClr,
  });

  @override
  Widget build(BuildContext context) {
    final activeTab = controller.activeTab;
    final isHome = activeTab == null || activeTab.isHome;
    final hasUrl = activeTab != null && !isHome && activeTab.url.isNotEmpty;

    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert_rounded, size: 20, color: textClr),
      color: isDark ? AppTheme.surface : AppTheme.lightSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 8,
      onSelected: (action) => _handleAction(context, action, activeTab),
      itemBuilder: (ctx) => [
        _buildItem(
          ctx,
          value: 'reload',
          icon: Icons.refresh_rounded,
          title: L10n.isRtl(ctx) ? 'إعادة تحميل' : 'Reload',
          enabled: hasUrl,
        ),
        _buildItem(
          ctx,
          value: 'new_tab',
          icon: Icons.add_box_outlined,
          title: L10n.of(ctx, 'browser_new_tab'),
        ),
        _buildItem(
          ctx,
          value: 'new_incognito',
          icon: Icons.visibility_off_outlined,
          title: L10n.of(ctx, 'browser_new_incognito_tab'),
        ),
        _buildItem(
          ctx,
          value: 'recently_closed',
          icon: Icons.restore_page_rounded,
          title: L10n.isRtl(ctx) ? 'التبويبات المغلقة مؤخراً' : 'Recently Closed',
          enabled: controller.recentlyClosedTabs.isNotEmpty,
        ),
        const PopupMenuDivider(height: 8),
        _buildItem(
          ctx,
          value: 'bookmark_page',
          icon: Icons.bookmark_add_outlined,
          title: L10n.isRtl(ctx) ? 'إضافة إلى الإشارات' : 'Bookmark this page',
          enabled: hasUrl,
        ),
        _buildItem(
          ctx,
          value: 'bookmarks',
          icon: Icons.bookmark_outline_rounded,
          title: L10n.of(ctx, 'browser_bookmarks'),
        ),
        _buildItem(
          ctx,
          value: 'history',
          icon: Icons.history_rounded,
          title: L10n.of(ctx, 'browser_history_title'),
        ),
        _buildItem(
          ctx,
          value: 'downloads',
          icon: Icons.download_rounded,
          title: L10n.of(ctx, 'browser_downloads_tab'),
        ),
        _buildItem(
          ctx,
          value: 'desktop_mode',
          icon: settings.desktopMode
              ? Icons.desktop_windows_rounded
              : Icons.phone_android_rounded,
          title: settings.desktopMode
              ? (L10n.isRtl(ctx) ? 'عرض الهاتف' : 'Mobile View')
              : (L10n.isRtl(ctx) ? 'عرض سطح المكتب' : 'Desktop Site'),
        ),
        _buildItem(
          ctx,
          value: 'save_offline',
          icon: Icons.offline_pin_outlined,
          title: L10n.of(ctx, 'browser_save_offline'),
          enabled: hasUrl,
        ),
        const PopupMenuDivider(height: 8),
        _buildItem(
          ctx,
          value: 'find_in_page',
          icon: Icons.search_rounded,
          title: L10n.of(ctx, 'browser_find_in_page'),
          enabled: hasUrl,
        ),
        _buildItem(
          ctx,
          value: 'reader_mode',
          icon: Icons.chrome_reader_mode_outlined,
          title: L10n.of(ctx, 'browser_reader_mode'),
          enabled: hasUrl,
        ),
        _buildItem(
          ctx,
          value: 'page_zoom',
          icon: Icons.zoom_in_rounded,
          title: L10n.of(ctx, 'browser_page_zoom'),
          enabled: hasUrl,
        ),
        _buildItem(
          ctx,
          value: 'share',
          icon: Icons.share_outlined,
          title: L10n.of(ctx, 'browser_share_link'),
          enabled: hasUrl,
        ),
        _buildItem(
          ctx,
          value: 'copy_link',
          icon: Icons.copy_rounded,
          title: L10n.of(ctx, 'browser_copy_link'),
          enabled: hasUrl,
        ),
        // FIX(D7): Save a full-page screenshot of the active tab to the
        // downloads directory via ScreenshotService.
        _buildItem(
          ctx,
          value: 'save_screenshot',
          icon: Icons.photo_camera_outlined,
          title: L10n.of(ctx, 'browser_save_screenshot'),
          enabled: hasUrl,
        ),
        _buildItem(
          ctx,
          value: 'js_css_injector',
          icon: Icons.code_rounded,
          title: L10n.of(ctx, 'browser_js_css_injector'),
          enabled: hasUrl,
        ),
        const PopupMenuDivider(height: 8),
        _buildItem(
          ctx,
          value: 'keyboard_shortcuts',
          icon: Icons.keyboard_rounded,
          title: L10n.of(ctx, 'browser_keyboard_shortcuts'),
        ),
        _buildItem(
          ctx,
          value: 'settings',
          icon: Icons.settings_outlined,
          title: L10n.of(ctx, 'settings_title'),
        ),
      ],
    );
  }

  PopupMenuItem<String> _buildItem(
    BuildContext context, {
    required String value,
    required IconData icon,
    required String title,
    bool enabled = true,
  }) {
    final itemTextClr = enabled
        ? (isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary)
        : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted);

    return PopupMenuItem<String>(
      value: value,
      enabled: enabled,
      height: 40,
      child: Row(
        children: [
          Icon(icon, size: 18, color: itemTextClr),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                color: itemTextClr,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _handleAction(
    BuildContext context,
    String action,
    BrowserTab? activeTab,
  ) {
    HapticHelper.triggerHaptic(settings);

    switch (action) {
      case 'reload':
        controller.reload();
        break;
      case 'recently_closed':
        controller.restoreRecentlyClosedTab();
        break;
      case 'bookmark_page':
        if (activeTab != null && activeTab.url.isNotEmpty) {
          final db = context.read<DatabaseService>();
          db.saveBookmark(Bookmark(
            id: const Uuid().v4(),
            url: activeTab.url,
            title: activeTab.title.isNotEmpty ? activeTab.title : activeTab.url,
            createdAt: DateTime.now(),
          ));
          ThemedSnackbar.show(
            context,
            message: L10n.isRtl(context)
                ? 'تمت إضافة الصفحة إلى الإشارات'
                : 'Page bookmarked',
            color: AppTheme.neonGreen,
            icon: Icons.bookmark_added_rounded,
            isDarkMode: isDark,
          );
        }
        break;
      case 'desktop_mode':
        settings.setDesktopMode(!settings.desktopMode);
        controller.reload();
        break;
      case 'new_tab':
        controller.openInNewTab('about:blank', switchTo: true);
        break;
      case 'new_incognito':
        controller.openInNewTab('about:blank', isIncognito: true, switchTo: true);
        break;
      case 'bookmarks':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const BookmarkManagerScreen()),
        );
        break;
      case 'history':
        BrowserHistorySheet.show(context).then((url) {
          if (url != null && url.isNotEmpty) {
            controller.navigateToUrl(url);
          }
        });
        break;
      case 'downloads':
        controller.downloadProvider.setActiveTabIndex(0);
        break;
      case 'save_offline':
        if (activeTab != null) {
          controller.savePageOffline(activeTab, context: context);
        }
        break;
      case 'find_in_page':
        controller.openFindPanel();
        break;
      case 'reader_mode':
        if (activeTab != null) {
          controller.activateReaderMode(activeTab);
        }
        break;
      case 'page_zoom':
        if (activeTab != null && activeTab.host.isNotEmpty) {
          BrowserMiscDialogs.showZoomDialog(
            context,
            controller: controller,
            host: activeTab.host,
            settings: settings,
          );
        }
        break;
      case 'share':
        if (activeTab != null && activeTab.url.isNotEmpty) {
          SharePlus.instance.share(ShareParams(
            text: activeTab.url,
            subject: activeTab.title,
          ));
        }
        break;
      case 'copy_link':
        if (activeTab != null && activeTab.url.isNotEmpty) {
          Clipboard.setData(ClipboardData(text: activeTab.url));
          ThemedSnackbar.show(
            context,
            message: L10n.isRtl(context) ? 'تم نسخ الرابط' : 'Link copied to clipboard',
            color: AppTheme.neonGreen,
            icon: Icons.check_circle_outline,
            isDarkMode: isDark,
          );
        }
        break;
      case 'save_screenshot':
        if (activeTab != null) {
          _saveScreenshot(context, activeTab);
        }
        break;
      case 'js_css_injector':
        if (activeTab != null) {
          BrowserMiscDialogs.showJsCssInjectorDialog(
            context,
            controller: controller,
            tab: activeTab,
            settings: settings,
          );
        }
        break;
      case 'keyboard_shortcuts':
        BrowserMiscDialogs.showKeyboardShortcutsDialog(context, settings: settings);
        break;
      case 'settings':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BrowserSettingsScreen(
              isSnifferEnabled: controller.isSnifferEnabled,
              onSnifferChanged: (val) => controller.setSnifferEnabled(val),
            ),
          ),
        );
        break;
    }
  }

  // FIX(D7): Capture a full-page screenshot of the active tab and save it to
  // the downloads directory (custom path or the app default).
  Future<void> _saveScreenshot(BuildContext context, BrowserTab tab) async {
    final webController = tab.controller;
    if (webController == null) return;
    try {
      final bytes = await ScreenshotService.captureFullPage(webController);
      if (bytes == null || bytes.isEmpty) {
        if (context.mounted) {
          ThemedSnackbar.show(
            context,
            message: L10n.of(context, 'browser_screenshot_failed'),
            color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
            icon: Icons.error_outline,
            isDarkMode: isDark,
          );
        }
        return;
      }

      String targetDir = settings.customDownloadPath ?? '';
      if (targetDir.isEmpty) {
        targetDir = await PermissionService().defaultDownloadDirectory();
      }
      final safeName = tab.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final file = File(p.join(targetDir, '${safeName}_$stamp.png'));
      await file.writeAsBytes(bytes);

      if (context.mounted) {
        final dir = p.basename(targetDir);
        ThemedSnackbar.show(
          context,
          message: '${L10n.of(context, 'browser_screenshot_saved')} ($dir)',
          color: AppTheme.neonGreen,
          icon: Icons.check_circle_outline,
          isDarkMode: isDark,
        );
      }
    } catch (e, st) {
      _log.warning('Save screenshot error', e, st);
      if (context.mounted) {
        ThemedSnackbar.show(
          context,
          message: L10n.of(context, 'browser_screenshot_failed'),
          color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
          icon: Icons.error_outline,
          isDarkMode: isDark,
        );
      }
    }
  }
}
