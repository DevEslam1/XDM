import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A bottom sheet that displays potential redirect targets extracted from
/// an ad-bridge or shortener page. Allows the user to open, copy, or dismiss.
class RedirectSheet extends StatelessWidget {
  final List<String> candidates;
  final ValueChanged<String> onSelected;

  const RedirectSheet({
    super.key,
    required this.candidates,
    required this.onSelected,
  });

  /// Helper to show the sheet cleanly.
  static Future<void> show(
    BuildContext context, {
    required List<String> candidates,
    required ValueChanged<String> onSelected,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RedirectSheet(
        candidates: candidates,
        onSelected: onSelected,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Row(
                children: [
                  Icon(Icons.shield_moon_outlined, color: colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Redirect Detected',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'This page appears to be an ad bridge. Select the real destination:',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Candidates List
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: candidates.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, indent: 16),
                itemBuilder: (context, index) {
                  final url = candidates[index];
                  return _RedirectCandidateTile(
                    url: url,
                    onTap: () {
                      Navigator.of(context).pop();
                      onSelected(url);
                    },
                  );
                },
              ),
            ),
            const Divider(height: 1),
            // Footer Actions
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Stay on page'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RedirectCandidateTile extends StatelessWidget {
  final String url;
  final VoidCallback onTap;

  const _RedirectCandidateTile({required this.url, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final uri = Uri.tryParse(url);
    final isSecure = uri?.scheme == 'https';

    // Extract domain and path for cleaner display
    final host = uri?.host ?? 'Unknown Host';
    final path = uri?.path ?? '';
    final query = uri?.query ?? '';

    // Detect if it's a direct file link
    final isDirectFile = RegExp(
      r'\.(mp4|mkv|mp3|zip|rar|7z|apk|exe|dmg|iso|m4a|pdf|epub)(\?|$)',
      caseSensitive: false,
    ).hasMatch(path);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Favicon / Icon
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: isDirectFile
                  ? Icon(Icons.download_rounded,
                      color: theme.colorScheme.primary)
                  : Icon(Icons.language_rounded,
                      color: theme.colorScheme.secondary),
            ),
            const SizedBox(width: 16),
            // Text Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          host,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (isSecure)
                        Icon(Icons.lock_outline,
                            size: 12,
                            color: theme.brightness == Brightness.dark
                                ? Colors.green[300]
                                : Colors.green[600]),
                      if (isDirectFile) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.brightness == Brightness.dark
                                ? Colors.green[900]!.withValues(alpha: 0.6)
                                : Colors.green[100],
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'FILE',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: theme.brightness == Brightness.dark
                                  ? Colors.green[300]
                                  : Colors.green[800],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    path.isEmpty && query.isEmpty
                        ? '/'
                        : '$path${query.isNotEmpty ? '?$query' : ''}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Copy Button
            IconButton(
              icon: const Icon(Icons.copy_outlined, size: 20),
              visualDensity: VisualDensity.compact,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: url));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Link copied to clipboard'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
