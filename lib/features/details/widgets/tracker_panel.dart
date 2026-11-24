import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/torrent_service.dart';
import '../../../core/services/tracker_manager.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_design.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/widgets/dmx_bottom_sheet.dart';

class TrackerPanel extends StatefulWidget {
  final int torrentId;
  final TrackerManager trackerManager;

  const TrackerPanel({
    super.key,
    required this.torrentId,
    required this.trackerManager,
  });

  @override
  State<TrackerPanel> createState() => _TrackerPanelState();
}

class _TrackerPanelState extends State<TrackerPanel> {
  final TextEditingController _urlController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _showAddTrackerSheet(bool isDark) {
    _urlController.clear();
    final accent = AppTheme.accent(isDark);

    showDmxModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => DmxSheetContainer(
        isDark: isDark,
        accentColor: accent,
        scrollable: true,
        header: DmxSheetHeader(
          title: L10n.of(sheetCtx, 'add_tracker'),
          subtitle: 'Add an HTTP, HTTPS, or UDP announce URL',
          icon: Icons.dns_rounded,
          accentColor: accent,
          isDark: isDark,
        ),
        footer: DmxSheetActionBar(
          isDark: isDark,
          secondaryLabel: L10n.of(sheetCtx, 'cancel_btn'),
          onSecondary: () => Navigator.pop(sheetCtx),
          primaryLabel: L10n.of(sheetCtx, 'add_btn'),
          primaryIcon: Icons.add_rounded,
          primaryColor: accent,
          onPrimary: () {
            final added = widget.trackerManager.addTracker(
              widget.torrentId,
              _urlController.text,
            );
            Navigator.pop(sheetCtx);
            if (!added && mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(L10n.of(context, 'invalid_tracker_url')),
                ),
              );
            }
          },
        ),
        child: DmxSheetSection(
          title: 'TRACKER URL',
          isDark: isDark,
          child: DmxTextField(
            controller: _urlController,
            hintText: 'udp://tracker.opentrackr.org:1337/announce',
            autofocus: true,
          ),
        ),
      ),
    );
  }

  Color _statusColor(TrackerStatus status, bool isDark) {
    return switch (status) {
      TrackerStatus.working =>
        isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
      TrackerStatus.updating =>
        isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
      TrackerStatus.notWorking =>
        isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
      TrackerStatus.disabled => AppTheme.textMutedOf(isDark),
    };
  }

  String _statusLabel(TrackerStatus status) {
    return switch (status) {
      TrackerStatus.working => 'Working',
      TrackerStatus.updating => 'Updating',
      TrackerStatus.notWorking => 'Error',
      TrackerStatus.disabled => 'Disabled',
    };
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final textSecondary = AppTheme.textSecondaryOf(isDark);
    final textMuted = AppTheme.textMutedOf(isDark);
    final accent = AppTheme.accent(isDark);

    // The libtorrent 1.9.2 bridge exposes no tracker management symbols
    // (getTrackers/addTracker/removeTracker/announceNow are no-ops), so the
    // TrackerManager is a throwaway facade the swarm never sees. Rather than
    // present editable controls that silently do nothing, show an honest
    // "unavailable" state gated on the engine capability flag.
    if (!TorrentService.trackersSupported) {
      final isRtl = L10n.isRtl(context);
      return Container(
        padding: const EdgeInsets.all(DmxTokens.spaceLg),
        decoration: BoxDecoration(
          color: AppTheme.surfaceColor(isDark),
          borderRadius: BorderRadius.circular(DmxTokens.radiusLg),
          border: Border.all(
            color: AppTheme.hairlineBorder(isDark),
            width: DmxTokens.borderThin,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Trackers',
              style: TextStyle(
                fontFamily: AppTheme.fontDisplay,
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                color: textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 16, color: textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isRtl
                        ? 'إدارة المتتبعات غير متاحة في نسخة المحرك الحالية.'
                        : 'Tracker management is not available on this engine build.',
                    style: TextStyle(
                      fontFamily: AppTheme.fontBody,
                      color: textMuted,
                      fontSize: DmxTokens.textMd,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return ListenableBuilder(
      listenable: widget.trackerManager,
      builder: (context, _) {
        final trackers = widget.trackerManager.getTrackers(widget.torrentId);
        final workingCount =
            trackers.where((t) => t.status == TrackerStatus.working).length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header row with active/total count + compact action controls
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Trackers',
                      style: TextStyle(
                        fontFamily: AppTheme.fontDisplay,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        color: textPrimary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2.5,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: isDark ? 0.16 : 0.11),
                        borderRadius:
                            BorderRadius.circular(DmxTokens.radiusFull),
                      ),
                      child: Text(
                        trackers.isEmpty
                            ? '0'
                            : '$workingCount/${trackers.length}',
                        style: TextStyle(
                          fontFamily: AppTheme.fontDisplay,
                          fontSize: DmxTokens.textXs,
                          fontWeight: FontWeight.w700,
                          color: accent,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _HeaderIconBtn(
                      icon: Icons.flash_on_rounded,
                      tooltip: 'Add Default Trackers',
                      isDark: isDark,
                      onPressed: () => widget.trackerManager
                          .autoAddDefaultsIfSparse(widget.torrentId),
                    ),
                    const SizedBox(width: 6),
                    _HeaderIconBtn(
                      icon: Icons.refresh_rounded,
                      tooltip: L10n.of(context, 'announce_now'),
                      isDark: isDark,
                      onPressed: () =>
                          widget.trackerManager.reannounce(widget.torrentId),
                    ),
                    const SizedBox(width: 6),
                    Material(
                      color: accent,
                      borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
                      child: InkWell(
                        onTap: () => _showAddTrackerSheet(isDark),
                        borderRadius:
                            BorderRadius.circular(DmxTokens.radiusFull),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.add_rounded,
                                size: 15,
                                color: AppTheme.inkOn(accent),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                L10n.of(context, 'add_tracker'),
                                style: TextStyle(
                                  fontFamily: AppTheme.fontDisplay,
                                  fontSize: DmxTokens.textXs,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.inkOn(accent),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: DmxTokens.spaceMd),

            if (trackers.isEmpty)
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceColor(isDark),
                  borderRadius: BorderRadius.circular(DmxTokens.radiusLg),
                  border: Border.all(
                    color: AppTheme.hairlineBorder(isDark),
                    width: DmxTokens.borderThin,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.dns_outlined, size: 24, color: textMuted),
                    const SizedBox(height: 8),
                    Text(
                      'No trackers configured for this torrent.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: AppTheme.fontBody,
                        fontSize: DmxTokens.textSm,
                        color: textMuted,
                      ),
                    ),
                  ],
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: trackers.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(height: DmxTokens.spaceSm),
                itemBuilder: (context, index) {
                  final tracker = trackers[index];
                  final statusClr = _statusColor(tracker.status, isDark);
                  final healthPct =
                      (widget.trackerManager.trackerHealthScore(tracker) * 100)
                          .toInt();

                  return Dismissible(
                    key: ValueKey('${tracker.url}_$index'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      decoration: BoxDecoration(
                        color: (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed)
                            .withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                      ),
                      alignment: AlignmentDirectional.centerEnd,
                      padding: const EdgeInsetsDirectional.only(end: 16.0),
                      child: Icon(
                        Icons.delete_outline_rounded,
                        color:
                            isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                      ),
                    ),
                    onDismissed: (_) {
                      widget.trackerManager.removeTracker(
                        widget.torrentId,
                        tracker.url,
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.all(DmxTokens.spaceMd),
                      decoration: BoxDecoration(
                        color: AppTheme.surfaceColor(isDark),
                        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                        border: Border.all(
                          color: AppTheme.hairlineBorder(isDark),
                          width: DmxTokens.borderThin,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              // Status pill
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2.5,
                                ),
                                decoration: BoxDecoration(
                                  color: statusClr.withValues(
                                    alpha: isDark ? 0.14 : 0.10,
                                  ),
                                  borderRadius: BorderRadius.circular(
                                    DmxTokens.radiusFull,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        color: statusClr,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      _statusLabel(tracker.status),
                                      style: TextStyle(
                                        fontFamily: AppTheme.fontDisplay,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                        color: statusClr,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '$healthPct%',
                                style: TextStyle(
                                  fontFamily: AppTheme.fontDisplay,
                                  fontSize: DmxTokens.textXs,
                                  fontWeight: FontWeight.w600,
                                  color: textMuted,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                              const Spacer(),
                              // Copy URL button
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 32,
                                ),
                                padding: EdgeInsets.zero,
                                icon: Icon(
                                  Icons.copy_rounded,
                                  size: 15,
                                  color: textSecondary,
                                ),
                                tooltip: 'Copy Tracker URL',
                                onPressed: () async {
                                  await Clipboard.setData(
                                    ClipboardData(text: tracker.url),
                                  );
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Tracker URL copied'),
                                        duration: Duration(seconds: 1),
                                      ),
                                    );
                                  }
                                },
                              ),
                              // Remove button
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 32,
                                ),
                                padding: EdgeInsets.zero,
                                icon: Icon(
                                  Icons.close_rounded,
                                  size: 16,
                                  color: textMuted,
                                ),
                                tooltip: L10n.of(context, 'delete_btn'),
                                onPressed: () {
                                  widget.trackerManager.removeTracker(
                                    widget.torrentId,
                                    tracker.url,
                                  );
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            tracker.url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: DmxTokens.textSm,
                              fontWeight: FontWeight.w500,
                              color: textPrimary,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 10,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                'Seeds: ${tracker.seeds}',
                                style: TextStyle(
                                  fontFamily: AppTheme.fontDisplay,
                                  fontSize: DmxTokens.textXs,
                                  fontWeight: FontWeight.w600,
                                  color: isDark
                                      ? AppTheme.neonGreen
                                      : AppTheme.lightNeonGreen,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                              Text(
                                'Peers: ${tracker.peers}',
                                style: TextStyle(
                                  fontFamily: AppTheme.fontDisplay,
                                  fontSize: DmxTokens.textXs,
                                  fontWeight: FontWeight.w600,
                                  color: isDark
                                      ? AppTheme.neonBlue
                                      : AppTheme.lightNeonBlue,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                              if (tracker.message.isNotEmpty)
                                Text(
                                  tracker.message,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: AppTheme.fontBody,
                                    fontSize: DmxTokens.textXs,
                                    color: textMuted,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
          ],
        );
      },
    );
  }
}

class _HeaderIconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool isDark;
  final VoidCallback onPressed;

  const _HeaderIconBtn({
    required this.icon,
    required this.tooltip,
    required this.isDark,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppTheme.surfaceColor(isDark, elevated: true),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
          side: BorderSide(
            color: AppTheme.hairlineBorder(isDark),
            width: DmxTokens.borderThin,
          ),
        ),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
          child: SizedBox(
            width: 34,
            height: 34,
            child: Icon(
              icon,
              size: 16,
              color: AppTheme.textSecondaryOf(isDark),
            ),
          ),
        ),
      ),
    );
  }
}
