import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/search_engine_config.dart';

/// Reusable styled search engine selector pill widget (U3).
class SearchEngineSelectorWidget extends StatelessWidget {
  final SettingsProvider settings;
  final bool isDark;
  final bool isRtl;

  const SearchEngineSelectorWidget({
    super.key,
    required this.settings,
    required this.isDark,
    required this.isRtl,
  });

  @override
  Widget build(BuildContext context) {
    final accentColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
            .withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.travel_explore_rounded,
            size: 15,
            color:
                isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
          ),
          const SizedBox(width: 8),
          Text(
            isRtl ? 'محرك البحث:' : 'Search engine:',
            style: TextStyle(
              color:
                  isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(width: 8),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: settings.searchEngine,
              dropdownColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
              menuMaxHeight: 250,
              style: TextStyle(
                color: accentColor,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
              icon: Icon(Icons.arrow_drop_down, color: accentColor, size: 16),
              items: SearchEngineConfig.engines.map((e) {
                return DropdownMenuItem<String>(
                  value: e.name,
                  child: Text(e.name),
                );
              }).toList(),
              onChanged: (val) {
                if (val != null) {
                  HapticHelper.triggerHaptic(settings);
                  settings.setSearchEngine(val);
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}
