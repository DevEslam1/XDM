import 'package:flutter/material.dart';
import '../../../core/app_theme.dart';
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

    return Container(
      height: 40,
      color: isDark
          ? AppTheme.background.withValues(alpha: 0.95)
          : AppTheme.lightBackground.withValues(alpha: 0.95),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: tabs.length,
              itemBuilder: (context, index) {
                final tab = tabs[index];
                final isActive = index == currentIndex;
                return GestureDetector(
                  onTap: () => onTabSelected(index),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 160),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: isActive
                              ? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue)
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          tab.isIncognito ? Icons.visibility_off_rounded : Icons.language_rounded,
                          size: 12,
                          color: isActive
                              ? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue)
                              : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            tab.title.isNotEmpty ? tab.title : tab.url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: isActive
                                  ? (isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary)
                                  : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted),
                            ),
                          ),
                        ),
                        if (tabs.length > 1) ...[
                          const SizedBox(width: 4),
                          GestureDetector(
                            onTap: () => onCloseTab(index),
                            child: Icon(
                              Icons.close_rounded,
                              size: 14,
                              color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          GestureDetector(
            onTap: onAddTab,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Icon(
                Icons.add_rounded,
                size: 20,
                color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
