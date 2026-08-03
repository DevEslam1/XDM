import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../provider/download_provider.dart';

/// Modal bottom sheet allowing users to perform bulk actions on selected tasks.
class BatchOperationsSheet extends StatefulWidget {
  final List<String> selectedTaskIds;
  final VoidCallback? onCompleted;

  const BatchOperationsSheet({
    super.key,
    required this.selectedTaskIds,
    this.onCompleted,
  });

  static Future<void> show(
    BuildContext context, {
    required List<String> selectedTaskIds,
    VoidCallback? onCompleted,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => BatchOperationsSheet(
        selectedTaskIds: selectedTaskIds,
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
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
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
                'Batch Actions ($count selected)',
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
          ListTile(
            leading: const Icon(Icons.play_arrow_rounded, color: Colors.green),
            title: const Text('Resume Selected'),
            onTap: () async {
              final navigator = Navigator.of(context);
              final provider = context.read<DownloadProvider>();
              try {
                await provider.resumeMultipleTasks(widget.selectedTaskIds);
              } catch (e) {
                debugPrint('[BatchOperations] Resume failed: $e');
              }
              if (!mounted) return;
              navigator.pop();
              widget.onCompleted?.call();
            },
          ),
          ListTile(
            leading: const Icon(Icons.pause_rounded, color: Colors.amber),
            title: const Text('Pause Selected'),
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
          ListTile(
            leading: const Icon(Icons.category_rounded, color: Colors.blue),
            title: const Text('Change Category'),
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
          StatefulBuilder(
            builder: (context, setCheckboxState) {
              return CheckboxListTile(
                value: _deleteFiles,
                title: const Text('Also delete downloaded files from disk'),
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
              'Delete Selected ($count)',
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
        title: const Text('Select Category'),
        children: categories.map((cat) {
          return SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(cat),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(cat, style: const TextStyle(fontSize: 16)),
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
        title: Text('Delete $count Downloads?'),
        content: Text(
          _deleteFiles
              ? 'This will permanently remove the selected download entries and delete their local files.'
              : 'This will remove the selected download entries from the list.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
