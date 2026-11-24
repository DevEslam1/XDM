import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/responsive.dart';
import '../../../shared/design/dmx_design.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/widgets/skeleton_loader.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../downloads/widgets/download_card.dart';
import '../../downloads/widgets/filter_chips_bar.dart';
import '../../settings/provider/settings_provider.dart';
import 'home_segmented_tabs.dart';

class _RenderItem {
  final bool isPlaylist;
  final String? playlistId;
  final String? title;
  final List<DownloadTask>? items;
  final DownloadTask? task;

  const _RenderItem._({
    required this.isPlaylist,
    this.playlistId,
    this.title,
    this.items,
    this.task,
  });

  const _RenderItem.playlist({
    required String playlistId,
    required String title,
    required List<DownloadTask> items,
  }) : this._(
          isPlaylist: true,
          playlistId: playlistId,
          title: title,
          items: items,
        );

  const _RenderItem.single({required DownloadTask task})
      : this._(isPlaylist: false, task: task);
}

/// Responsive download task list supporting single-column list, multi-column
/// grid on wide surfaces, manual-sort reorderable queue, selection mode,
/// pull-to-refresh, and clean empty states.
class HomeTaskList extends StatelessWidget {
  final int selectedTab;
  final bool isDark;
  final bool isRtl;
  final VoidCallback? onClearSearch;
  final VoidCallback? onAddDownload;
  final Widget Function(double, Widget) stagger;

  const HomeTaskList({
    super.key,
    required this.selectedTab,
    required this.isDark,
    required this.isRtl,
    this.onClearSearch,
    this.onAddDownload,
    required this.stagger,
  });

  Widget _staggeredItem(BuildContext context, int index, Widget child) {
    final delay = (0.24 + index * 0.04).clamp(0.0, 1.0);
    return stagger(delay, child);
  }

  Widget _wrapSelectionMode(
    Widget card,
    _RenderItem item,
    DownloadProvider provider,
  ) {
    if (item.isPlaylist) return card;

    final isSelected = provider.selectedTaskIds.contains(item.task?.id);
    final isInSelectionMode = provider.isSelectionMode;
    return GestureDetector(
      onLongPress: () {
        if (!isInSelectionMode) {
          provider.toggleTaskSelection(item.task!.id);
        }
      },
      onTap: () {
        if (isInSelectionMode) {
          provider.toggleTaskSelection(item.task!.id);
        }
      },
      child: Row(
        children: [
          if (isInSelectionMode)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8.0),
              child: Checkbox(
                value: isSelected,
                onChanged: (_) => provider.toggleTaskSelection(item.task!.id),
                activeColor:
                    isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
          Expanded(child: card),
        ],
      ),
    );
  }

