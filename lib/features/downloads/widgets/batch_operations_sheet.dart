import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/utils/localization.dart';
import '../provider/download_provider.dart';
import '../models/download_task.dart';

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
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
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
    final theme = Theme.of(context);
    final count = widget.selectedTaskIds.length;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(50),
            blurRadius: 16,
            spreadRadius: 2,
          ),
        ],
      ),
      padding: EdgeInsetsDirectional.only(
        start: 20,
        end: 20,
        top: 16,
        bottom: MediaQuery.of(context).padding.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: theme.dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Title
          Row(
            children: [
              Icon(Icons.checklist_rtl_rounded,
                  color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Text(
                L10n.of(context, 'selected_count', args: {'count': count}),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const Divider(height: 24),
          // Action Buttons
          if (widget.initialAction == null ||
              widget.initialAction == BatchAction.resume) ...[
            ListTile(
              leading:
                  const Icon(Icons.play_arrow_rounded, color: Colors.green),
              title: Text(L10n.of(context, 'resume_selected')),
              onTap: () async {
                final navigator = Navigator.of(context);
                final provider = context.read<DownloadProvider>();
                final resumableIds = widget.selectedTaskIds.where((id) {
                  final matches = provider.tasks.where((t) => t.id == id);
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
          ],
          if (widget.initialAction == null ||
              widget.initialAction == BatchAction.pause) ...[
            ListTile(
              leading: const Icon(Icons.pause_rounded, color: Colors.amber),
              title: Text(L10n.of(context, 'pause_selected')),
              onTap: () async {
                final navigator = Navigator.of(context);
                final provider = context.read<DownloadProvider>();
                try {
                  await provider.pauseMultipleTasks(widget.selectedTaskIds);
                } catch (e) {
                  debugPrint('[BatchOperations] Pause failed: $e');
                }
                if (!mounted) return;
                navigator.pop();
                widget.onCompleted?.call();
              },
            ),
          ],
          if (widget.initialAction == null ||
              widget.initialAction == BatchAction.changeCategory) ...[
            ListTile(
              leading: const Icon(Icons.category_rounded, color: Colors.blue),
              title: Text(L10n.of(context, 'change_category')),
              onTap: () async {
                final navigator = Navigator.of(context);
                final provider = context.read<DownloadProvider>();
                final category = await _showCategoryDialog(context);
                if (!mounted || category == null) return;
                try {
                  await provider.changeCategoryForMultipleTasks(
                    widget.selectedTaskIds,
                    category,
                  );
                } catch (e) {
                  debugPrint('[BatchOperations] Category change failed: $e');
                }
                if (!mounted) return;
                navigator.pop();
                widget.onCompleted?.call();
              },
            ),
          ],
          if (widget.initialAction == null ||
              widget.initialAction == BatchAction.delete) ...[
            StatefulBuilder(
              builder: (context, setCheckboxState) {
                return CheckboxListTile(
                  value: _deleteFiles,
                  title: Text(L10n.of(context, 'delete_files_disk')),
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: Colors.redAccent,
                  onChanged: (val) {
                    setCheckboxState(() {
                      _deleteFiles = val ?? false;
                    });
                  },
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever_rounded,
                  color: Colors.redAccent),
              title: Text(
                L10n.of(context, 'delete_downloads_count',
                    args: {'count': count}),
                style: const TextStyle(
                    color: Colors.redAccent, fontWeight: FontWeight.bold),
              ),
              onTap: () async {
                final navigator = Navigator.of(context);
                final provider = context.read<DownloadProvider>();
                final confirm = await _showDeleteConfirmDialog(context, count);
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
        ],
      ),
    );
  }

  Future<String?> _showCategoryDialog(BuildContext context) {
    final categories = [
      'General',
      'Video',
      'Audio',
      'Documents',
      'Archives',
      'Software'
    ];
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(L10n.of(ctx, 'select_category')),
        children: categories.map((cat) {
          return SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(cat),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                L10n.translateCategory(ctx, cat),
                style: const TextStyle(fontSize: 16),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Future<bool?> _showDeleteConfirmDialog(BuildContext context, int count) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          count == 1
              ? L10n.of(ctx, 'delete_download_single')
              : L10n.of(ctx, 'delete_downloads_count', args: {'count': count}),
        ),
        content: Text(
          _deleteFiles
              ? L10n.of(ctx, 'delete_files_label')
              : L10n.of(ctx, 'delete_desc'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(L10n.of(ctx, 'cancel_btn')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(L10n.of(ctx, 'delete_btn')),
          ),
        ],
      ),
    );
  }
}
