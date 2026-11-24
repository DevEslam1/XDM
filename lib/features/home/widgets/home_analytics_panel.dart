import 'package:fl_chart/fl_chart.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_design.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';

/// Clean, collapsible storage analytics card showing category breakdown
/// with an interactive donut chart and scannable legend rows.
class HomeAnalyticsPanel extends StatelessWidget {
  final Map<String, double> categorySizes;
  final bool isDark;
  final bool isAmoled;
  final Color activeFilterClr;

  const HomeAnalyticsPanel({
    super.key,
    required this.categorySizes,
    required this.isDark,
    required this.isAmoled,
    required this.activeFilterClr,
  });

  @override
  Widget build(BuildContext context) {
    final textClr = AppTheme.textPrimaryOf(isDark);
    final mutedClr = AppTheme.textMutedOf(isDark);
    final isRtl = L10n.isRtl(context);
    final totalSizeMb = categorySizes.values.fold(0.0, (sum, val) => sum + val);
    final hasNoData = totalSizeMb <= 0.0;
    final totalSizeText = totalSizeMb >= 1024
        ? '${(totalSizeMb / 1024).toStringAsFixed(2)} GB'
        : '${totalSizeMb.toStringAsFixed(1)} MB';

    final categories = [
      (
        name: 'Video',
        color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
        icon: Icons.movie_rounded,
      ),
      (
        name: 'Audio',
        color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
        icon: Icons.audiotrack_rounded,
      ),
      (
        name: 'Document',
        color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
        icon: Icons.description_rounded,
      ),
      (
        name: 'Archive',
        color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
        icon: Icons.folder_zip_rounded,
      ),
      (
        name: 'APK',
        color: const Color(0xFFE05297),
        icon: Icons.android_rounded,
      ),
      (
        name: 'Other',
        color: AppTheme.textSecondaryOf(isDark),
        icon: Icons.insert_drive_file_rounded,
      ),
    ];

    final activeCategories = hasNoData
        ? <({String name, Color color, IconData icon})>[]
        : categories.where((c) => (categorySizes[c.name] ?? 0.0) > 0).toList();

    final sections = hasNoData
        ? [
            PieChartSectionData(
              color: AppTheme.hairlineBorder(isDark, isAmoled: isAmoled),
              value: 1.0,
              radius: 14,
              title: '',
            ),
          ]
        : activeCategories.map((cat) {
            final sizeMb = categorySizes[cat.name] ?? 0.0;
            return PieChartSectionData(
              color: cat.color,
              value: sizeMb,
              radius: 14,
              title: '',
            );
          }).toList();

    return DmxCardShell(
      accent: activeFilterClr,
      radius: DmxTokens.radiusLg,
      showRail: false,
      child: Padding(
        padding: const EdgeInsets.all(DmxTokens.spaceLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color:
                        activeFilterClr.withValues(alpha: isDark ? 0.14 : 0.10),
                    borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
                  ),
                  child: Icon(
                    Icons.storage_rounded,
                    size: 15,
                    color: activeFilterClr,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    L10n.of(context, 'storage_analytics'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.microLabel(isDark: isDark, color: mutedClr),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.panelBg(isDark, isAmoled: isAmoled),
                    borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
                    border: Border.all(
                      color:
                          AppTheme.hairlineBorder(isDark, isAmoled: isAmoled),
                      width: DmxTokens.borderThin,
                    ),
                  ),
                  child: Text(
                    totalSizeText,
                    style: AppTheme.dataStyle(
                      isDark: isDark,
                      size: 12,
                      weight: FontWeight.w700,
                      color: textClr,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: DmxTokens.spaceLg),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 108,
                  height: 108,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      PieChart(
                        PieChartData(
                          pieTouchData: PieTouchData(
                            touchCallback:
                                (FlTouchEvent event, pieTouchResponse) {
                              if (!event.isInterestedForInteractions ||
                                  pieTouchResponse?.touchedSection == null) {
                                return;
                              }
                              final idx = pieTouchResponse!
                                  .touchedSection!.touchedSectionIndex;
                              if (idx >= 0 && idx < activeCategories.length) {
                                context
                                    .read<DownloadProvider>()
                                    .toggleCategoryFilter(
                                      activeCategories[idx].name,
                                    );
                              }
                            },
                          ),
                          sections: sections,
                          centerSpaceRadius: 34,
                          sectionsSpace: 2.5,
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            hasNoData ? '0' : '${activeCategories.length}',
                            style: AppTheme.dataStyle(
                              isDark: isDark,
                              size: 16,
                              weight: FontWeight.w800,
                              color: textClr,
                            ),
                          ),
                          Text(
                            isRtl ? 'فئات' : 'types',
                            style: TextStyle(
                              fontFamily: AppTheme.fontBody,
                              fontSize: 11,
                              color: mutedClr,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: DmxTokens.spaceLg),
                Expanded(
                  child: hasNoData
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Text(
                              L10n.of(context, 'no_data_available'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontFamily: AppTheme.fontBody,
                                color: mutedClr,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: activeCategories.map((cat) {
                            final sizeMb = categorySizes[cat.name] ?? 0.0;
                            final pct = totalSizeMb > 0
                                ? (sizeMb / totalSizeMb) * 100
                                : 0.0;
                            final sizeText = sizeMb >= 1024
                                ? '${(sizeMb / 1024).toStringAsFixed(1)} GB'
                                : '${sizeMb.toStringAsFixed(0)} MB';

                            return InkWell(
                              borderRadius:
                                  BorderRadius.circular(DmxTokens.radiusSm),
                              onTap: () {
                                runHaptic(context.read<SettingsProvider>());
                                context
                                    .read<DownloadProvider>()
                                    .toggleCategoryFilter(cat.name);
                              },
                              child: Semantics(
                                button: true,
                                label: 'Filter by ${cat.name}',
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 8,
                                        height: 8,
                                        decoration: BoxDecoration(
                                          color: cat.color,
                                          borderRadius:
                                              BorderRadius.circular(3),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          isRtl
                                              ? _translateCat(cat.name)
                                              : cat.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontFamily: AppTheme.fontBody,
                                            color: textClr,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '${pct.toStringAsFixed(0)}%',
                                        style: AppTheme.dataStyle(
                                          isDark: isDark,
                                          size: 11,
                                          weight: FontWeight.w700,
                                          color: cat.color,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        sizeText,
                                        style: AppTheme.dataStyle(
                                          isDark: isDark,
                                          size: 11,
                                          weight: FontWeight.w500,
                                          color: mutedClr,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _translateCat(String name) {
    switch (name) {
      case 'Video':
        return 'الفيديو';
      case 'Audio':
        return 'الصوت';
      case 'Document':
        return 'المستندات';
      case 'Archive':
        return 'الأرشيف';
      case 'APK':
        return 'التطبيقات';
      default:
        return 'أخرى';
    }
  }
}
