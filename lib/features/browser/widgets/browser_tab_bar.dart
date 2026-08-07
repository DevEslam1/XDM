import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/browser_tab.dart';

class BrowserTabBar extends StatelessWidget {
  final List<BrowserTab> tabs;
  final int currentIndex;
  final ValueChanged<int> onTabSelected;
  final VoidCallback onAddTab;
  final ValueChanged<int> onCloseTab;
  final bool isDark;

  const BrowserTabBar({
    super.key,
    required this.tabs,
    required this.currentIndex,
    required this.onTabSelected,
    required this.onAddTab,
    required this.onCloseTab,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    if (tabs.isEmpty) return const SizedBox.shrink();

    final isAmoled = context.watch<SettingsProvider>().isAmoledMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final violet = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final navBg = isDark
        ? (isAmoled ? AppTheme.amoledBackground : AppTheme.surface)
        : AppTheme.lightSurface;

    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: navBg.withValues(
          alpha: isAmoled ? 1.0 : 0.92,
        ),
        border: Border(
          bottom: BorderSide(
            color: isDark
                ? (isAmoled ? AppTheme.amoledBorder : AppTheme.border)
                : AppTheme.lightBorder,
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          // Tab counter block
          Container(
            margin: const EdgeInsetsDirectional.only(start: 10, end: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: accent.withValues(alpha: 0.3)),
            ),
            child: Text(
              '${tabs.length}',
              style: TextStyle(
                fontFamily: 'Space Grotesk',
                fontWeight: FontWeight.w800,
                fontSize: 12,
                color: accent,
              ),
            ),
          ),
          // Scrollable tab strip
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(vertical: 7),
              itemCount: tabs.length,
              itemBuilder: (context, index) {
                final tab = tabs[index];
                final isActive = index == currentIndex;
                final tabAccent = tab.isIncognito ? violet : accent;
                return _TabChip(
                  tab: tab,
                  isActive: isActive,
                  accent: tabAccent,
                  isDark: isDark,
                  isAmoled: isAmoled,
                  showClose: tabs.length > 1,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onTabSelected(index);
                  },
                  onClose: () {
                    HapticFeedback.lightImpact();
                    onCloseTab(index);
                  },
                );
              },
            ),
          ),
          // Add tab
          _BarIconButton(
            icon: Icons.add_rounded,
            isDark: isDark,
            tooltip: 'New tab',
            onTap: () {
              HapticFeedback.lightImpact();
              onAddTab();
            },
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  final BrowserTab tab;
  final bool isActive;
  final Color accent;
  final bool isDark;
  final bool isAmoled;
  final bool showClose;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const _TabChip({
    required this.tab,
    required this.isActive,
    required this.accent,
    required this.isDark,
    this.isAmoled = false,
    required this.showClose,
    required this.onTap,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final muted = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        constraints: const BoxConstraints(maxWidth: 170, minWidth: 90),
        margin: const EdgeInsetsDirectional.only(end: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isActive
              ? accent.withValues(alpha: isDark ? 0.14 : 0.10)
              : (isDark
                      ? (isAmoled ? AppTheme.amoledCardBg : AppTheme.cardBg)
                      : AppTheme.lightCardBg)
                  .withValues(
                  alpha: 0.5,
                ),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isActive
                ? accent.withValues(alpha: 0.5)
                : (isDark
                    ? (isAmoled ? AppTheme.amoledBorder : AppTheme.border)
                    : AppTheme.lightBorder),
            width: isActive ? 1.2 : 0.8,
          ),
        ),
        child: Row(
          children: [
            Icon(
              tab.isIncognito
                  ? Icons.visibility_off_rounded
                  : tab.isHome
                      ? Icons.home_rounded
                      : tab.isSecure
                          ? Icons.lock_rounded
                          : Icons.language_rounded,
              size: 13,
              color: isActive ? accent : muted,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tab.stripLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Space Grotesk',
                      fontSize: 11,
                      fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                      color: isActive
                          ? (isDark
                              ? AppTheme.textPrimary
                              : AppTheme.lightTextPrimary)
                          : muted,
                    ),
                  ),
                  if (tab.isLoading)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: ValueListenableBuilder<double>(
                        valueListenable: tab.progressNotifier,
                        builder: (context, value, child) => ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: value,
                            minHeight: 2,
                            backgroundColor: accent.withValues(alpha: 0.15),
                            valueColor: AlwaysStoppedAnimation(accent),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (showClose)
              GestureDetector(
                onTap: onClose,
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 6),
                  child: Icon(Icons.close_rounded, size: 14, color: muted),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BarIconButton extends StatelessWidget {
  final IconData icon;
  final bool isDark;
  final String tooltip;
  final VoidCallback onTap;

  const _BarIconButton({
    required this.icon,
    required this.isDark,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: (isDark ? AppTheme.cardBg : AppTheme.lightCardBg)
                  .withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: isDark ? AppTheme.border : AppTheme.lightBorder,
                width: 0.8,
              ),
            ),
            child: Icon(
              icon,
              size: 18,
              color:
                  isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
