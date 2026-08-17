import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/browser_controller.dart';

class BrowserTabSwitcher extends StatelessWidget with HapticHelper {
  final BrowserController controller;
  final SettingsProvider settings;
  final bool isDark;
  final Color textClr;

  const BrowserTabSwitcher({
    super.key,
    required this.controller,
    required this.settings,
    required this.isDark,
    required this.textClr,
  });

  static void show(
    BuildContext context, {
    required BrowserController controller,
    required SettingsProvider settings,
    required bool isDark,
    required Color textClr,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => BrowserTabSwitcher(
        controller: controller,
        settings: settings,
        isDark: isDark,
        textClr: textClr,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return DraggableScrollableSheet(
      initialChildSize: 0.65, // U26: 0.65 so top address bar isn't completely covered
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: settings.isAmoledMode
                ? Colors.black
                : (isDark ? AppTheme.surface : AppTheme.lightSurface),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.all(
              color: isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle,
              width: 1,
            ),
          ),
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final tabs = controller.tabs;
              final currentIndex = controller.currentIndex;

              return Column(
                children: [
                  // Handle bar
                  Center(
                    child: Container(
                      margin: const EdgeInsets.only(top: 8, bottom: 6),
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: textClr.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                  // Header with actions
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Row(
                      children: [
                        Text(
                          '${L10n.of(context, 'browser_tabs_header')} (${tabs.length})',
                          style: TextStyle(
                            color: textClr,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),

                        // Recently closed
                        if (controller.recentlyClosedTabs.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.history_rounded, size: 20),
                            tooltip: L10n.of(context, 'browser_recently_closed'),
                            onPressed: () {
                              HapticHelper.triggerHaptic(settings);
                              _showRecentlyClosedSheet(context);
                            },
                          ),

                        // New tab
                        IconButton(
                          icon: Icon(Icons.add_rounded, color: accent, size: 22),
                          tooltip: L10n.of(context, 'browser_new_tab'),
                          onPressed: () {
                            HapticHelper.triggerHaptic(settings);
                            Navigator.pop(context);
                            controller.openInNewTab('about:blank', switchTo: true);
                          },
                        ),

                        // Close all tabs
                        if (tabs.length > 1)
                          IconButton(
                            icon: const Icon(Icons.delete_sweep_rounded, size: 20, color: AppTheme.neonRed),
                            tooltip: L10n.of(context, 'browser_close_all_tabs'),
                            onPressed: () {
                              HapticHelper.triggerHaptic(settings);
                              _confirmCloseAll(context);
                            },
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),

                  // Tabs Grid (U7: Responsive max extent)
                  Expanded(
                    child: GridView.builder(
                      controller: scrollController,
                      padding: const EdgeInsets.all(12),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 220,
                        childAspectRatio: 0.85,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                      ),
                      itemCount: tabs.length,
                      itemBuilder: (context, index) {
                        final tab = tabs[index];
                        final isActive = index == currentIndex;

                        return Dismissible(
                          key: ValueKey(tab.id),
                          direction: DismissDirection.horizontal,
                          onDismissed: (_) {
                            HapticHelper.triggerHaptic(settings);
                            final closedTitle = tab.title.isNotEmpty ? tab.title : tab.url;
                            controller.closeTab(tab.id);
                            ScaffoldMessenger.of(context).hideCurrentSnackBar();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  L10n.isRtl(context)
                                      ? 'تم إغلاق التبويب'
                                      : 'Tab closed: $closedTitle',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                action: SnackBarAction(
                                  label: L10n.isRtl(context) ? 'تراجع' : 'Undo',
                                  onPressed: () {
                                    controller.restoreRecentlyClosedTab();
                                  },
                                ),
                                duration: const Duration(seconds: 4),
                              ),
                            );
                          },
                          child: GestureDetector(
                            onTap: () {
                              HapticHelper.triggerHaptic(settings);
                              controller.switchTab(index);
                              Navigator.pop(context);
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? (isActive ? accent.withValues(alpha: 0.12) : AppTheme.cardBg)
                                    : (isActive ? accent.withValues(alpha: 0.08) : AppTheme.lightCardBg),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isActive
                                      ? accent
                                      : (isDark ? AppTheme.border : AppTheme.lightBorder),
                                  width: isActive ? 2 : 1,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // Tab card header
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? Colors.white.withValues(alpha: 0.04)
                                          : Colors.black.withValues(alpha: 0.03),
                                      borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
                                    ),
                                    child: Row(
                                      children: [
                                        if (tab.faviconBytes != null)
                                          Image(
                                            image: MemoryImage(tab.faviconBytes!),
                                            width: 14,
                                            height: 14,
                                            fit: BoxFit.cover,
                                          )
                                        else
                                          Icon(
                                            tab.isIncognito
                                                ? Icons.visibility_off_rounded
                                                : (tab.isHome ? Icons.home_rounded : Icons.public_rounded),
                                            size: 14,
                                            color: accent,
                                          ),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            tab.stripLabel,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: textClr,
                                            ),
                                          ),
                                        ),
                                        if (tabs.length > 1)
                                          GestureDetector(
                                            onTap: () {
                                              HapticHelper.triggerHaptic(settings);
                                              controller.closeTab(tab.id);
                                            },
                                            child: Icon(
                                              Icons.close_rounded,
                                              size: 16,
                                              color: textClr.withValues(alpha: 0.6),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),

                                  // Tab card thumbnail preview / placeholder
                                  Expanded(
                                    child: ClipRRect(
                                      borderRadius: const BorderRadius.vertical(
                                          bottom: Radius.circular(11)),
                                      child: tab.previewBytes != null
                                          ? Image.memory(
                                              tab.previewBytes!,
                                              fit: BoxFit.cover,
                                              width: double.infinity,
                                              height: double.infinity,
                                              gaplessPlayback: true,
                                            )
                                          : Center(
                                              child: Column(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Icon(
                                                    tab.isHome
                                                        ? Icons
                                                            .dashboard_outlined
                                                        : (tab.isSuspended
                                                            ? Icons
                                                                .pause_circle_outline_rounded
                                                            : Icons
                                                                .language_rounded),
                                                    size: 32,
                                                    color: textClr
                                                        .withValues(alpha: 0.25),
                                                  ),
                                                  const SizedBox(height: 6),
                                                  Text(
                                                    tab.isSuspended
                                                        ? L10n.of(
                                                            context,
                                                            'browser_tab_paused',
                                                          )
                                                        : (tab.isHome
                                                            ? 'Home'
                                                            : tab.domain),
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      color: textClr
                                                          .withValues(alpha: 0.5),
                                                    ),
                                                  ),
                                                  if (tab.isSuspended) ...[
                                                    const SizedBox(height: 4),
                                                    Container(
                                                      padding:
                                                          const EdgeInsets
                                                              .symmetric(
                                                              horizontal: 6,
                                                              vertical: 2),
                                                      decoration: BoxDecoration(
                                                        color: accent
                                                            .withValues(
                                                                alpha: 0.1),
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(4),
                                                      ),
                                                      child: Text(
                                                        L10n.isRtl(context)
                                                            ? 'انقر للاستئناف'
                                                            : 'Tap to resume',
                                                        style: TextStyle(
                                                          fontSize: 8,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color: accent,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  void _confirmCloseAll(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
        title: Text(L10n.of(context, 'browser_close_all_tabs')),
        content: Text(L10n.of(context, 'browser_clear_all_tabs_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(L10n.of(context, 'cancel_btn')),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.neonRed),
            onPressed: () {
              Navigator.pop(dialogCtx);
              controller.closeAllTabs();
              Navigator.pop(context);
            },
            child: Text(L10n.of(context, 'browser_close_btn')),
          ),
        ],
      ),
    );
  }

  void _showRecentlyClosedSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final recent = controller.recentlyClosedTabs;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Text(
                      L10n.of(ctx, 'browser_recently_closed'),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: textClr,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        controller.clearRecentlyClosedTabs();
                        Navigator.pop(ctx);
                        // U11: Undo snackbar after clear
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(L10n.of(context, 'browser_history_cleared')),
                          ),
                        );
                      },
                      child: Text(L10n.of(ctx, 'browser_clear_btn')),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              if (recent.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    L10n.of(ctx, 'browser_no_recent_tabs'),
                    style: TextStyle(color: textClr.withValues(alpha: 0.5)),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: recent.length,
                    itemBuilder: (context, index) {
                      final item = recent[index];
                      return ListTile(
                        leading: const Icon(Icons.tab_unselected_rounded),
                        title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(item.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () {
                          Navigator.pop(ctx);
                          Navigator.pop(context);
                          controller.openInNewTab(item.url, isIncognito: item.isIncognito, switchTo: true);
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
