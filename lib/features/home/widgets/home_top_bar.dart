import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/widgets/dmx_app_icon.dart';
import '../../categories/screens/categories_screen.dart';
import '../../downloads/provider/download_provider.dart';
import '../../downloads/widgets/batch_operations_sheet.dart';
import '../../history/screens/history_screen.dart';
import '../../settings/provider/settings_provider.dart';

/// Elevated, uncluttered top header for [HomeScreen] with an integrated
/// search bar, live aggregate speed/active pill, and clean action buttons.
class HomeTopBar extends StatelessWidget implements PreferredSizeWidget {
  final bool isDark;
  final bool classicUi;
  final bool isAmoled;
  final Color accentClr;
  final bool isSearching;
  final bool showAnalytics;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final VoidCallback onToggleAnalytics;
  final VoidCallback onToggleSearch;
  final VoidCallback onClearSearch;

  const HomeTopBar({
    super.key,
    required this.isDark,
    required this.classicUi,
    required this.isAmoled,
    required this.accentClr,
    required this.isSearching,
    required this.showAnalytics,
    required this.searchController,
    required this.searchFocusNode,
    required this.onToggleAnalytics,
    required this.onToggleSearch,
    required this.onClearSearch,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 4);

  @override
  Widget build(BuildContext context) {
    final textClr = AppTheme.textPrimaryOf(isDark);
    final surfaceClr = AppTheme.surfaceColor(isDark, isAmoled: isAmoled);
    final borderClr = AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);
    final screenWidth = MediaQuery.sizeOf(context).width;

    return AppBar(
      toolbarHeight: kToolbarHeight + 4,
      backgroundColor: classicUi
          ? surfaceClr
          : (isAmoled
              ? AppTheme.amoledBackground
              : surfaceClr.withValues(alpha: isDark ? 0.72 : 0.86)),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      iconTheme: IconThemeData(color: textClr),
      shape: Border(
        bottom: BorderSide(
          color: (classicUi || isAmoled)
              ? borderClr
              : borderClr.withValues(alpha: 0.65),
          width: DmxTokens.borderThin,
        ),
      ),
      titleSpacing: isSearching ? 8 : 12,
      title: AnimatedSwitcher(
        duration: AppTheme.motionFast,
        switchInCurve: AppTheme.motionCurve,
        switchOutCurve: AppTheme.motionCurve,
        child: isSearching
            ? _HomeSearchField(
                key: const ValueKey('home_search_field'),
                controller: searchController,
                focusNode: searchFocusNode,
                isDark: isDark,
                isAmoled: isAmoled,
                accentClr: accentClr,
                onClear: onClearSearch,
              )
            : Row(
                key: const ValueKey('home_brand_row'),
                children: [
                  const DmxAppIcon(size: 24, showGlow: false),
                  const SizedBox(width: 8),
                  Text(
                    'XDM',
                    style: TextStyle(
                      fontFamily: AppTheme.fontDisplay,
                      color: textClr,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.6,
                      fontSize: 17,
                    ),
                  ),
                  if (screenWidth >= 360) ...[
                    const SizedBox(width: 10),
                    Flexible(
                      child: _LiveSpeedPill(
                        isDark: isDark,
                        isAmoled: isAmoled,
                      ),
                    ),
                  ],
                ],
              ),
      ),
      actions: [
        if (!isSearching) ...[
          _HeaderActionButton(
            icon: Icons.category_outlined,
            color: textClr,
            tooltip: 'Categories',
            isDark: isDark,
            onPressed: () {
              runHaptic(context.read<SettingsProvider>());
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CategoriesScreen()),
              );
            },
          ),
          _HeaderActionButton(
            icon: Icons.history_rounded,
            color: textClr,
            tooltip: 'History',
            isDark: isDark,
            onPressed: () {
              runHaptic(context.read<SettingsProvider>());
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HistoryScreen()),
              );
            },
          ),
          _HeaderActionButton(
            icon: showAnalytics
                ? Icons.pie_chart_rounded
                : Icons.pie_chart_outline_rounded,
            color: showAnalytics ? accentClr : textClr,
            isActive: showAnalytics,
            activeColor: accentClr,
            tooltip: L10n.of(context, 'storage_analytics'),
            isDark: isDark,
            onPressed: onToggleAnalytics,
          ),
        ],
        _HeaderActionButton(
          icon: isSearching ? Icons.close_rounded : Icons.search_rounded,
          color: isSearching ? accentClr : textClr,
          isActive: isSearching,
          activeColor: accentClr,
          tooltip: isSearching ? L10n.of(context, 'cancel_btn') : 'Search',
          isDark: isDark,
          onPressed: onToggleSearch,
        ),
        const SizedBox(width: 6),
      ],
    );
  }
}

