import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/intl_formatters.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/responsive.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/widgets/dmx_bottom_sheet.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../downloads/widgets/filter_chips_bar.dart';
import 'home_segmented_tabs.dart';

/// Section header above the task list with count badge, sort menu, and
/// clear-history action (using the unified [DmxSheetContainer] confirmation sheet).
class HomeSectionHeader extends StatelessWidget {
  final int selectedTab;
  final bool isDark;
  final bool isAmoled;
  final bool isRtl;

  const HomeSectionHeader({
    super.key,
    required this.selectedTab,
    required this.isDark,
    required this.isAmoled,
    required this.isRtl,
  });

  @override
  Widget build(BuildContext context) {
    final textClr = AppTheme.textPrimaryOf(isDark);
    final secClr = AppTheme.textSecondaryOf(isDark);
    final mutedClr = AppTheme.textMutedOf(isDark);
    final surfaceClr = AppTheme.surfaceColor(isDark, isAmoled: isAmoled);
    final borderClr = AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);
    final activeColor = context.select<DownloadProvider, Color>(
      (p) => getActiveFilterColor(p, isDark),
    );

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: screenPadding(context).left),
      child: Row(
        children: [
          Expanded(
            child: Selector<DownloadProvider, int>(
              selector: (_, p) {
                var count = 0;
                for (final t in p.filteredTasks) {
                  final active = isHomeActiveTask(t);
                  if (selectedTab == 0 ? active : !active) count++;
                }
                return count;
              },
              builder: (context, count, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          selectedTab == 0
                              ? L10n.of(context, 'active_transmissions_header')
                              : L10n.of(
                                  context, 'completed_transmissions_header'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: AppTheme.fontDisplay,
                            color: textClr,
                            fontSize: responsiveFontSize(context, 13),
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.panelBg(isDark, isAmoled: isAmoled),
                          borderRadius:
                              BorderRadius.circular(DmxTokens.radiusSm),
                          border: Border.all(
                            color: borderClr,
                            width: DmxTokens.borderThin,
                          ),
                        ),
                        child: Text(
                          formatLocalizedNumber(context, count),
                          style: AppTheme.dataStyle(
                            isDark: isDark,
                            size: 11,
                            weight: FontWeight.w700,
                            color: secClr,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    L10n.of(
                      context,
                      count == 1
                          ? 'items_count_singular'
                          : 'items_count_plural',
                      args: {'count': count},
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: AppTheme.fontBody,
                      color: mutedClr,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Selector<DownloadProvider, ({SortOption option, bool ascending})>(
            selector: (_, p) =>
                (option: p.sortOption, ascending: p.sortAscending),
            builder: (context, sortState, _) {
              return PopupMenuButton<SortOption>(
                tooltip: L10n.of(context, 'sort_tooltip'),
                color: AppTheme.surfaceColor(isDark,
                    isAmoled: isAmoled, elevated: true),
                surfaceTintColor: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                  side:
                      BorderSide(color: borderClr, width: DmxTokens.borderThin),
                ),
                offset: const Offset(0, 42),
                onSelected: (option) {
                  final p = context.read<DownloadProvider>();
                  if (p.sortOption == option) {
                    p.toggleSortDirection();
                  } else {
                    p.setSortOption(option);
                  }
                },
                itemBuilder: (context) => [
                  _sortMenuItem(
                    SortOption.dateAdded,
                    L10n.of(context, 'sort_date'),
                    sortState,
                    activeColor,
                  ),
                  _sortMenuItem(
                    SortOption.fileSize,
                    L10n.of(context, 'details_size'),
                    sortState,
                    activeColor,
                  ),
                  _sortMenuItem(
                    SortOption.fileName,
                    L10n.of(context, 'details_filename'),
                    sortState,
                    activeColor,
                  ),
                  _sortMenuItem(
                    SortOption.status,
                    L10n.of(context, 'sort_status'),
                    sortState,
                    activeColor,
                  ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: surfaceClr,
                    borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                    border: Border.all(
                      color: borderClr,
                      width: DmxTokens.borderThin,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        sortState.ascending
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded,
                        color: secClr,
                        size: 14,
                      ),
                      const SizedBox(width: 5),
                      Icon(Icons.sort_rounded, color: secClr, size: 16),
                    ],
                  ),
                ),
              );
            },
          ),
          Selector<DownloadProvider, int>(
            selector: (_, p) =>
                p.filteredTasks.where((t) => !isHomeActiveTask(t)).length,
            builder: (context, clearableLength, _) {
              if (selectedTab != 1 || clearableLength == 0) {
                return const SizedBox.shrink();
              }
              final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
              return Padding(
                padding: const EdgeInsetsDirectional.only(start: 8),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                    onTap: () => _showClearHistorySheet(
                      context,
                      context.read<DownloadProvider>(),
                    ),
                    child: Tooltip(
                      message: L10n.of(context, 'clear_all'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: redClr.withValues(alpha: isDark ? 0.12 : 0.08),
                          borderRadius:
                              BorderRadius.circular(DmxTokens.radiusMd),
                          border: Border.all(
                            color:
                                redClr.withValues(alpha: isDark ? 0.28 : 0.22),
                            width: DmxTokens.borderThin,
                          ),
                        ),
                        child: Icon(
                          Icons.delete_sweep_outlined,
                          color: redClr,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  PopupMenuItem<SortOption> _sortMenuItem(
    SortOption option,
    String label,
    ({SortOption option, bool ascending}) sortState,
    Color activeColor,
  ) {
    final isSelected = sortState.option == option;
    final textColor = AppTheme.textPrimaryOf(isDark);
    return PopupMenuItem<SortOption>(
      value: option,
      height: 44,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontFamily: AppTheme.fontDisplay,
              color: isSelected ? activeColor : textColor,
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              fontSize: 12,
              letterSpacing: 0.3,
            ),
          ),
          if (isSelected)
            Icon(
              sortState.ascending
                  ? Icons.arrow_upward_rounded
                  : Icons.arrow_downward_rounded,
              color: activeColor,
              size: 14,
            ),
        ],
      ),
    );
  }

  Future<void> _showClearHistorySheet(
    BuildContext context,
    DownloadProvider provider,
  ) async {
    final tasksToClear = provider.filteredTasks
        .where((task) => !isHomeActiveTask(task))
        .toList();
    if (tasksToClear.isEmpty) return;

    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final title = isRtl
        ? 'مسح سجل التنزيلات (${tasksToClear.length})'
        : 'Clear Download History (${tasksToClear.length})';
    final message = isRtl
        ? 'هل أنت متأكد من حذف جميع ${tasksToClear.length} سجل مكتمل؟ لا يمكن التراجع عن هذا الإجراء.'
        : 'Delete all ${tasksToClear.length} completed records? This action cannot be undone.';

    final confirmed = await showDmxModalBottomSheet<bool>(
      context: context,
      builder: (sheetCtx) => DmxSheetContainer(
        isDark: isDark,
        isAmoled: isAmoled,
        accentColor: redClr,
        header: DmxSheetHeader(
          title: title,
          icon: Icons.delete_sweep_rounded,
          accentColor: redClr,
          isDark: isDark,
        ),
        footer: DmxSheetActionBar(
          isDark: isDark,
          isAmoled: isAmoled,
          secondaryLabel: L10n.of(context, 'cancel_btn'),
          onSecondary: () => Navigator.of(sheetCtx).pop(false),
          primaryLabel: L10n.of(context, 'clear_all').toUpperCase(),
          primaryDestructive: true,
          primaryIcon: Icons.delete_outline_rounded,
          onPrimary: () => Navigator.of(sheetCtx).pop(true),
        ),
        child: DmxSheetSection(
          isDark: isDark,
          isAmoled: isAmoled,
          accentColor: redClr,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, color: redClr, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    fontFamily: AppTheme.fontBody,
                    fontSize: 13,
                    height: 1.45,
                    color: AppTheme.textSecondaryOf(isDark),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed == true && context.mounted) {
      await provider
          .deleteMultipleTasks(tasksToClear.map((t) => t.id).toList());
    }
  }
}