  Widget _buildTaskCard({
    required _RenderItem item,
    required int index,
    required bool compact,
    required bool showDragHandle,
  }) {
    if (item.isPlaylist) {
      return PlaylistGroupCard(
        key: ValueKey('playlist_${item.playlistId}'),
        playlistId: item.playlistId!,
        title: item.title!,
        items: item.items!,
      );
    }

    return Selector<DownloadProvider, DownloadTask?>(
      key: ValueKey(item.task!.id),
      selector: (_, p) => p.taskById(item.task!.id),
      shouldRebuild: (prev, next) {
        if (prev == null || next == null) return prev != next;
        return prev.status != next.status ||
            (prev.progress - next.progress).abs() > 0.005 ||
            (prev.speed - next.speed).abs() > 1024 ||
            prev.errorMessage != next.errorMessage ||
            prev.statusMessage != next.statusMessage ||
            prev.fileSize != next.fileSize ||
            (prev.downloadedBytes - next.downloadedBytes).abs() > 65536;
      },
      builder: (_, liveTask, __) {
        final effectiveTask = liveTask ?? item.task!;
        return DownloadCard(
          key: ValueKey(effectiveTask.id),
          task: effectiveTask,
          compact: compact,
          showDragHandle: showDragHandle,
          index: index,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLoading =
        context.select<DownloadProvider, bool>((p) => p.isLoadingTasks);

    Widget child;
    if (isLoading) {
      child = const SkeletonList(
        key: ValueKey('loading'),
        itemCount: 4,
        itemHeight: 110,
      );
    } else {
      child = Selector<DownloadProvider, List<DownloadTask>>(
        selector: (_, p) => p.filteredTasks,
        shouldRebuild: (prev, next) {
          if (prev.length != next.length) return true;
          for (var i = 0; i < prev.length; i++) {
            if (prev[i].id != next[i].id || prev[i].status != next[i].status) {
              return true;
            }
          }
          return false;
        },
        builder: (context, fullList, __) {
          final provider = context.read<DownloadProvider>();
          final displayTasks = fullList
              .where((task) => selectedTab == 0
                  ? isHomeActiveTask(task)
                  : !isHomeActiveTask(task))
              .toList();

          if (displayTasks.isEmpty) {
            return _HomeEmptyState(
              key: const ValueKey('empty'),
              selectedTab: selectedTab,
              isDark: isDark,
              isRtl: isRtl,
              onClearSearch: onClearSearch,
              onAddDownload: onAddDownload,
            );
          }

          final groups = <String, List<DownloadTask>>{};
          for (final t in displayTasks) {
            if (t.isPlaylistItem) {
              groups.putIfAbsent(t.playlistId!, () => []).add(t);
            }
          }

          final renderItems = <_RenderItem>[];
          final seenPlaylists = <String>{};
          for (final t in displayTasks) {
            if (t.isPlaylistItem) {
              if (seenPlaylists.contains(t.playlistId)) continue;
              seenPlaylists.add(t.playlistId!);
              renderItems.add(
                _RenderItem.playlist(
                  playlistId: t.playlistId!,
                  title: t.playlistTitle ?? 'Playlist',
                  items: groups[t.playlistId!]!,
                ),
              );
            } else {
              renderItems.add(_RenderItem.single(task: t));
            }
          }

          final isReorderable = selectedTab == 0 &&
              provider.sortOption == SortOption.manual &&
              provider.statusFilter == 'All' &&
              provider.searchQuery.isEmpty &&
              provider.categoryFilters.isEmpty;

          final horizontalPad = screenPadding(context).left;
          final bottomPadding = isTablet(context) ? 108.0 : 96.0;

          final Widget contentWidget;
          if (isReorderable) {
            contentWidget = KeyedSubtree(
              key: const ValueKey('reorderable'),
              child: ReorderableListView.builder(
                // ignore: deprecated_member_use
                cacheExtent: 500.0,
                padding: EdgeInsets.only(
                  left: horizontalPad,
                  right: horizontalPad,
                  bottom: bottomPadding,
                ),
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                itemCount: renderItems.length,
                onReorderItem: (oldIndex, newIndex) {
                  runHaptic(context.read<SettingsProvider>());
                  final p = context.read<DownloadProvider>();
                  if (p.statusFilter != 'All' ||
                      p.searchQuery.isNotEmpty ||
                      p.categoryFilters.isNotEmpty) {
                    debugPrint('[Queue] Reorder blocked in UI: filters active');
                    return;
                  }

                  final itemToMove = renderItems[oldIndex];
                  if (itemToMove.isPlaylist) return;

                  final taskToMove = itemToMove.task!;
                  final oldTaskIndex =
                      p.filteredTasks.indexWhere((t) => t.id == taskToMove.id);
                  int newTaskIndex;
                  if (newIndex >= renderItems.length) {
                    newTaskIndex = p.filteredTasks.length - 1;
                  } else {
                    final targetItem = renderItems[newIndex];
                    if (targetItem.isPlaylist) return;
                    newTaskIndex = p.filteredTasks
                        .indexWhere((t) => t.id == targetItem.task!.id);
                  }
                  if (oldTaskIndex != -1 && newTaskIndex != -1) {
                    p.reorderTasks(p.filteredTasks, oldTaskIndex, newTaskIndex);
                  }
                },
                itemBuilder: (context, index) {
                  final item = renderItems[index];
                  var card = _buildTaskCard(
                    item: item,
                    index: index,
                    compact: false,
                    showDragHandle: true,
                  );
                  card = _wrapSelectionMode(card, item, provider);
                  return Padding(
                    key: ValueKey(item.isPlaylist
                        ? 'playlist_${item.playlistId}'
                        : item.task!.id),
                    padding: const EdgeInsets.only(bottom: DmxTokens.cardGap),
                    child: RepaintBoundary(
                      child: _staggeredItem(context, index, card),
                    ),
                  );
                },
              ),
            );
          } else {
            final idToIndex = <String, int>{
              for (int i = 0; i < renderItems.length; i++)
                (renderItems[i].isPlaylist
                    ? 'playlist_${renderItems[i].playlistId}'
                    : (renderItems[i].task?.id ?? '')): i,
            };

            if (isMultiColumnLayout(context)) {
              contentWidget = KeyedSubtree(
                key: const ValueKey('grid'),
                child: GridView.builder(
                  // ignore: deprecated_member_use
                  cacheExtent: 500.0,
                  padding: EdgeInsets.only(
                    left: horizontalPad,
                    right: horizontalPad,
                    top: 4,
                    bottom: bottomPadding,
                  ),
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 480,
                    mainAxisExtent: 195,
                    crossAxisSpacing: 14,
                    mainAxisSpacing: 12,
                  ),
                  findChildIndexCallback: (Key key) {
                    if (key is ValueKey<String>) return idToIndex[key.value];
                    return null;
                  },
                  itemCount: renderItems.length,
                  itemBuilder: (context, index) {
                    final item = renderItems[index];
                    var card = _buildTaskCard(
                      item: item,
                      index: index,
                      compact: true,
                      showDragHandle: false,
                    );
                    if (!item.isPlaylist) {
                      card = _wrapSelectionMode(card, item, provider);
                    }
                    return RepaintBoundary(
                      child: _staggeredItem(context, index, card),
                    );
                  },
                ),
              );
            } else {
              contentWidget = KeyedSubtree(
                key: const ValueKey('list'),
                child: ListView.separated(
                  // ignore: deprecated_member_use
                  cacheExtent: 500.0,
                  padding: EdgeInsets.only(
                    left: horizontalPad,
                    right: horizontalPad,
                    bottom: bottomPadding,
                  ),
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  findItemIndexCallback: (Key key) {
                    if (key is ValueKey<String>) return idToIndex[key.value];
                    return null;
                  },
                  itemCount: renderItems.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: DmxTokens.cardGap),
                  itemBuilder: (context, index) {
                    final item = renderItems[index];
                    var card = _buildTaskCard(
                      item: item,
                      index: index,
                      compact: false,
                      showDragHandle: false,
                    );
                    if (!item.isPlaylist) {
                      card = _wrapSelectionMode(card, item, provider);
                    }
                    return RepaintBoundary(
                      child: _staggeredItem(context, index, card),
                    );
                  },
                ),
              );
            }
          }

          final Widget bodyWithReconcileIndicator = provider.isReconciling
              ? Column(
                  children: [
                    const SizedBox(
                      height: 3,
                      child: LinearProgressIndicator(
                        value: null,
                        backgroundColor: Colors.transparent,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(AppTheme.neonGreen),
                      ),
                    ),
                    Expanded(child: contentWidget),
                  ],
                )
              : contentWidget;

          return Directionality(
            textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
            child: bodyWithReconcileIndicator,
          );
        },
      );
    }

    final Widget animatedChild = AnimatedSwitcher(
      duration: AppTheme.motionBase,
      child: child,
    );

    if (selectedTab == 0) {
      final provider = context.read<DownloadProvider>();
      return RefreshIndicator(
        color: getActiveFilterColor(provider, isDark),
        backgroundColor: AppTheme.surfaceColor(isDark),
        strokeWidth: 2.5,
        onRefresh: () async {
          HapticFeedback.lightImpact();
          await context.read<DownloadProvider>().load(
                pauseOrphanDownloads: false,
              );
        },
        child: animatedChild,
      );
    }

    return animatedChild;
  }
}

class _HomeEmptyState extends StatelessWidget {
  final int selectedTab;
  final bool isDark;
  final bool isRtl;
  final VoidCallback? onClearSearch;
  final VoidCallback? onAddDownload;

