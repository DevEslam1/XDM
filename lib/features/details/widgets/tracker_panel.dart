import 'package:flutter/material.dart';
import '../../../core/app_theme.dart';
import '../../../core/services/torrent_models.dart';
import '../../../core/services/tracker_manager.dart';
import '../../../core/utils/localization.dart';

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

  void _showAddTrackerDialog() {
    _urlController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.of(ctx, 'add_tracker')),
        content: TextField(
          controller: _urlController,
          decoration: const InputDecoration(
            hintText: 'udp://tracker.opentrackr.org:1337/announce',
            labelText: 'Tracker URL',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(L10n.of(ctx, 'cancel_btn')),
          ),
          ElevatedButton(
            onPressed: () {
              final added = widget.trackerManager.addTracker(
                widget.torrentId,
                _urlController.text,
              );
              Navigator.pop(ctx);
              if (!added && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text(L10n.of(context, 'invalid_tracker_url'))),
                );
              }
            },
            child: Text(L10n.of(ctx, 'add_btn')),
          ),
        ],
      ),
    );
  }

  Color _statusColor(TrackerStatus status) {
    return switch (status) {
      TrackerStatus.working => AppTheme.neonGreen,
      TrackerStatus.updating => AppTheme.neonAmber,
      TrackerStatus.notWorking => AppTheme.neonRed,
      TrackerStatus.disabled => AppTheme.textMuted,
    };
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.trackerManager,
      builder: (context, _) {
        final trackers = widget.trackerManager.getTrackers(widget.torrentId);

        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Trackers (${trackers.length})',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.refresh),
                        tooltip: L10n.of(context, 'announce_now'),
                        onPressed: () =>
                            widget.trackerManager.reannounce(widget.torrentId),
                      ),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.add, size: 16),
                        label: Text(L10n.of(context, 'add_tracker')),
                        onPressed: _showAddTrackerDialog,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (trackers.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24.0),
                  child: Center(
                    child: Text(
                      'No trackers configured for this torrent.',
                      style: TextStyle(color: AppTheme.textMuted),
                    ),
                  ),
                )
              else
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: trackers.length,
                  itemBuilder: (context, index) {
                    final tracker = trackers[index];
                    return Dismissible(
                      key: ValueKey('${tracker.url}_$index'),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Colors.red,
                        alignment: AlignmentDirectional.centerEnd,
                        padding: const EdgeInsetsDirectional.only(end: 16.0),
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      onDismissed: (_) {
                        widget.trackerManager.removeTracker(
                          widget.torrentId,
                          tracker.url,
                        );
                      },
                      child: ListTile(
                        leading: CircleAvatar(
                          radius: 6,
                          backgroundColor: _statusColor(tracker.status),
                        ),
                        title: Text(
                          tracker.url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          'Seeds: ${tracker.seeds} | Peers: ${tracker.peers} ${tracker.message.isNotEmpty ? '• ${tracker.message}' : ''}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () {
                            widget.trackerManager.removeTracker(
                              widget.torrentId,
                              tracker.url,
                            );
                          },
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}
