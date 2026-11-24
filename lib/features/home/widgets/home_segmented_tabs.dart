import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/intl_formatters.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/responsive.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../downloads/widgets/filter_chips_bar.dart';

/// Returns true if [task] belongs on the Active tab (not completed/failed, or actively seeding).
bool isHomeActiveTask(DownloadTask task) {
  return (task.status != DownloadStatus.completed &&
          task.status != DownloadStatus.failed) ||
      task.isActivelySeeding;
}

/// Refined segmented tab switcher (Active / Completed) with crisp tabular counts
/// and calm surface hierarchy.
class HomeSegmentedTabs extends StatelessWidget {
  final int selectedTab;
  final bool isDark;
  final bool isAmoled;
  final ValueChanged<int> onTabSelected;

  const HomeSegmentedTabs({
    super.key,
    required this.selectedTab,
    required this.isDark,
    required this.isAmoled,
    required this.onTabSelected,
  });

  @override
  Widget build(BuildContext context) {
    final surfaceClr = AppTheme.surfaceColor(isDark, isAmoled: isAmoled);
    final borderClr = AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);

    return Selector<DownloadProvider, ({int active, int history})>(
      selector: (_, p) {
        final allTasks = p.filteredTasks;
        var active = 0;
        var history = 0;
        for (final t in allTasks) {
          if (isHomeActiveTask(t)) {
            active++;
          } else {
            history++;
          }
        }
        return (active: active, history: history);
      },
      builder: (context, counts, _) {
        final accentClr = context.select<DownloadProvider, Color>(
          (p) => getActiveFilterColor(p, isDark),
        );

        return Padding(
          padding:
              EdgeInsets.symmetric(horizontal: screenPadding(context).left),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: surfaceClr,
              borderRadius: BorderRadius.circular(DmxTokens.radiusLg),
              border: Border.all(color: borderClr, width: DmxTokens.borderThin),
              boxShadow: AppTheme.cardShadow(isDark),
            ),
            child: Row(
              children: [
                _SegmentPill(
                  index: 0,
                  label: L10n.of(context, 'active_tab'),
                  count: counts.active,
                  isSelected: selectedTab == 0,
                  isDark: isDark,
                  accentClr: accentClr,
                  onTap: () => onTabSelected(0),
                ),
                const SizedBox(width: 4),
                _SegmentPill(
                  index: 1,
                  label: L10n.of(context, 'completed_tab'),
                  count: counts.history,
                  isSelected: selectedTab == 1,
                  isDark: isDark,
                  accentClr: accentClr,
                  onTap: () => onTabSelected(1),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SegmentPill extends StatelessWidget {
  final int index;
  final String label;
  final int count;
  final bool isSelected;
  final bool isDark;
  final Color accentClr;
  final VoidCallback onTap;

  const _SegmentPill({
    required this.index,
    required this.label,
    required this.count,
    required this.isSelected,
    required this.isDark,
    required this.accentClr,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final selectedFg = AppTheme.inkOn(accentClr);
    final unselectedFg = AppTheme.textSecondaryOf(isDark);

    return Expanded(
      child: Semantics(
        selected: isSelected,
        button: true,
        label: '$label, $count',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
            child: AnimatedContainer(
              duration: AppTheme.motionBase,
              curve: AppTheme.motionCurve,
              constraints: const BoxConstraints(minHeight: 42),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: isSelected ? accentClr : Colors.transparent,
                borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color:
                              accentClr.withValues(alpha: isDark ? 0.28 : 0.20),
                          blurRadius: 10,
                          spreadRadius: -2,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isSelected ? selectedFg : unselectedFg,
                        fontFamily: AppTheme.fontDisplay,
                        fontSize: responsiveFontSize(context, 13),
                        fontWeight:
                            isSelected ? FontWeight.w700 : FontWeight.w600,
                      ),
                    ),
                  ),
                  if (count > 0) ...[
                    const SizedBox(width: 7),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? selectedFg.withValues(alpha: 0.20)
                            : accentClr.withValues(alpha: isDark ? 0.14 : 0.10),
                        borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
                      ),
                      child: Text(
                        count > 99
                            ? '99+'
                            : formatLocalizedNumber(context, count),
                        style: AppTheme.dataStyle(
                          isDark: isDark,
                          size: 11,
                          weight: FontWeight.w700,
                          color: isSelected ? selectedFg : accentClr,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