  const _HomeEmptyState({
    super.key,
    required this.selectedTab,
    required this.isDark,
    required this.isRtl,
    this.onClearSearch,
    this.onAddDownload,
  });

  @override
  Widget build(BuildContext context) {
    final query =
        context.select<DownloadProvider, String>((p) => p.searchQuery);
    final accentClr =
        getActiveFilterColor(context.read<DownloadProvider>(), isDark);

    if (query.isNotEmpty) {
      return DmxEmptyState(
        icon: Icons.search_off_rounded,
        title: '${L10n.of(context, 'no_results_for')} "$query"',
        subtitle: isRtl
            ? 'جرّب مصطلح بحث مختلفاً أو امسح عوامل التصفية.'
            : 'Try a different keyword or clear your search filter.',
        buttonText: L10n.of(context, 'clear_search'),
        onButtonPressed: onClearSearch,
        accentColor: accentClr,
      );
    }

    final isHistory = selectedTab == 1;
    final icon =
        isHistory ? Icons.inventory_2_outlined : Icons.cloud_download_outlined;
    final title = isHistory
        ? L10n.of(context, 'history_empty')
        : L10n.of(context, 'empty_transmissions');
    final subtitle = isHistory
        ? (isRtl
            ? 'تظهر جميع التنزيلات المكتملة والفاشلة هنا.'
            : 'Finished and failed downloads will be cataloged here.')
        : (isRtl
            ? 'أدخل رابطاً لبدء التنزيل.'
            : 'Insert a URL to start downloading.');

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: AppTheme.motionReveal,
      curve: AppTheme.motionSpring,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 14 * (1 - value)),
            child: child,
          ),
        );
      },
      child: DmxEmptyState(
        icon: icon,
        title: title,
        subtitle: subtitle,
        buttonText:
            !isHistory ? (isRtl ? 'إضافة تنزيل' : 'Add Download') : null,
        onButtonPressed: !isHistory ? onAddDownload : null,
        accentColor: accentClr,
      ),
    );
  }
}