class _LiveSpeedPill extends StatelessWidget {
  final bool isDark;
  final bool isAmoled;

  const _LiveSpeedPill({
    required this.isDark,
    required this.isAmoled,
  });

  @override
  Widget build(BuildContext context) {
    return Selector<DownloadProvider, ({String speed, int activeCount})>(
      selector: (_, p) => (
        speed: p.currentDownloadSpeedFormatted,
        activeCount: p.downloadingTasksCount,
      ),
      builder: (context, telemetry, _) {
        if (telemetry.activeCount <= 0) return const SizedBox.shrink();
        final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: greenClr.withValues(alpha: isDark ? 0.14 : 0.10),
            borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
            border: Border.all(
              color: greenClr.withValues(alpha: isDark ? 0.30 : 0.25),
              width: DmxTokens.borderThin,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: greenClr,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '${telemetry.activeCount} · ${telemetry.speed}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.dataStyle(
                    isDark: isDark,
                    size: 11,
                    weight: FontWeight.w700,
                    color: greenClr,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HomeSearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isDark;
  final bool isAmoled;
  final Color accentClr;
  final VoidCallback onClear;

  const _HomeSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.isDark,
    required this.isAmoled,
    required this.accentClr,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final isFocused = focusNode.hasFocus;
    final textClr = AppTheme.textPrimaryOf(isDark);
    final mutedClr = AppTheme.textMutedOf(isDark);
    final borderClr = AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);

    return Theme(
      data: Theme.of(context).copyWith(
        primaryColor: accentClr,
        colorScheme: Theme.of(context).colorScheme.copyWith(primary: accentClr),
        textSelectionTheme: TextSelectionThemeData(
          cursorColor: accentClr,
          selectionColor: accentClr.withValues(alpha: 0.25),
          selectionHandleColor: accentClr,
        ),
      ),
      child: AnimatedContainer(
        duration: AppTheme.motionFast,
        curve: AppTheme.motionCurve,
        height: 42,
        decoration: BoxDecoration(
          color: AppTheme.panelBg(isDark, isAmoled: isAmoled),
          borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
          border: Border.all(
            color: isFocused ? accentClr : borderClr,
            width: isFocused ? 1.4 : DmxTokens.borderThin,
          ),
        ),
        child: TextField(
          focusNode: focusNode,
          controller: controller,
          autofocus: true,
          cursorColor: accentClr,
          style: TextStyle(
            color: textClr,
            fontSize: 13.5,
            fontFamily: AppTheme.fontBody,
          ),
          onChanged: (val) {
            context.read<DownloadProvider>().setSearchQuery(val);
          },
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: Icon(
              Icons.search_rounded,
              size: 19,
              color: isFocused ? accentClr : mutedClr,
            ),
            suffixIcon: ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                if (value.text.isEmpty) return const SizedBox.shrink();
                return IconButton(
                  icon: Icon(Icons.clear_rounded, size: 17, color: mutedClr),
                  tooltip: L10n.of(context, 'clear_search'),
                  onPressed: onClear,
                );
              },
            ),
            hintText: L10n.of(context, 'search_placeholder'),
            hintStyle: TextStyle(
              color: mutedClr,
              fontSize: 13,
              fontFamily: AppTheme.fontBody,
            ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 11),
          ),
        ),
      ),
    );
  }
}

