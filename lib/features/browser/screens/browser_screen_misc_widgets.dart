part of 'browser_screen.dart';

class _YouTubeGrabButton extends StatelessWidget {
  final bool isPlaylist;
  final bool isRtl;
  final bool isDark;
  final bool enableGlow;
  final VoidCallback onPressed;
  const _YouTubeGrabButton(
      {required this.isPlaylist,
      required this.isRtl,
      required this.isDark,
      required this.enableGlow,
      required this.onPressed});
  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.2),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.red, width: 1.2),
          boxShadow: enableGlow
              ? [
                  BoxShadow(
                      color: Colors.red.withValues(alpha: 0.4),
                      blurRadius: 6,
                      spreadRadius: 0.5)
                ]
              : null,
        ),
        child: Icon(
            isPlaylist ? Icons.playlist_play_rounded : Icons.download_rounded,
            size: 16,
            color: Colors.white),
      ),
      tooltip: isPlaylist
          ? (isRtl ? 'تحميل قائمة التشغيل' : 'Download Playlist')
          : (isRtl ? 'تحميل الفيديو' : 'Download Video'),
      onPressed: onPressed,
    );
  }
}

class _TabSwitcherAction extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;
  const _TabSwitcherAction(
      {required this.icon,
      required this.color,
      required this.tooltip,
      required this.onPressed});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onPressed,
        child: Tooltip(
          message: tooltip,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border:
                  Border.all(color: color.withValues(alpha: 0.25), width: 0.7),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
        ),
      ),
    );
  }
}

class _JsCssInjectorDialog extends StatefulWidget {
  final String initialJs;
  final String initialCss;
  final Function(String, String) onSave;
  const _JsCssInjectorDialog(
      {required this.initialJs,
      required this.initialCss,
      required this.onSave});
  @override
  State<_JsCssInjectorDialog> createState() => _JsCssInjectorDialogState();
}

class _JsCssInjectorDialogState extends State<_JsCssInjectorDialog> {
  late final TextEditingController _jsController;
  late final TextEditingController _cssController;
  int _activeTab = 0;

  @override
  void initState() {
    super.initState();
    _jsController = TextEditingController(text: widget.initialJs);
    _cssController = TextEditingController(text: widget.initialCss);
  }

  @override
  void dispose() {
    _jsController.dispose();
    _cssController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return AlertDialog(
      backgroundColor: (isDark ? AppTheme.surface : AppTheme.lightSurface)
          .withValues(alpha: 0.95),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Row(
        children: [
          Icon(Icons.code_rounded, color: accent, size: 20),
          const SizedBox(width: 10),
          Text(L10n.of(context, 'browser_js_css_injector'),
              style: TextStyle(
                  color: accent,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0)),
        ],
      ),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.85,
        height: 280,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed)
                        .withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                      size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      L10n.of(context, 'browser_js_css_warning'),
                      style: TextStyle(
                          color:
                              isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                          fontSize: 10,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _tabHeader(0, 'JavaScript')),
              Expanded(child: _tabHeader(1, 'CSS Style'))
            ]),
            const SizedBox(height: 12),
            Expanded(
              child: IndexedStack(
                index: _activeTab,
                children: [
                  _buildCodeEditor(
                      _jsController,
                      '// Write your Custom Javascript here\n// Automatically runs on page loads...',
                      isDark),
                  _buildCodeEditor(
                      _cssController,
                      '/* Write your Custom CSS here */\nbody {\n  /* background-color: #000; */\n}',
                      isDark),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(L10n.of(context, 'cancel_btn_uppercase'))),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: accent, foregroundColor: Colors.black),
          onPressed: () {
            widget.onSave(_jsController.text, _cssController.text);
            Navigator.pop(context);
          },
          child: Text(L10n.of(context, 'browser_apply_uppercase')),
        ),
      ],
    );
  }

  Widget _tabHeader(int index, String label) {
    final isSelected = _activeTab == index;
    final settings = Provider.of<SettingsProvider>(context);
    final accent =
        settings.isDarkMode ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    return GestureDetector(
      onTap: () {
        runHaptic(settings);
        setState(() {
          _activeTab = index;
        });
      },
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
            border: Border(
                bottom: BorderSide(
                    color: isSelected ? accent : Colors.transparent,
                    width: 2))),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected
                ? accent
                : (settings.isDarkMode
                    ? AppTheme.textSecondary
                    : AppTheme.lightTextSecondary),
            fontWeight: FontWeight.bold,
            fontSize: 12,
            fontFamily: 'Space Grotesk',
          ),
        ),
      ),
    );
  }

  Widget _buildCodeEditor(
      TextEditingController controller, String hint, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: (isDark ? AppTheme.background : AppTheme.lightBackground)
            .withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
            width: 0.8),
      ),
      child: TextField(
        controller: controller,
        maxLines: null,
        expands: true,
        keyboardType: TextInputType.multiline,
        style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
              color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
              fontSize: 10),
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }
}

/// UX 3.5: A tab that was closed during the current session, eligible for
/// restore from the "Recently closed tabs" sheet.
class _ZoomPresetButton extends StatelessWidget {
  final String label;
  final int value;
  final VoidCallback onTap;
  const _ZoomPresetButton({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(48, 32),
        backgroundColor: AppTheme.neonBlue.withValues(alpha: 0.08),
        foregroundColor: AppTheme.neonBlue,
      ),
      onPressed: onTap,
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}
