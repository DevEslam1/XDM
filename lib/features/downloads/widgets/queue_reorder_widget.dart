import 'dart:ui';

import 'package:dmx/core/app_theme.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/shared/design/dmx_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class QueueReorderWidget extends StatefulWidget {
  const QueueReorderWidget({
    super.key,
    required this.queueTasks,
    required this.onReorder,
    this.onUndo,
  });

  final List<DownloadTask> queueTasks;
  final Function(int oldIndex, int newIndex) onReorder;
  final VoidCallback? onUndo;

  @override
  State<QueueReorderWidget> createState() => _QueueReorderWidgetState();
}

class _QueueReorderWidgetState extends State<QueueReorderWidget> {
  late List<DownloadTask> _items;

  @override
  void initState() {
    super.initState();
    _items = List.from(widget.queueTasks);
  }

  @override
  void didUpdateWidget(covariant QueueReorderWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _items = List.from(widget.queueTasks);
  }

  void _handleReorder(int oldIndex, int newIndex) {
    HapticFeedback.mediumImpact();
    setState(() {
      if (oldIndex < newIndex) {
        newIndex -= 1;
      }
      final item = _items.removeAt(oldIndex);
      _items.insert(newIndex, item);
    });

    widget.onReorder(oldIndex, newIndex);

    if (widget.onUndo != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Queue reordered'),
          action: SnackBarAction(
            label: 'UNDO',
            onPressed: () {
              HapticFeedback.selectionClick();
              widget.onUndo?.call();
            },
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Download queue is empty'),
        ),
      );
    }

    return ReorderableListView.builder(
      itemCount: _items.length,
      itemExtent: 80.0,
      onReorderItem: _handleReorder,
      proxyDecorator: (child, index, animation) {
        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final animValue = Curves.easeInOut.transform(animation.value);
            final elevation = lerpDouble(0, 8, animValue)!;
            final scale = lerpDouble(1, 1.03, animValue)!;

            return Transform.scale(
              scale: scale,
              child: Card(
                elevation: elevation,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: child,
              ),
            );
          },
          child: child,
        );
      },
      itemBuilder: (context, index) {
        final task = _items[index];
        final isDownloading = task.status == DownloadStatus.downloading;
        final priorityColor = isDownloading
            ? (isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet)
            : Colors.grey;

        return Padding(
          key: ValueKey(task.id),
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: DmxCardShell(
            accent: priorityColor,
            showRail: isDownloading,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 4,
              ),
              leading: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: priorityColor.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    '#${index + 1}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: priorityColor,
                    ),
                  ),
                ),
              ),
              title: Text(
                task.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                'Status: ${task.status.name.toUpperCase()} • Priority: $index',
                style: const TextStyle(fontSize: 11),
              ),
              trailing: ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Icon(Icons.drag_handle_rounded, color: Colors.grey),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
