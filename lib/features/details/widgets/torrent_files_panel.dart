import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/domain/engine_types.dart';
import '../../../core/services/engine/torrent_file_normalizer.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_design.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/widgets/dmx_bottom_sheet.dart';
import '../../settings/provider/settings_provider.dart';

/// Renders a hierarchical list/tree of files within a torrent download,
/// displaying each file's type badge, selection state, priority pill,
/// progress bar, downloaded / total bytes, and truthful estimated indicators.
class TorrentFilesPanel extends StatefulWidget {
  final List<Map<String, dynamic>> torrentFiles;
  final bool? isDark;
  final bool? isRtl;
  final bool isDownloading;
  final CycleState? cycleState;
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
    this.cycleState,
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
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _collapsedFolders = <String>{};
  bool _isExpanded = true;
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _resolveIsAmoled(BuildContext context) {
    try {
      return context.watch<SettingsProvider>().isAmoledMode;
    } catch (_) {
      return SettingsProvider.instance.isAmoledMode;
    }
  }

  static int _getFileLength(Map<String, dynamic> f) {
    return (f['length'] as num?)?.toInt() ??
        (f['size'] as num?)?.toInt() ??
        (f['fileSize'] as num?)?.toInt() ??
        0;
  }

  static double _calcFileProgress(Map<String, dynamic> f) {
    if (!isTorrentFileSelected(f)) return 0.0;
    // Completion is only trustworthy against a known length; a stale entry
    // whose length was never resolved must not read as 100%.
    final lengthKnown = TorrentFileNormalizer.isLengthKnown(f);
    if ((f['isComplete'] as bool?) == true && lengthKnown) return 1.0;
    final isEstimated = (f['progressEstimated'] as bool?) == true;
    final length = _getFileLength(f);
    final downloadedBytes = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
    if (!isEstimated && length > 0 && downloadedBytes >= length) return 1.0;
    if (f['progress'] != null) {
      return ((f['progress'] as num).toDouble()).clamp(0.0, 1.0);
    } else if (length > 0 && downloadedBytes > 0) {
      return (downloadedBytes / length).clamp(0.0, 1.0);
    }
    return 0.0;
  }

  static bool _isFileComplete(Map<String, dynamic> f) {
    final selected = isTorrentFileSelected(f);
    if (!selected) return false;
    final lengthKnown = TorrentFileNormalizer.isLengthKnown(f);
    if (!lengthKnown) return false;
    final isEstimated = (f['progressEstimated'] as bool?) == true;
    final length = _getFileLength(f);
    final downloadedBytes = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
    return (f['isComplete'] as bool?) == true ||
        (!isEstimated && length > 0 && downloadedBytes >= length);
  }

  _FolderNode _buildTree(List<Map<String, dynamic>> files, String query) {
    final root = _FolderNode(name: '', path: '');
    final lowerQuery = query.trim().toLowerCase();

    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      final rawName = (f['name'] as String? ?? 'file_${i + 1}').trim();
      if (lowerQuery.isNotEmpty && !rawName.toLowerCase().contains(lowerQuery)) {
        continue;
      }

      final segments = rawName
          .split(RegExp(r'[/\\]+'))
          .where((s) => s.isNotEmpty)
          .toList();
      if (segments.isEmpty) {
        root.files.add(_IndexedTorrentFile(
          index: i,
          displayName: rawName,
          fullName: rawName,
          data: f,
        ));
        continue;
      }

      var current = root;
      for (var s = 0; s < segments.length - 1; s++) {
        final folderName = segments[s];
        final folderPath =
            current.path.isEmpty ? folderName : '${current.path}/$folderName';
        current = current.subfolders.putIfAbsent(
          folderName,
          () => _FolderNode(name: folderName, path: folderPath),
        );
      }

      current.files.add(_IndexedTorrentFile(
        index: i,
        displayName: segments.last,
        fullName: rawName,
        data: f,
      ));
    }

