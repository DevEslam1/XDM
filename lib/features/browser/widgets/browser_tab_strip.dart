import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/browser_controller.dart';

class BrowserTabStrip extends StatelessWidget {
  final BrowserController controller;
  final SettingsProvider settings;
  final bool isDark;
  final Color textClr;

  const BrowserTabStrip({
    super.key,
    required this.controller,
    required this.settings,
    required this.isDark,
    required this.textClr,
  });

  @override
  Widget build(BuildContext context) {
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final tabs = controller.tabs;
    final currentIndex = controller.currentIndex;

    // FIX(U3): Scale the strip height with the system text scale factor so
    // larger fonts don't clip tab content (clamped 40–56 px).
    final textScale = MediaQuery.textScalerOf(context).scale(1.0);
    final stripHeight = (40 * textScale).clamp(40.0, 56.0);

    return Container(
      height: stripHeight,
      color: settings.isAmoledMode
          ? Colors.black
          : (isDark ? AppTheme.surface : AppTheme.lightSurface),
      child: ListView.builder(
        controller: controller.tabStripScrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: tabs.length,
        itemBuilder: (context, index) {
          final tab = tabs[index];
          final isActive = index == currentIndex;

          // FIX(P12): Each tab item rebuilds only when ITS OWN url/loading
          // notifiers fire, instead of rebuilding the whole ListView whenever
          // any tab changes.
          return ListenableBuilder(
            listenable: Listenable.merge(
                [tab.loadingNotifier, tab.urlNotifier]),
            builder: (context, _) {
              final isLoading = tab.loadingNotifier.value;
              return Semantics(
            button: true,
            selected: isActive,
            label: 'Tab: ${tab.stripLabel}',
            child: GestureDetector(
              onTap: () {
                HapticHelper.triggerHaptic(settings);
                controller.switchTab(index);
              },
              onLongPress: () => _showTabStripMenu(context, index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.only(right: 6, top: 4, bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: isActive
                      ? accent.withValues(alpha: 0.12)
                      : (isDark
                          ? const Color(0x0DFFFFFF)
                          : const Color(0x0D000000)),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isActive
                        ? accent.withValues(alpha: 0.7)
                        : Colors.transparent,
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // FIX(U13): Shield badge with the blocked-ads count for
                    // this tab, shown whenever any ad was blocked.
                    ValueListenableBuilder<int>(
                      valueListenable:
                          controller.blockedAdsNotifier(tab.id),
                      builder: (context, blocked, _) {
                        if (blocked <= 0) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppTheme.neonGreen.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: AppTheme.neonGreen
                                    .withValues(alpha: 0.5),
                                width: 0.7,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.shield_rounded,
                                  size: 9,
                                  color: AppTheme.neonGreen,
                                ),
                                const SizedBox(width: 2),
                                Text(
                                  '$blocked',
                                  style: const TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    color: AppTheme.neonGreen,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    // U10: Show small spinner on loading tabs
                    if (isLoading) ...[
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(accent),
                          ),
                        ),
                      ),
                    ] else
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: tab.faviconBytes != null && tab.faviconBytes!.isNotEmpty
                            ? Image(
                                image: MemoryImage(tab.faviconBytes!),
                                width: 14,
                                height: 14,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) =>
                                    Icon(
                                  tab.isIncognito
                                      ? Icons.visibility_off_rounded
                                      : (tab.isHome
                                          ? Icons.home_rounded
                                          : Icons.public_rounded),
                                  size: 14,
                                  color: isActive
                                      ? accent
                                      : textClr.withValues(alpha: 0.6),
                                ),
                              )
                            : Icon(
                                tab.isIncognito
                                    ? Icons.visibility_off_rounded
                                    : (tab.isHome
                                        ? Icons.home_rounded
                                        : Icons.public_rounded),
                                size: 14,
                                color: isActive ? accent : textClr.withValues(alpha: 0.6),
                              ),
                      ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 120),
                      child: Text(
                        tab.stripLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                          color: isActive ? textClr : textClr.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                    if (tabs.length > 1) ...[
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () {
                          HapticHelper.triggerHaptic(settings);
                          controller.closeTab(tab.id);
                        },
                        child: Icon(
                          Icons.close_rounded,
                          size: 14,
                          color: textClr.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
            },
          );
        },
      ),
    );
  }

  void _showTabStripMenu(BuildContext context, int index) {
    final tab = controller.tabs[index];
    HapticHelper.triggerHaptic(settings);

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: Text(L10n.of(ctx, 'browser_duplicate_tab')),
                onTap: () {
                  Navigator.pop(ctx);
                  controller.duplicateTab(tab.id);
                },
              ),
              ListTile(
                leading: const Icon(Icons.close_rounded),
                title: Text(L10n.of(ctx, 'browser_close_tab')),
                onTap: () {
                  Navigator.pop(ctx);
                  controller.closeTab(tab.id);
                },
              ),
              ListTile(
                leading: const Icon(Icons.clear_all_rounded),
                title: Text(L10n.of(ctx, 'browser_close_other_tabs')),
                onTap: () {
                  Navigator.pop(ctx);
                  controller.closeOtherTabs(tab.id);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_sweep_rounded, color: AppTheme.neonRed),
                title: Text(
                  L10n.of(ctx, 'browser_close_all_tabs'),
                  style: const TextStyle(color: AppTheme.neonRed),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  controller.closeAllTabs();
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