class _HeaderActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String? tooltip;
  final bool isDark;
  final bool isActive;
  final Color? activeColor;
  final VoidCallback onPressed;

  const _HeaderActionButton({
    required this.icon,
    required this.color,
    this.tooltip,
    required this.isDark,
    this.isActive = false,
    this.activeColor,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = isActive && activeColor != null
        ? activeColor!.withValues(alpha: isDark ? 0.16 : 0.11)
        : Colors.transparent;
    return IconButton(
      icon: Icon(icon, color: color, size: 21),
      tooltip: tooltip,
      onPressed: onPressed,
      constraints: const BoxConstraints(minWidth: 42, minHeight: 42),
      style: IconButton.styleFrom(
        backgroundColor: bgColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DmxTokens.badgeRadius),
        ),
        highlightColor: color.withValues(alpha: 0.12),
        hoverColor: color.withValues(alpha: 0.08),
      ),
    );
  }
}

/// Clean selection-mode top bar with count indicator and select/deselect actions.
class HomeSelectionAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  final bool isDark;
  final bool isAmoled;
  final Color accentClr;
  final List<String> Function(DownloadProvider provider) visibleTaskIdsBuilder;

  const HomeSelectionAppBar({
    super.key,
    required this.isDark,
    required this.isAmoled,
    required this.accentClr,
    required this.visibleTaskIdsBuilder,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 4);

  @override
  Widget build(BuildContext context) {
    final count =
        context.select<DownloadProvider, int>((p) => p.selectedTaskIds.length);
    final provider = context.read<DownloadProvider>();
    final textClr = AppTheme.textPrimaryOf(isDark);
    final surfaceClr =
        AppTheme.surfaceColor(isDark, isAmoled: isAmoled, elevated: true);
    final borderClr = AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);

    return AppBar(
      toolbarHeight: kToolbarHeight + 4,
      backgroundColor: surfaceClr,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(
        bottom: BorderSide(color: borderClr, width: DmxTokens.borderThin),
      ),
      leading: IconButton(
        icon: Icon(Icons.close_rounded, color: textClr),
        tooltip: L10n.of(context, 'deselect_btn'),
        onPressed: () => provider.clearTaskSelection(),
      ),
      title: Text(
        L10n.of(context, 'selected_count', args: {'count': count}),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: AppTheme.fontDisplay,
          color: textClr,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => provider.selectAllTasks(
            visibleTaskIds: visibleTaskIdsBuilder(provider),
          ),
          style: TextButton.styleFrom(
            foregroundColor: accentClr,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DmxTokens.badgeRadius),
            ),
          ),
          child: Text(
            L10n.of(context, 'select_all_btn'),
            style: TextStyle(
              fontFamily: AppTheme.fontDisplay,
              color: accentClr,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
        TextButton(
          onPressed: () => provider.clearTaskSelection(),
          style: TextButton.styleFrom(
            foregroundColor: AppTheme.textSecondaryOf(isDark),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DmxTokens.badgeRadius),
            ),
          ),
          child: Text(
            L10n.of(context, 'deselect_btn'),
            style: TextStyle(
              fontFamily: AppTheme.fontDisplay,
              color: AppTheme.textSecondaryOf(isDark),
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
        const SizedBox(width: 6),
      ],
    );
  }
}

/// Bottom action dock shown when multi-select mode is active.
class HomeBatchActionBar extends StatelessWidget {
  final bool isDark;
  final bool isAmoled;
  final Color accentClr;

  const HomeBatchActionBar({
    super.key,
    required this.isDark,
    required this.isAmoled,
    required this.accentClr,
  });