    return root;
  }

  void _collectFolderPaths(_FolderNode node, Set<String> out) {
    for (final child in node.subfolders.values) {
      out.add(child.path);
      _collectFolderPaths(child, out);
    }
  }

  void _collectFileIndices(_FolderNode node, List<int> out) {
    for (final f in node.files) {
      out.add(f.index);
    }
    for (final child in node.subfolders.values) {
      _collectFileIndices(child, out);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark =
        widget.isDark ?? (Theme.of(context).brightness == Brightness.dark);
    final isAmoled = _resolveIsAmoled(context);
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

    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final amberClr = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final textClr = AppTheme.textPrimaryOf(isDark);
    final secClr = AppTheme.textSecondaryOf(isDark);
    final mutedClr = AppTheme.textMutedOf(isDark);
    final hairline = AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);
    final panelBg = AppTheme.panelBg(isDark, isAmoled: isAmoled);

    // Loading metadata state when files haven't arrived yet
    if (widget.torrentFiles.isEmpty) {
      if (widget.isDownloading) {
        return DmxCardShell(
          showRail: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: blueClr.withValues(alpha: isDark ? 0.14 : 0.10),
                    borderRadius: BorderRadius.circular(DmxTokens.badgeRadius),
                    border: Border.all(
                      color: blueClr.withValues(alpha: 0.25),
                      width: 0.8,
                    ),
                  ),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: blueClr,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isRtl
                            ? 'جاري جلب ملفات وبيانات التورنت…'
                            : 'Waiting for torrent metadata…',
                        style: TextStyle(
                          fontFamily: AppTheme.fontDisplay,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: textClr,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isRtl
                            ? 'ستظهر قائمة الملفات فور استلام البيانات من الأقران'
                            : 'File list will appear automatically once peer metadata arrives',
                        style: TextStyle(
                          fontFamily: AppTheme.fontBody,
                          fontSize: 11.5,
                          color: mutedClr,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }
      return const SizedBox.shrink();
    }

    final files = widget.torrentFiles;
    final normalized = TorrentFileNormalizer.normalizeTorrentFileList(files);
    final selectedFiles = files.where(isTorrentFileSelected).toList();
    final completedCount = normalized.done;
    final denominator = selectedFiles.length == files.length
        ? files.length
        : selectedFiles.length;
    final allDone = denominator > 0 && completedCount >= denominator;
    final selectedBytes = selectedFiles.fold<int>(
      0,
      (sum, f) => sum + _getFileLength(f),
    );
    final totalBytes = files.fold<int>(0, (sum, f) => sum + _getFileLength(f));
    final summaryBytes = selectedBytes > 0 ? selectedBytes : totalBytes;

    final treeRoot = _buildTree(files, _searchQuery);
    final allFolderPaths = <String>{};
    _collectFolderPaths(treeRoot, allFolderPaths);
    final hasFolders = allFolderPaths.isNotEmpty;
    final allFoldersCollapsed =
        hasFolders && allFolderPaths.every(_collapsedFolders.contains);

    final treeWidgets = <Widget>[];
    _appendNodeWidgets(
      node: treeRoot,
      depth: 0,
      out: treeWidgets,
      isDark: isDark,
      isAmoled: isAmoled,
      isRtl: isRtl,
      blueClr: blueClr,
      greenClr: greenClr,
      amberClr: amberClr,
      redClr: redClr,
      textClr: textClr,
      secClr: secClr,
      mutedClr: mutedClr,
      hairline: hairline,
      panelBg: panelBg,
    );

    final badgeClr = allDone ? greenClr : blueClr;

    return DmxCardShell(
      showRail: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Collapsible Header
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => setState(() => _isExpanded = !_isExpanded),
                borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: blueClr.withValues(alpha: isDark ? 0.14 : 0.10),
                          borderRadius:
                              BorderRadius.circular(DmxTokens.badgeRadius),
                          border: Border.all(
                            color: blueClr.withValues(alpha: 0.24),
                            width: 0.8,
                          ),
                        ),
                        child: Icon(
                          Icons.folder_copy_outlined,
                          color: blueClr,
                          size: 17,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isRtl
                                  ? 'ملفات التورنت (${files.length})'
                                  : 'TORRENT FILES (${files.length})',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTheme.microLabel(
                                isDark: isDark,
                                size: 11,
                                color: textClr,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${selectedFiles.length}/${files.length} ${isRtl ? 'محدد' : 'selected'}${summaryBytes > 0 ? ' • ${formatBytes(summaryBytes)}' : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
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
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color:
                              badgeClr.withValues(alpha: isDark ? 0.14 : 0.10),
                          borderRadius:
                              BorderRadius.circular(DmxTokens.radiusFull),
                          border: Border.all(
                            color: badgeClr.withValues(alpha: 0.28),
                            width: 0.8,
                          ),
                        ),
                        child: Text(
                          '$completedCount/$denominator ${isRtl ? "مكتمل" : "done"}',
                          style: AppTheme.dataStyle(
                            isDark: isDark,
                            size: 11,
                            color: badgeClr,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      AnimatedRotation(
                        turns: _isExpanded ? 0.5 : 0.0,
                        duration: AppTheme.motionFast,
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: mutedClr,
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            if (_isExpanded) ...[
              const SizedBox(height: 12),

              // Search filter for multi-file torrents
              if (files.length > 3) ...[
                TextField(
                  controller: _searchController,
                  onChanged: (val) => setState(() => _searchQuery = val),
                  style: TextStyle(
                    fontFamily: AppTheme.fontBody,
                    color: textClr,
                    fontSize: 12.5,
                  ),
                  decoration: InputDecoration(
                    hintText: isRtl ? 'بحث في الملفات…' : 'Filter files…',
                    hintStyle: TextStyle(
                      fontFamily: AppTheme.fontBody,
                      color: mutedClr,
                      fontSize: 12.5,
                    ),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: 17,
                      color: mutedClr,
                    ),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: mutedClr,
                            ),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: panelBg,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                      borderSide: BorderSide(color: hairline, width: 0.8),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                      borderSide: BorderSide(color: hairline, width: 0.8),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                      borderSide: BorderSide(color: blueClr, width: 1.2),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],

              // Batch action pills (overflow-safe Wrap)
              if (widget.onSelectAll != null ||
                  widget.onDeselectAll != null ||
                  hasFolders) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    if (hasFolders)
                      _PanelActionButton(
                        label: allFoldersCollapsed
                            ? (isRtl ? 'توسيع المجلدات' : 'EXPAND ALL')
                            : (isRtl ? 'طي المجلدات' : 'COLLAPSE ALL'),
                        icon: allFoldersCollapsed
                            ? Icons.unfold_more_rounded
                            : Icons.unfold_less_rounded,
                        color: secClr,
                        isDark: isDark,
                        onPressed: () {
                          setState(() {
                            if (allFoldersCollapsed) {
                              _collapsedFolders.clear();
                            } else {
                              _collapsedFolders.addAll(allFolderPaths);
                            }
                          });
                        },
                      ),
                    if (widget.onSelectAll != null)
                      _PanelActionButton(
                        label: isRtl ? 'تحديد الكل' : 'SELECT ALL',
                        icon: Icons.select_all_rounded,
                        color: blueClr,
                        isDark: isDark,
                        onPressed: widget.onSelectAll!,
                      ),
                    if (widget.onDeselectAll != null)
                      _PanelActionButton(
                        label: isRtl ? 'إلغاء تحديد الكل' : 'DESELECT ALL',
                        icon: Icons.deselect_rounded,
                        color: redClr,
                        isDark: isDark,
                        onPressed: widget.onDeselectAll!,
                      ),
                  ],
                ),
                const SizedBox(height: 10),
              ],

              Divider(height: 1, thickness: 0.8, color: hairline),
              const SizedBox(height: 8),

              if (treeWidgets.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: Text(
                      isRtl
                          ? 'لا توجد ملفات تطابق البحث'
                          : 'No files match "$_searchQuery"',
                      style: TextStyle(
                        fontFamily: AppTheme.fontBody,
                        fontSize: 12,
                        color: mutedClr,
                      ),
                    ),
                  ),
                )
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: treeWidgets,
                ),
            ],
          ],
        ),
      ),
    );
  }

  void _appendNodeWidgets({
    required _FolderNode node,
    required int depth,
    required List<Widget> out,
    required bool isDark,
    required bool isAmoled,
    required bool isRtl,
    required Color blueClr,
    required Color greenClr,
    required Color amberClr,
    required Color redClr,
    required Color textClr,
    required Color secClr,
    required Color mutedClr,
    required Color hairline,
    required Color panelBg,
  }) {
    final sortedFolders = node.subfolders.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    for (final folder in sortedFolders) {
      final isCollapsed =
          _searchQuery.isEmpty && _collapsedFolders.contains(folder.path);
      out.add(_buildFolderRow(
        folder: folder,
        depth: depth,
        isCollapsed: isCollapsed,
        isDark: isDark,
        isRtl: isRtl,
        blueClr: blueClr,
        greenClr: greenClr,
        textClr: textClr,
        mutedClr: mutedClr,
        hairline: hairline,
        panelBg: panelBg,
      ));
      if (!isCollapsed) {
        _appendNodeWidgets(
          node: folder,
          depth: depth + 1,
          out: out,
          isDark: isDark,
          isAmoled: isAmoled,
          isRtl: isRtl,
          blueClr: blueClr,
          greenClr: greenClr,
          amberClr: amberClr,
          redClr: redClr,
          textClr: textClr,
          secClr: secClr,
          mutedClr: mutedClr,
          hairline: hairline,
          panelBg: panelBg,
        );
      }
    }

    for (var i = 0; i < node.files.length; i++) {
      final entry = node.files[i];
      out.add(_buildFileRow(
        entry: entry,
        depth: depth,
        isDark: isDark,
        isAmoled: isAmoled,
        isRtl: isRtl,
        blueClr: blueClr,
        greenClr: greenClr,
        amberClr: amberClr,
        redClr: redClr,
        textClr: textClr,
        mutedClr: mutedClr,
        hairline: hairline,
      ));
    }
  }

  Widget _buildFolderRow({
    required _FolderNode folder,
    required int depth,
    required bool isCollapsed,
    required bool isDark,
    required bool isRtl,
    required Color blueClr,
    required Color greenClr,
    required Color textClr,
    required Color mutedClr,
    required Color hairline,
    required Color panelBg,
  }) {
    final indices = <int>[];
    _collectFileIndices(folder, indices);
    final totalCount = indices.length;
    var selectedCount = 0;
    var totalLen = 0;
    var downloadedLen = 0;
    var allKnownComplete = totalCount > 0;

    for (final idx in indices) {
      final f = widget.torrentFiles[idx];
      final sel = isTorrentFileSelected(f);
      if (sel) {
        selectedCount++;
        final len = _getFileLength(f);
        totalLen += len;
        final complete = _isFileComplete(f);
        if (!complete) allKnownComplete = false;
        final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
        downloadedLen += complete && len > 0 ? len : dl;
      }
    }

    final bool? checkboxVal = selectedCount == 0
        ? false
        : (selectedCount == totalCount ? true : null);
    final double folderProgress = totalLen > 0
        ? (downloadedLen / totalLen).clamp(0.0, 1.0)
        : (allKnownComplete && selectedCount > 0 ? 1.0 : 0.0);
    final indent = (depth * 14.0).clamp(0.0, 42.0);

    return Padding(
      padding: EdgeInsetsDirectional.only(start: indent, bottom: 6),
      child: Material(
        color: panelBg,
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            setState(() {
              if (_collapsedFolders.contains(folder.path)) {
                _collapsedFolders.remove(folder.path);
              } else {
                _collapsedFolders.add(folder.path);
              }
            });
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
              border: Border.all(color: hairline, width: 0.8),
            ),
            child: Row(
              children: [
                if (widget.onFileToggle != null) ...[
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: Checkbox(
                      tristate: true,
                      value: checkboxVal,
                      activeColor: blueClr,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      side: BorderSide(color: hairline, width: 1.2),
                      onChanged: (_) {
                        final targetSelected = selectedCount < totalCount;
                        for (final idx in indices) {
                          widget.onFileToggle!(idx, targetSelected);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Icon(
                  isCollapsed
                      ? Icons.folder_rounded
                      : Icons.folder_open_rounded,
                  size: 17,
                  color: blueClr,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        folder.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: AppTheme.fontDisplay,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: textClr,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$totalCount ${isRtl ? 'ملف' : (totalCount == 1 ? 'file' : 'files')}${totalLen > 0 ? ' • ${formatBytes(totalLen)}' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                const SizedBox(width: 8),
                Text(
                  '${(folderProgress * 100).toStringAsFixed(0)}%',
                  style: AppTheme.dataStyle(
                    isDark: isDark,
                    size: 11,
                    color: allKnownComplete && selectedCount > 0
                        ? greenClr
                        : mutedClr,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  isCollapsed
                      ? Icons.chevron_right_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: mutedClr,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFileRow({
    required _IndexedTorrentFile entry,
    required int depth,
    required bool isDark,
    required bool isAmoled,
    required bool isRtl,
    required Color blueClr,
    required Color greenClr,
    required Color amberClr,
    required Color redClr,
    required Color textClr,
    required Color mutedClr,
    required Color hairline,
  }) {
    final index = entry.index;
    final f = entry.data;
    final name = entry.fullName;
    final displayName = entry.displayName;
    final length = _getFileLength(f);
    final lengthKnown = TorrentFileNormalizer.isLengthKnown(f);
    final downloadedBytes = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
    final selected = (f['selected'] as bool?) ?? true;
    final isEstimated = (f['progressEstimated'] as bool?) == true;
    final progress = _calcFileProgress(f);
    final isComplete = _isFileComplete(f);

    final displayDownloadedBytes =
        !selected ? 0 : (isComplete && length > 0 ? length : downloadedBytes);
    final progressPercent = (isComplete ? 1.0 : progress) * 100.0;
    final progressText = !selected
        ? (isRtl ? 'تم التخطي' : 'Skipped')
        : (isComplete
            ? '100.0%'
            : (isEstimated
                ? '≈${progressPercent.toStringAsFixed(0)}%'
                : '${progressPercent.toStringAsFixed(1)}%'));

    final typeVisual = _fileTypeVisual(displayName, isDark);
    final iconColor =
        isComplete ? greenClr : (selected ? typeVisual.color : mutedClr);
    final iconData = isComplete
        ? Icons.check_circle_rounded
        : (selected ? typeVisual.icon : Icons.block_rounded);
    final indent = (depth * 14.0).clamp(0.0, 42.0);
    final rowSurface =
        AppTheme.surfaceColor(isDark, isAmoled: isAmoled, elevated: false);

    return RepaintBoundary(
      key: ValueKey('$name:$downloadedBytes:$selected'),
      child: Padding(
        padding: EdgeInsetsDirectional.only(start: indent, bottom: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? rowSurface : rowSurface.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
            border: Border.all(
              color: isComplete
                  ? greenClr.withValues(alpha: isDark ? 0.26 : 0.22)
                  : hairline,
              width: 0.8,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.onFileToggle != null) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: Checkbox(
                      value: selected,
                      activeColor: blueClr,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      side: BorderSide(color: hairline, width: 1.2),
                      onChanged: (val) {
                        if (val != null) {
                          widget.onFileToggle!(index, val);
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: isDark ? 0.14 : 0.10),
                  borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
                ),
                child: Icon(iconData, size: 16, color: iconColor),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            displayName,
                            style: TextStyle(
                              fontFamily: AppTheme.fontDisplay,
                              color: selected ? textClr : mutedClr,
                              fontSize: 12.5,
                              fontWeight:
                                  selected ? FontWeight.w600 : FontWeight.w400,
                              decoration:
                                  selected ? null : TextDecoration.lineThrough,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (widget.onPriorityChanged != null && selected) ...[
                          const SizedBox(width: 6),
                          _PriorityBadge(
                            priority: (f['priority'] as int?) ?? 4,
                            isDark: isDark,
                            isRtl: isRtl,
                            isCompleted: isComplete,
                            fileName: displayName,
                            onChanged: (newPriority) =>
                                widget.onPriorityChanged!(index, newPriority),
                            onSkip: widget.onFileToggle != null
                                ? () => widget.onFileToggle!(index, false)
                                : null,
                          ),
                        ],
                        if (widget.onDeleteFile != null) ...[
                          const SizedBox(width: 4),
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () => widget.onDeleteFile!(index, name),
                              borderRadius: BorderRadius.circular(6),
                              child: Padding(
                                padding: const EdgeInsets.all(3),
                                child: Icon(
                                  Icons.delete_outline_rounded,
                                  size: 16,
                                  color: redClr,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),

                    if (widget.cycleState == CycleState.verifying ||
                        isEstimated) ...[
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          if (widget.cycleState == CycleState.verifying)
                            _StatusPill(
                              label: isRtl ? 'إعادة الفحص' : 'Re-checking',
                              color: amberClr,
                              isDark: isDark,
                            ),
                          if (isEstimated)
                            _StatusPill(
                              label: isRtl ? 'تقديري' : 'ESTIMATED',
                              icon: Icons.auto_awesome_outlined,
                              color: amberClr,
                              isDark: isDark,
                            ),
                        ],
                      ),
                    ],

                    const SizedBox(height: 7),

                    if (selected) ...[
                      // Sleek inline progress bar
                      Stack(
                        children: [
                          Container(
                            height: 4,
                            width: double.infinity,
                            decoration: AppTheme.progressTrack(isDark: isDark),
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
                        children: [
                          Expanded(
                            child: Text(
                              '${formatBytes(displayDownloadedBytes)} / ${lengthKnown ? formatBytes(length) : '—'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTheme.dataStyle(
                                isDark: isDark,
                                size: 11,
                                weight: FontWeight.w500,
                                color: mutedClr,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            progressText,
                            style: AppTheme.dataStyle(
                              isDark: isDark,
                              size: 11,
                              color: isComplete
                                  ? greenClr
                                  : (isEstimated
                                      ? textClr.withValues(alpha: 0.65)
                                      : textClr),
                            ),
                          ),
                        ],
                      ),
                    ] else
                      Text(
                        isRtl ? 'تم تخطيه' : 'Skipped',
                        style: TextStyle(
                          fontFamily: AppTheme.fontBody,
                          color: mutedClr,
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  _FileTypeVisual _fileTypeVisual(String fileName, bool isDark) {
    final lower = fileName.toLowerCase();
    final dot = lower.lastIndexOf('.');
    final ext = dot != -1 ? lower.substring(dot + 1) : '';
    switch (ext) {
      case 'mp4':
      case 'mkv':
      case 'avi':
      case 'mov':
      case 'webm':
      case 'wmv':
        return _FileTypeVisual(
          Icons.movie_outlined,
          isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
        );
      case 'mp3':
      case 'flac':
      case 'wav':
      case 'm4a':
      case 'aac':
      case 'ogg':
        return _FileTypeVisual(
          Icons.audiotrack_outlined,
          isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
        );
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
      case 'iso':
        return _FileTypeVisual(
          Icons.folder_zip_outlined,
          isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
        );
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'webp':
      case 'svg':
        return _FileTypeVisual(
          Icons.image_outlined,
          isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan,
        );
      case 'srt':
      case 'ass':
      case 'vtt':
      case 'sub':
        return _FileTypeVisual(
          Icons.subtitles_outlined,
          isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
        );
      case 'pdf':
      case 'txt':
      case 'md':
      case 'doc':
      case 'docx':
      case 'nfo':
        return _FileTypeVisual(
          Icons.description_outlined,
          isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan,
        );
      default:
        return _FileTypeVisual(
          Icons.insert_drive_file_outlined,
          AppTheme.textSecondaryOf(isDark),
        );
    }
  }
}

class _FolderNode {
  final String name;
  final String path;
  final Map<String, _FolderNode> subfolders = <String, _FolderNode>{};
  final List<_IndexedTorrentFile> files = <_IndexedTorrentFile>[];

  _FolderNode({required this.name, required this.path});
}

class _IndexedTorrentFile {
  final int index;
  final String displayName;
  final String fullName;
  final Map<String, dynamic> data;

  const _IndexedTorrentFile({
    required this.index,
    required this.displayName,
    required this.fullName,
    required this.data,
  });
}

class _FileTypeVisual {
  final IconData icon;
  final Color color;

  const _FileTypeVisual(this.icon, this.color);
}

class _StatusPill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color color;
  final bool isDark;

  const _StatusPill({
    required this.label,
    this.icon,
    required this.color,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.14 : 0.10),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 10, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              fontFamily: AppTheme.fontDisplay,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: color,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool isDark;
  final VoidCallback onPressed;

  const _PanelActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.isDark,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: isDark ? 0.12 : 0.08),
            borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
            border:
                Border.all(color: color.withValues(alpha: 0.28), width: 0.8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontFamily: AppTheme.fontDisplay,
                  color: color,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
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
  final String fileName;
  final ValueChanged<int> onChanged;
  final VoidCallback? onSkip;

  const _PriorityBadge({
    required this.priority,
    required this.isDark,
    required this.isRtl,
    required this.isCompleted,
    required this.fileName,
    required this.onChanged,
    this.onSkip,
  });

  Future<void> _openPrioritySheet(BuildContext context) async {
    final red = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final blue = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final violet = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final muted = AppTheme.textMutedOf(isDark);

    final options = [
      (
        value: 7,
        label: isRtl ? 'أولوية عالية' : 'High Priority',
        desc: isRtl
            ? 'تحميل هذا الملف أولاً بأسرع ما يمكن'
            : 'Download pieces for this file first',
        color: red,
        icon: Icons.keyboard_double_arrow_up_rounded,
      ),
      (
        value: 4,
        label: isRtl ? 'أولوية عادية' : 'Normal Priority',
        desc: isRtl
            ? 'توزيع متوازن مع بقية الملفات'
            : 'Balanced piece scheduling with other files',
        color: blue,
        icon: Icons.drag_handle_rounded,
      ),
      (
        value: 1,
        label: isRtl ? 'أولوية منخفضة' : 'Low Priority',
        desc: isRtl
            ? 'تحميل بعد الملفات الأعلى أولوية'
            : 'Download after higher-priority files',
        color: violet,
        icon: Icons.keyboard_arrow_down_rounded,
      ),
    ];

    await showDmxModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => DmxSheetContainer(
        scrollable: true,
        isDark: isDark,
        accentColor: blue,
        header: DmxSheetHeader(
          title: isRtl ? 'أولوية الملف' : 'File Priority',
          subtitle: fileName,
          icon: Icons.low_priority_rounded,
          accentColor: blue,
          isDark: isDark,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DmxSheetSection(
              isDark: isDark,
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  for (var i = 0; i < options.length; i++) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        thickness: 0.8,
                        color: AppTheme.hairlineBorder(isDark),
                      ),
                    _buildSheetOption(
                      context: sheetCtx,
                      label: options[i].label,
                      desc: options[i].desc,
                      icon: options[i].icon,
                      color: options[i].color,
                      selected: priority == options[i].value,
                      onTap: () {
                        Navigator.of(sheetCtx).pop();
                        onChanged(options[i].value);
                      },
                    ),
                  ],
                  if (onSkip != null) ...[
                    Divider(
                      height: 1,
                      thickness: 0.8,
                      color: AppTheme.hairlineBorder(isDark),
                    ),
                    _buildSheetOption(
                      context: sheetCtx,
                      label: isRtl ? 'تخطي الملف' : 'Skip File',
                      desc: isRtl
                          ? 'عدم تحميل هذا الملف'
                          : 'Do not download this file',
                      icon: Icons.block_rounded,
                      color: muted,
                      selected: false,
                      onTap: () {
                        Navigator.of(sheetCtx).pop();
                        onSkip!();
                      },
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSheetOption({
    required BuildContext context,
    required String label,
    required String desc,
    required IconData icon,
    required Color color,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final textClr = AppTheme.textPrimaryOf(isDark);
    final secClr = AppTheme.textSecondaryOf(isDark);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: isDark ? 0.14 : 0.10),
                  borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
                ),
                child: Icon(icon, size: 17, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontFamily: AppTheme.fontDisplay,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: selected ? color : textClr,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      desc,
                      style: TextStyle(
                        fontFamily: AppTheme.fontBody,
                        fontSize: 11.5,
                        color: secClr,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded, size: 19, color: color),
            ],
          ),
        ),
      ),
    );
  }

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

    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: priorityColor.withValues(alpha: isDark ? 0.12 : 0.08),
        borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
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
              fontFamily: AppTheme.fontDisplay,
              color: priorityColor,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (!isCompleted) ...[
            const SizedBox(width: 2),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 13,
              color: priorityColor,
            ),
          ],
        ],
      ),
    );

    if (isCompleted) return pill;

    return Tooltip(
      message: isRtl ? 'تحديد الأولوية' : 'Set priority',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openPrioritySheet(context),
          borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
          child: pill,
        ),
      ),
    );
  }
}
