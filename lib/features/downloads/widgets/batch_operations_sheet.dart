import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_design.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/widgets/dmx_bottom_sheet.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/download_task.dart';
import '../provider/download_provider.dart';

/// Modal bottom sheet allowing users to perform bulk actions on selected tasks.
enum BatchAction { pause, resume, delete, changeCategory }

class BatchOperationsSheet extends StatefulWidget {
  final List<String> selectedTaskIds;
  final BatchAction? initialAction;
  final VoidCallback? onCompleted;

  const BatchOperationsSheet({
    super.key,
    required this.selectedTaskIds,
    this.initialAction,
    this.onCompleted,
  });

  static Future<void> show(
    BuildContext context, {
    required List<String> selectedTaskIds,
    BatchAction? initialAction,
    VoidCallback? onCompleted,
  }) {
    return showDmxModalBottomSheet<void>(
      context: context,
      builder: (ctx) => BatchOperationsSheet(
        selectedTaskIds: selectedTaskIds,
        initialAction: initialAction,
        onCompleted: onCompleted,
      ),
    );
  }

  @override
  State<BatchOperationsSheet> createState() => _BatchOperationsSheetState();
}

class _BatchOperationsSheetState extends State<BatchOperationsSheet> {
  bool _deleteFiles = false;

  @override
  Widget build(BuildContext context) {
    if (widget.selectedTaskIds.isEmpty) {
      return const SizedBox.shrink();
    }

    final isDark = context.select<SettingsProvider, bool>((s) => s.isDarkMode);
    final provider = context.read<DownloadProvider>();
    final count = widget.selectedTaskIds.length;

    final selectedIdSet = widget.selectedTaskIds.toSet();
    int activeCount = 0;
    int pausedCount = 0;
    int failedCount = 0;
    for (final task in provider.tasks) {
      if (!selectedIdSet.contains(task.id)) continue;
      if (task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued) {
        activeCount++;
      } else if (task.status == DownloadStatus.paused) {
        pausedCount++;
      } else if (task.status == DownloadStatus.failed) {
        failedCount++;
      }
    }

    final summaryParts = <String>[
      if (activeCount > 0) '$activeCount active',
      if (pausedCount > 0) '$pausedCount paused',
      if (failedCount > 0) '$failedCount failed',
    ];
    final subtitle = summaryParts.isNotEmpty
        ? summaryParts.join(' · ')
        : '$count items ready for batch action';

    final accent = AppTheme.accent(isDark);
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final amberClr = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final textSecondary = AppTheme.textSecondaryOf(isDark);

    final showResume = widget.initialAction == null ||
        widget.initialAction == BatchAction.resume;
    final showPause = widget.initialAction == null ||
        widget.initialAction == BatchAction.pause;
    final showCategory = widget.initialAction == null ||
        widget.initialAction == BatchAction.changeCategory;
    final showDelete = widget.initialAction == null ||
        widget.initialAction == BatchAction.delete;

    final resumableCount = pausedCount + failedCount;

    return DmxSheetContainer(
      isDark: isDark,
      accentColor: widget.initialAction == BatchAction.delete ? redClr : accent,
      scrollable: true,
      header: DmxSheetHeader(
        title: L10n.of(context, 'selected_count', args: {'count': count}),
        subtitle: subtitle,
        icon: Icons.checklist_rtl_rounded,
        accentColor:
            widget.initialAction == BatchAction.delete ? redClr : accent,
        isDark: isDark,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showResume || showPause || showCategory)
            DmxSheetSection(
              isDark: isDark,
              padding: const EdgeInsets.all(6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showResume)
                    _BatchActionTile(
                      icon: Icons.play_arrow_rounded,
                      color: greenClr,
                      title: L10n.of(context, 'resume_selected'),
                      badge: resumableCount > 0 ? '$resumableCount' : null,
                      isDark: isDark,
                      onTap: () async {
                        final navigator = Navigator.of(context);
                        final resumableIds = widget.selectedTaskIds.where((id) {
                          final matches =
                              provider.tasks.where((t) => t.id == id);
                          if (matches.isEmpty) return false;
                          final status = matches.first.status;
                          return status == DownloadStatus.paused ||
                              status == DownloadStatus.failed;
                        }).toList();
                        try {
                          await provider.resumeMultipleTasks(resumableIds);
                        } catch (e) {
                          debugPrint('[BatchOperations] Resume failed: $e');
                        }
                        if (!mounted) return;
                        navigator.pop();
                        widget.onCompleted?.call();
                      },
                    ),
                  if (showPause)
                    _BatchActionTile(
                      icon: Icons.pause_rounded,
                      color: amberClr,
                      title: L10n.of(context, 'pause_selected'),
                      badge: activeCount > 0 ? '$activeCount' : null,
                      isDark: isDark,
                      onTap: () async {
                        final navigator = Navigator.of(context);
                        try {
                          await provider
                              .pauseMultipleTasks(widget.selectedTaskIds);
                        } catch (e) {
                          debugPrint('[BatchOperations] Pause failed: $e');
                        }
                        if (!mounted) return;
                        navigator.pop();
                        widget.onCompleted?.call();
                      },
                    ),
                  if (showCategory)
                    _BatchActionTile(
                      icon: Icons.category_rounded,
                      color: blueClr,
                      title: L10n.of(context, 'change_category'),
                      isDark: isDark,
                      onTap: () async {
                        final navigator = Navigator.of(context);
                        final category =
                            await _showCategorySheet(context, isDark);
                        if (!mounted || category == null) return;
                        try {
                          await provider.changeCategoryForMultipleTasks(
                            widget.selectedTaskIds,
                            category,
                          );
                        } catch (e) {
                          debugPrint(
                              '[BatchOperations] Category change failed: $e');
                        }
                        if (!mounted) return;
                        navigator.pop();
                        widget.onCompleted?.call();
                      },
                    ),
                ],
              ),
            ),
          if (showDelete) ...[
            if (showResume || showPause || showCategory)
              const SizedBox(height: DmxTokens.spaceMd),
            DmxSheetSection(
              isDark: isDark,
              accentColor: redClr,
              padding: const EdgeInsets.all(6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CheckboxListTile(
                    value: _deleteFiles,
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                    ),
                    title: Text(
                      L10n.of(context, 'delete_files_disk'),
                      style: TextStyle(
                        color: textPrimary,
                        fontFamily: AppTheme.fontBody,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    subtitle: Text(
                      _deleteFiles
                          ? 'Downloaded files will be permanently removed'
                          : 'Only removes entries from DMX list',
                      style: TextStyle(
                        color: textSecondary,
                        fontFamily: AppTheme.fontBody,
                        fontSize: 11,
                      ),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: redClr,
                    onChanged: (val) {
                      setState(() => _deleteFiles = val ?? false);
                    },
                  ),
                  const SizedBox(height: 4),
                  _BatchActionTile(
                    icon: Icons.delete_forever_rounded,
                    color: redClr,
                    title: L10n.of(
                      context,
                      'delete_downloads_count',
                      args: {'count': count},
                    ),
                    destructive: true,
                    isDark: isDark,
                    onTap: () async {
                      final navigator = Navigator.of(context);
                      final confirm =
                          await _showDeleteConfirmDialog(context, count);
                      if (!mounted || confirm != true) return;
                      try {
                        await provider.deleteMultipleTasks(
                          widget.selectedTaskIds,
                          deleteFiles: _deleteFiles,
                        );
                      } catch (e) {
                        debugPrint('[BatchOperations] Delete failed: $e');
                      }
                      if (!mounted) return;
                      navigator.pop();
                      widget.onCompleted?.call();
                    },
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<String?> _showCategorySheet(BuildContext context, bool isDark) {
    const categories = [
      ('Video', Icons.movie_outlined),
      ('Audio', Icons.audiotrack_outlined),
      ('Document', Icons.description_outlined),
      ('Archive', Icons.folder_zip_outlined),
      ('APK', Icons.android_outlined),
      ('Other', Icons.insert_drive_file_outlined),
    ];
    final accent = AppTheme.accent(isDark);

    return showDmxModalBottomSheet<String>(
      context: context,
      builder: (ctx) => DmxSheetContainer(
        isDark: isDark,
        accentColor: accent,
        scrollable: true,
        header: DmxSheetHeader(
          title: L10n.of(ctx, 'select_category'),
          icon: Icons.category_rounded,
          accentColor: accent,
          isDark: isDark,
        ),
        child: DmxSheetSection(
          isDark: isDark,
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: categories.map((entry) {
              final (cat, icon) = entry;
              return _BatchActionTile(
                icon: icon,
                color: accent,
                title: L10n.translateCategory(ctx, cat),
                isDark: isDark,
                onTap: () => Navigator.of(ctx).pop(cat),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Future<bool?> _showDeleteConfirmDialog(BuildContext context, int count) {
    return DmxConfirmDialog.show(
      context,
      title: count == 1
          ? L10n.of(context, 'delete_download_single')
          : L10n.of(context, 'delete_downloads_count', args: {'count': count}),
      message: _deleteFiles
          ? L10n.of(context, 'delete_files_label')
          : L10n.of(context, 'delete_desc'),
      confirmLabel: L10n.of(context, 'delete_btn'),
      cancelLabel: L10n.of(context, 'cancel_btn'),
      isDestructive: true,
    );
  }
}

class _BatchActionTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String? badge;
  final bool destructive;
  final bool isDark;
  final VoidCallback onTap;

  const _BatchActionTile({
    required this.icon,
    required this.color,
    required this.title,
    this.badge,
    this.destructive = false,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
      ),
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color.withValues(alpha: isDark ? 0.15 : 0.11),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 19, color: color),
      ),
      title: Text(
        title,
        style: TextStyle(
          color: destructive ? color : textPrimary,
          fontFamily: AppTheme.fontDisplay,
          fontSize: 13.5,
          fontWeight: destructive ? FontWeight.w700 : FontWeight.w600,
        ),
      ),
      trailing: badge != null
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: isDark ? 0.16 : 0.12),
                borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
              ),
              child: Text(
                badge!,
                style: TextStyle(
                  color: color,
                  fontFamily: AppTheme.fontDisplay,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          : Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: destructive
                  ? color.withValues(alpha: 0.7)
                  : AppTheme.textMutedOf(isDark),
            ),
      onTap: onTap,
    );
  }
}