  @override
  Widget build(BuildContext context) {
    final selectedIds =
        context.select<DownloadProvider, Set<String>>((p) => p.selectedTaskIds);
    final textClr = AppTheme.textPrimaryOf(isDark);
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final surfaceClr =
        AppTheme.surfaceColor(isDark, isAmoled: isAmoled, elevated: true);
    final borderClr = AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        decoration: BoxDecoration(
          color: surfaceClr,
          border: Border(
            top: BorderSide(color: borderClr, width: DmxTokens.borderThin),
          ),
          boxShadow: AppTheme.cardShadow(isDark, elevated: true),
        ),
        child: Wrap(
          alignment: WrapAlignment.spaceAround,
          runAlignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            _BatchActionButton(
              icon: Icons.pause_rounded,
              label: L10n.of(context, 'pause_btn'),
              color: textClr,
              isDark: isDark,
              onTap: () => BatchOperationsSheet.show(
                context,
                selectedTaskIds: selectedIds.toList(),
                initialAction: BatchAction.pause,
              ),
            ),
            _BatchActionButton(
              icon: Icons.play_arrow_rounded,
              label: L10n.of(context, 'resume_btn'),
              color: textClr,
              isDark: isDark,
              onTap: () => BatchOperationsSheet.show(
                context,
                selectedTaskIds: selectedIds.toList(),
                initialAction: BatchAction.resume,
              ),
            ),
            _BatchActionButton(
              icon: Icons.delete_rounded,
              label: L10n.of(context, 'delete_btn'),
              color: redClr,
              isDark: isDark,
              onTap: () => BatchOperationsSheet.show(
                context,
                selectedTaskIds: selectedIds.toList(),
                initialAction: BatchAction.delete,
              ),
            ),
            _BatchActionButton(
              icon: Icons.folder_rounded,
              label: L10n.of(context, 'change_category'),
              color: accentClr,
              isDark: isDark,
              onTap: () => BatchOperationsSheet.show(
                context,
                selectedTaskIds: selectedIds.toList(),
                initialAction: BatchAction.changeCategory,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BatchActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool isDark;
  final VoidCallback onTap;

  const _BatchActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        child: Container(
          constraints: const BoxConstraints(minWidth: 68, minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: AppTheme.fontDisplay,
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Clean navigation drawer for quick access to Transmissions, Categories, and History.
class HomeNavigationDrawer extends StatelessWidget {
  final bool isDark;
  final bool isAmoled;
  final Color accentClr;

  const HomeNavigationDrawer({
    super.key,
    required this.isDark,
    required this.isAmoled,
    required this.accentClr,
  });

  @override
  Widget build(BuildContext context) {
    final bg = AppTheme.surfaceColor(isDark, isAmoled: isAmoled);
    final textClr = AppTheme.textPrimaryOf(isDark);
    final secClr = AppTheme.textSecondaryOf(isDark);
    final borderClr = AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);

    return Drawer(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadiusDirectional.horizontal(
          end: Radius.circular(DmxTokens.radiusXl),
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
              child: Row(
                children: [
                  const DmxAppIcon(size: 32, showGlow: false),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'XDM',
                          style: TextStyle(
                            fontFamily: AppTheme.fontDisplay,
                            color: textClr,
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.5,
                          ),
                        ),
                        Text(
                          L10n.of(context, 'title_transmissions'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: AppTheme.fontBody,
                            color: secClr,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Divider(color: borderClr, height: 1, thickness: 0.8),
            const SizedBox(height: 10),
            _DrawerTile(
              icon: Icons.home_outlined,
              label: 'Transmissions',
              isSelected: true,
              accentClr: accentClr,
              textClr: textClr,
              isDark: isDark,
              onTap: () => Navigator.pop(context),
            ),
            const SizedBox(height: 4),
            _DrawerTile(
              icon: Icons.category_outlined,
              label: 'Categories',
              isSelected: false,
              accentClr: accentClr,
              textClr: textClr,
              isDark: isDark,
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CategoriesScreen()),
                );
              },
            ),
            const SizedBox(height: 4),
            _DrawerTile(
              icon: Icons.history_rounded,
              label: 'History',
              isSelected: false,
              accentClr: accentClr,
              textClr: textClr,
              isDark: isDark,
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const HistoryScreen()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final Color accentClr;
  final Color textClr;
  final bool isDark;
  final VoidCallback onTap;

  const _DrawerTile({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.accentClr,
    required this.textClr,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = isSelected ? accentClr : textClr;
    return ListTile(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
      ),
      tileColor: isSelected
          ? accentClr.withValues(alpha: isDark ? 0.14 : 0.09)
          : Colors.transparent,
      leading: Icon(icon, color: fg, size: 21),
      title: Text(
        label,
        style: TextStyle(
          fontFamily: AppTheme.fontDisplay,
          color: fg,
          fontSize: 14,
          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      onTap: onTap,
    );
  }
}
