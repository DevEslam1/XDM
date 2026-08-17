import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/browser_controller.dart';

class BrowserFindPanel extends StatelessWidget {
  final BrowserController controller;
  final SettingsProvider settings;

  const BrowserFindPanel({
    super.key,
    required this.controller,
    required this.settings,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = settings.isDarkMode;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.surface : AppTheme.lightSurface,
        border: Border(
          bottom: BorderSide(
            color: isDark ? AppTheme.border : AppTheme.lightBorder,
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        bottom: false,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller.findTextController,
                autofocus: true,
                style: TextStyle(fontSize: 13, color: textClr),
                decoration: InputDecoration(
                  hintText: L10n.of(context, 'browser_find_in_page'),
                  hintStyle: TextStyle(
                    fontSize: 13,
                    color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  suffixIcon: controller.findTextController.text.isNotEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Center(
                            widthFactor: 1,
                            child: Text(
                              controller.findMatchCount > 0
                                  ? '${controller.findActiveMatch}/${controller.findMatchCount}'
                                  : (L10n.isRtl(context) ? 'لا نتائج' : '0/0'),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: controller.findMatchCount > 0
                                    ? (isDark
                                        ? AppTheme.neonBlue
                                        : AppTheme.lightNeonBlue)
                                    : (isDark
                                        ? AppTheme.neonRed
                                        : AppTheme.lightNeonRed),
                              ),
                            ),
                          ),
                        )
                      : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color: isDark ? AppTheme.border : AppTheme.lightBorder,
                    ),
                  ),
                ),
                onChanged: (val) {
                  controller.searchFindQuery(val);
                },
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 20),
              onPressed: () => controller.findPrevious(),
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
              onPressed: () => controller.findNext(),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: () => controller.closeFindPanel(),
            ),
          ],
        ),
      ),
    );
  }
}
