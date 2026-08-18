import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_design.dart';

/// Renders a list of files within a torrent download, displaying each file's
/// name, progress bar, downloaded / total bytes, and estimated progress indicators.
class TorrentFilesPanel extends StatefulWidget {
  final List<Map<String, dynamic>> torrentFiles;
  final bool? isDark;
  final bool? isRtl;
  final bool isDownloading;
  final void Function(int index, bool selected)? onFileToggle;
  final void Function(int index, int priority)? onPriorityChanged;
  final void Function(int index, String name)? onDeleteFile;
  final VoidCallback? onSelectAll;
  final VoidCallback? onDeselectAll;

  const TorrentFilesPanel({
    super.key,
    required this.torrentFiles,
    this.isDark,
    this.isRtl,
    this.isDownloading = false,
    this.onFileToggle,
    this.onPriorityChanged,
    this.onDeleteFile,
    this.onSelectAll,
    this.onDeselectAll,
  });

  @override
  State<TorrentFilesPanel> createState() => _TorrentFilesPanelState();
}

class _TorrentFilesPanelState extends State<TorrentFilesPanel> {
  bool _isExpanded = true;

  @override
  Widget build(BuildContext context) {
    final isDark =
        widget.isDark ?? (Theme.of(context).brightness == Brightness.dark);
    final bool isRtl;
    if (widget.isRtl != null) {
      isRtl = widget.isRtl!;
    } else {
      bool isRtlVal = false;
      try {
        isRtlVal = L10n.isRtl(context);
      } catch (_) {
        isRtlVal = Directionality.maybeOf(context) == TextDirection.rtl;
      }
      isRtl = isRtlVal;
    }

    // FIX v2.0.0: Show a loading indicator instead of blank space
    // when files haven't been received yet (metadata pending).
    if (widget.torrentFiles.isEmpty) {
      if (widget.isDownloading) {
        return DmxCardShell(
          showRail: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Text(
                  widget.isDownloading
                      ? (isRtl
                          ? 'جاري جلب ملفات وبيانات التورنت…'
                          : 'Waiting for torrent metadata…')
                      : (isRtl ? 'لا توجد ملفات متاحة' : 'No files available'),
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                  ),
                ),
              ],
            ),
          ),
        );
      }
      return const SizedBox.shrink();
    }

    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final amberClr = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;

    double calcFileProgress(Map<String, dynamic> f) {
      final length = (f['length'] as num?)?.toInt() ?? 0;
      final downloadedBytes = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      if (f['progress'] != null) {
        return ((f['progress'] as num).toDouble()).clamp(0.0, 1.0);
      } else if (length > 0 && downloadedBytes > 0) {
        return (downloadedBytes / length).clamp(0.0, 1.0);
      }
      return 0.0;
    }

    final files = widget.torrentFiles;
    final completedCount = files.where((f) {
      final isComp = (f['isComplete'] as bool?) ?? false;
      final prog = calcFileProgress(f);
      return isComp || prog >= 1.0;
    }).length;

    return DmxCardShell(
      showRail: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with toggle & counts
            InkWell(
              onTap: () => setState(() => _isExpanded = !_isExpanded),
              borderRadius: BorderRadius.circular(8),
              child: Row(
                children: [
                  Icon(Icons.folder_open_outlined, color: blueClr, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isRtl
                          ? 'ملفات التورنت (${files.length})'
                          : 'TORRENT FILES (${files.length})',
                      style: AppTheme.microLabel(isDark: isDark, size: 11),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: blueClr.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '$completedCount/${files.length} ${isRtl ? "مكتمل" : "done"}',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: blueClr,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    _isExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: mutedClr,
                    size: 20,
                  ),
                ],
              ),
            ),

            if (_isExpanded) ...[
              // Action buttons (Select All / Deselect All) if callbacks provided
              if (widget.onSelectAll != null ||
                  widget.onDeselectAll != null) ...[
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (widget.onSelectAll != null)
                      _PanelActionButton(
                        label: isRtl ? 'تحديد الكل' : 'SELECT ALL',
                        icon: Icons.select_all_rounded,
                        color: blueClr,
                        onPressed: widget.onSelectAll!,
                      ),
                    if (widget.onSelectAll != null &&
                        widget.onDeselectAll != null)
                      const SizedBox(width: 8),
                    if (widget.onDeselectAll != null)
                      _PanelActionButton(
                        label: isRtl ? 'إلغاء تحديد الكل' : 'DESELECT ALL',
                        icon: Icons.deselect_rounded,
                        color:
                            isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                        onPressed: widget.onDeselectAll!,
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: files.length,
                separatorBuilder: (context, index) => Divider(
                  height: 16,
                  thickness: 0.3,
                  color: isDark
                      ? AppTheme.borderSubtle
                      : AppTheme.lightBorderSubtle,
                ),
                itemBuilder: (context, index) {
                  final f = files[index];
                  final name = f['name'] as String? ?? 'file_${index + 1}';
                  final length = (f['length'] as num?)?.toInt() ?? 0;
                  final downloadedBytes =
                      (f['downloadedBytes'] as num?)?.toInt() ?? 0;
                  final selected = (f['selected'] as bool?) ?? true;
                  final isEstimated = (f['progressEstimated'] as bool?) == true;

                  // Progress calculation: prefer explicit progress field, fallback to downloaded/length
                  final progress = calcFileProgress(f);

                  final isComplete =
                      (f['isComplete'] as bool?) == true || progress >= 1.0;
                  final progressPercent = (progress * 100).clamp(0.0, 100.0);
                  final progressText = isEstimated
                      ? '≈${progressPercent.toStringAsFixed(0)}%'
                      : '${progressPercent.toStringAsFixed(1)}%';

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.onFileToggle != null) ...[
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: Checkbox(
                            value: selected,
                            activeColor: blueClr,
                            side: BorderSide(
                              color: isDark
                                  ? AppTheme.border
                                  : AppTheme.lightBorder,
                              width: 1.0,
                            ),
                            onChanged: (val) {
                              if (val != null) {
                                widget.onFileToggle!(index, val);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Icon(
                        isComplete
                            ? Icons.check_circle_outline_rounded
                            : Icons.insert_drive_file_outlined,
                        size: 16,
                        color: isComplete
                            ? greenClr
                            : (selected ? textClr : mutedClr),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    name,
                                    style: TextStyle(
                                      color: selected ? textClr : mutedClr,
                                      fontSize: 12,
                                      fontWeight: selected
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                      decoration: selected
                                          ? null
                                          : TextDecoration.lineThrough,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (isEstimated) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1.5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: amberClr.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(
                                        color: amberClr.withValues(alpha: 0.4),
                                        width: 0.6,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.auto_awesome_outlined,
                                          size: 9,
                                          color: amberClr,
                                        ),
                                        const SizedBox(width: 2),
                                        Text(
                                          isRtl ? 'تقديري' : 'ESTIMATED',
                                          style: TextStyle(
                                            fontSize: 8,
                                            fontWeight: FontWeight.bold,
                                            color: amberClr,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                if (widget.onPriorityChanged != null &&
                                    selected) ...[
                                  const SizedBox(width: 6),
                                  _PriorityBadge(
                                    priority: (f['priority'] as int?) ?? 4,
                                    isDark: isDark,
                                    isRtl: isRtl,
                                    isCompleted: isComplete,
                                    onChanged: (newPriority) => widget
                                        .onPriorityChanged!(index, newPriority),
                                  ),
                                ],
                                if (widget.onDeleteFile != null) ...[
                                  const SizedBox(width: 4),
                                  InkWell(
                                    onTap: () =>
                                        widget.onDeleteFile!(index, name),
                                    borderRadius: BorderRadius.circular(6),
                                    child: Padding(
                                      padding: const EdgeInsets.all(2.0),
                                      child: Icon(
                                        Icons.delete_outline_rounded,
                                        size: 16,
                                        color: isDark
                                            ? AppTheme.neonRed
                                            : AppTheme.lightNeonRed,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 6),
                            if (selected) ...[
                              // Linear Progress Bar
                              Stack(
                                children: [
                                  Container(
                                    height: 4,
                                    width: double.infinity,
                                    decoration:
                                        AppTheme.progressTrack(isDark: isDark),
                                  ),
                                  FractionallySizedBox(
                                    widthFactor: progress,
                                    child: Container(
                                      height: 4,
                                      decoration: AppTheme.progressFill(
                                        isComplete
                                            ? greenClr
                                            : (widget.isDownloading
                                                ? blueClr
                                                : mutedClr),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    '${formatBytes(downloadedBytes)} / ${formatBytes(length)}',
                                    style: AppTheme.dataStyle(
                                      isDark: isDark,
                                      size: 10,
                                      weight: FontWeight.w500,
                                      color: mutedClr,
                                    ),
                                  ),
                                  Text(
                                    progressText,
                                    style: AppTheme.dataStyle(
                                      isDark: isDark,
                                      size: 10,
                                      color: isComplete
                                          ? greenClr
                                          : (isEstimated
                                              ? textClr.withValues(alpha: 0.6)
                                              : textClr),
                                    ),
                                  ),
                                ],
                              ),
                            ] else ...[
                              Text(
                                isRtl ? 'تم تخطيه' : 'Skipped',
                                style: TextStyle(
                                  color: mutedClr,
                                  fontSize: 10,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PanelActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  const _PanelActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PriorityBadge extends StatelessWidget {
  final int priority;
  final bool isDark;
  final bool isRtl;
  final bool isCompleted;
  final ValueChanged<int> onChanged;

  const _PriorityBadge({
    required this.priority,
    required this.isDark,
    required this.isRtl,
    required this.isCompleted,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final Color priorityColor;
    final String label;

    switch (priority) {
      case 7:
        priorityColor = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
        label = isRtl ? 'عالية' : 'High';
        break;
      case 1:
        priorityColor = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
        label = isRtl ? 'منخفضة' : 'Low';
        break;
      case 4:
      default:
        priorityColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
        label = isRtl ? 'عادية' : 'Normal';
        break;
    }

    final child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: priorityColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: priorityColor.withValues(alpha: 0.3),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              color: priorityColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: priorityColor,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (!isCompleted) ...[
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down, size: 12, color: priorityColor),
          ],
        ],
      ),
    );

    if (isCompleted) return child;

    return PopupMenuButton<int>(
      tooltip: isRtl ? 'تحديد الأولوية' : 'Set priority',
      padding: EdgeInsets.zero,
      color: isDark ? AppTheme.surface : AppTheme.lightSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
          width: 0.6,
        ),
      ),
      onSelected: onChanged,
      child: child,
      itemBuilder: (context) => [
        PopupMenuItem<int>(
          value: 7,
          height: 44,
          child: _priorityMenuItem(
            isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
            isRtl ? 'عالية' : 'High',
          ),
        ),
        PopupMenuItem<int>(
          value: 4,
          height: 44,
          child: _priorityMenuItem(
            isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
            isRtl ? 'عادية' : 'Normal',
          ),
        ),
        PopupMenuItem<int>(
          value: 1,
          height: 44,
          child: _priorityMenuItem(
            isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
            isRtl ? 'منخفضة' : 'Low',
          ),
        ),
      ],
    );
  }

  Widget _priorityMenuItem(Color color, String label) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w500,
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }
}
