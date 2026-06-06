import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../../core/app_theme.dart';
import '../../../../core/utils/localization.dart';
import '../../settings/provider/settings_provider.dart';
import '../provider/download_provider.dart';

class FilterChipsBar extends StatelessWidget {
  const FilterChipsBar({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<DownloadProvider>(context);
    final settings = Provider.of<SettingsProvider>(context);
    final isDark = settings.isDarkMode;
    final activeFilter = provider.statusFilter;
    final categoryFilter = provider.categoryFilter;
    final isRtl = L10n.isRtl(context);

    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final glassBg = isDark ? AppTheme.glassBg : AppTheme.lightGlassBg;
    final glassBorder = isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    final filters = ['All', 'Downloading', 'Completed', 'Failed'];

    return SizedBox(
      height: 40,
      child: Row(
        children: [
          if (categoryFilter != null) ...[
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: InputChip(
                label: Text(
                  '${isRtl ? 'تصنيف: ' : 'CAT: '}${categoryFilter.toUpperCase()}',
                  style: TextStyle(
                    color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                deleteIcon: Icon(
                  Icons.close_rounded,
                  size: 14,
                  color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                ),
                onDeleted: () {
                  if (settings.vibration) {
                    HapticFeedback.lightImpact();
                  }
                  provider.setCategoryFilter(null);
                },
                backgroundColor: (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen).withValues(alpha: 0.1),
                side: BorderSide(
                  color: (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen).withValues(alpha: 0.35),
                  width: 0.8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ],
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: filters.length,
              itemBuilder: (context, index) {
                final filter = filters[index];
                final isSelected = activeFilter == filter;

                // Derive status color matching task status colors
                final filterClr = switch (filter) {
                  'All' => isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                  'Downloading' => isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                  'Completed' => isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                  'Failed' => isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                  _ => isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                };

                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: InkWell(
                    onTap: () => provider.setStatusFilter(filter),
                    borderRadius: BorderRadius.circular(20),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeInOut,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? filterClr.withValues(alpha: 0.12)
                            : glassBg,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isSelected
                              ? filterClr.withValues(alpha: 0.5)
                              : glassBorder,
                          width: 1.0,
                        ),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: filterClr.withValues(alpha: isDark ? 0.35 : 0.15),
                                  blurRadius: 10.0,
                                  spreadRadius: 1.0,
                                )
                              ]
                            : null,
                      ),
                      child: Center(
                        widthFactor: 1.0,
                        heightFactor: 1.0,
                        child: Text(
                          filter.toUpperCase(),
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: isSelected ? filterClr : secClr,
                            fontSize: 10,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                            letterSpacing: 1.0,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
