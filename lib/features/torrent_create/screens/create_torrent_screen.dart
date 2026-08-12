import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import '../../../core/app_theme.dart';
import '../../../core/services/torrent_service.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../settings/provider/settings_provider.dart';

class CreateTorrentScreen extends StatefulWidget {
  const CreateTorrentScreen({super.key});

  @override
  State<CreateTorrentScreen> createState() => _CreateTorrentScreenState();
}

class _CreateTorrentScreenState extends State<CreateTorrentScreen> {
  final TextEditingController _sourceController = TextEditingController();
  final TextEditingController _outputController = TextEditingController();
  final TextEditingController _commentController = TextEditingController();
  final TextEditingController _trackerInputController = TextEditingController();

  final List<String> _trackers = [
    'udp://tracker.opentrackr.org:1337/announce',
    'udp://open.stealth.si:80/announce',
  ];

  bool _isPrivate = false;
  final int _pieceSize = 0; // 0 = auto
  bool _isCreating = false;

  @override
  void dispose() {
    _sourceController.dispose();
    _outputController.dispose();
    _commentController.dispose();
    _trackerInputController.dispose();
    super.dispose();
  }

  Future<void> _pickSourceFile() async {
    final result = await FilePicker.pickFiles();
    if (result != null && result.files.single.path != null) {
      setState(() {
        _sourceController.text = result.files.single.path!;
        if (_outputController.text.isEmpty) {
          _outputController.text = '${result.files.single.path!}.torrent';
        }
      });
    }
  }

  Future<void> _pickSourceFolder() async {
    final result = await FilePicker.getDirectoryPath();
    if (result != null) {
      setState(() {
        _sourceController.text = result;
        if (_outputController.text.isEmpty) {
          _outputController.text = '$result.torrent';
        }
      });
    }
  }

  Future<void> _pickOutputDirectory() async {
    final result = await FilePicker.getDirectoryPath();
    if (result != null) {
      final sourcePath = _sourceController.text.trim();
      String baseName = 'download';
      if (sourcePath.isNotEmpty) {
        baseName = p.basename(sourcePath);
      }
      setState(() {
        _outputController.text = p.join(result, '$baseName.torrent');
      });
    }
  }

  void _addTracker() {
    final text = _trackerInputController.text.trim();
    if (text.isNotEmpty && !_trackers.contains(text)) {
      setState(() {
        _trackers.add(text);
        _trackerInputController.clear();
      });
    }
  }

  Future<void> _handleCreate() async {
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);

    final source = _sourceController.text.trim();
    var output = _outputController.text.trim();

    if (source.isEmpty) {
      ThemedSnackbar.show(
        context,
        message: isRtl
            ? 'يرجى تحديد ملف أو مجلد مصدر'
            : 'Please select a source file or folder',
        color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
        icon: Icons.error_outline,
        isDarkMode: isDark,
      );
      return;
    }
    if (output.isEmpty) {
      output = '$source.torrent';
    }

    setState(() => _isCreating = true);

    try {
      final res = await TorrentService.createTorrent(
        sourcePath: source,
        outputPath: output,
        trackers: _trackers,
        comment: _commentController.text.trim(),
        pieceSize: _pieceSize,
        isPrivate: _isPrivate,
      );

      if (!mounted) return;

      // FIX: Safely check file existence to avoid FileSystemException crashes
      bool fileExists = false;
      try {
        fileExists = File(output).existsSync();
      } catch (_) {
        // Ignore stat errors, rely on `res`
      }

      if (res != null || fileExists) {
        ThemedSnackbar.show(
          context,
          message: isRtl
              ? 'تم إنشاء ملف التورنت بنجاح!'
              : 'Torrent file created successfully!',
          color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
          icon: Icons.check_circle_outline,
          isDarkMode: isDark,
        );
        Navigator.pop(context, output);
      } else {
        ThemedSnackbar.show(
          context,
          message: isRtl
              ? 'أرجع إنشاء التورنت نتيجة فارغة'
              : 'Torrent creation returned empty result',
          color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
          icon: Icons.warning_amber_rounded,
          isDarkMode: isDark,
        );
      }
    } catch (e) {
      if (!mounted) return;
      ThemedSnackbar.show(
        context,
        message: isRtl ? 'فشل الإنشاء: $e' : 'Creation failed: $e',
        color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
        icon: Icons.error_outline,
        isDarkMode: isDark,
      );
    } finally {
      if (mounted) {
        setState(() => _isCreating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final borderClr = isDark ? AppTheme.border : AppTheme.lightBorder;
    final panelBg = isDark ? AppTheme.surface : AppTheme.lightSurface;
    final accentClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isRtl ? 'إنشاء ملف تورنت' : 'Create Torrent',
          style: TextStyle(color: textClr, fontWeight: FontWeight.bold),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SectionLabel(
              text: isRtl ? 'مسار المصدر' : 'Source Path',
              color: textClr,
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _sourceController,
                    style: TextStyle(
                        color: textClr, fontSize: 12, fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      hintText: isRtl
                          ? 'اختر ملفاً أو مجلداً...'
                          : 'Select file or folder...',
                      hintStyle: TextStyle(color: mutedClr, fontSize: 12),
                      filled: true,
                      fillColor: panelBg,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: borderClr, width: 0.8),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: borderClr, width: 0.8),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                            color: accentClr.withValues(alpha: 0.5),
                            width: 1.2),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.insert_drive_file, color: accentClr),
                  onPressed: _pickSourceFile,
                  tooltip: isRtl ? 'اختيار ملف' : 'Pick File',
                ),
                IconButton(
                  icon: Icon(Icons.folder, color: accentClr),
                  onPressed: _pickSourceFolder,
                  tooltip: isRtl ? 'اختيار مجلد' : 'Pick Folder',
                ),
              ],
            ),
            const SizedBox(height: 16),

            _SectionLabel(
              text: isRtl
                  ? 'مسار ملف .torrent الناتج'
                  : 'Output .torrent File Path',
              color: textClr,
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _outputController,
                    style: TextStyle(
                        color: textClr, fontSize: 12, fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      hintText: isRtl
                          ? 'المسار لحفظ ملف .torrent'
                          : 'Path to save created .torrent file',
                      hintStyle: TextStyle(color: mutedClr, fontSize: 12),
                      filled: true,
                      fillColor: panelBg,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: borderClr, width: 0.8),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: borderClr, width: 0.8),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                            color: accentClr.withValues(alpha: 0.5),
                            width: 1.2),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.folder_open, color: accentClr),
                  onPressed: _pickOutputDirectory,
                  tooltip: isRtl ? 'اختيار مجلد الحفظ' : 'Pick Save Directory',
                ),
              ],
            ),
            const SizedBox(height: 16),

            _SectionLabel(
              text: isRtl ? 'المتتبعات' : 'Trackers',
              color: textClr,
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _trackerInputController,
                    style: TextStyle(
                        color: textClr, fontSize: 12, fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      hintText: 'udp://tracker.example.com:80/announce',
                      hintStyle: TextStyle(color: mutedClr, fontSize: 12),
                      filled: true,
                      fillColor: panelBg,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: borderClr, width: 0.8),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: borderClr, width: 0.8),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                            color: accentClr.withValues(alpha: 0.5),
                            width: 1.2),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.add, color: accentClr),
                  onPressed: _addTracker,
                  tooltip: isRtl ? 'إضافة متتبع' : 'Add Tracker',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _trackers.map((t) {
                return Chip(
                  label:
                      Text(t, style: TextStyle(fontSize: 11, color: textClr)),
                  backgroundColor: panelBg,
                  side: BorderSide(color: borderClr, width: 0.8),
                  deleteIcon: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.close, size: 16, color: mutedClr),
                  ),
                  onDeleted: () {
                    setState(() => _trackers.remove(t));
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            _SectionLabel(
              text: isRtl ? 'تعليق' : 'Comment',
              color: textClr,
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _commentController,
              style: TextStyle(color: textClr, fontSize: 12),
              decoration: InputDecoration(
                hintText: isRtl ? 'تعليق اختياري...' : 'Optional comment...',
                hintStyle: TextStyle(color: mutedClr, fontSize: 12),
                filled: true,
                fillColor: panelBg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: borderClr, width: 0.8),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: borderClr, width: 0.8),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                      color: accentClr.withValues(alpha: 0.5), width: 1.2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            SwitchListTile(
              title: Text(
                L10n.of(context, 'private_torrent'),
                style: TextStyle(
                    color: textClr, fontWeight: FontWeight.w600, fontSize: 13),
              ),
              subtitle: Text(
                L10n.of(context, 'disables_dht_pex'),
                style: TextStyle(color: mutedClr, fontSize: 11),
              ),
              value: _isPrivate,
              activeThumbColor: accentClr,
              onChanged: (val) => setState(() => _isPrivate = val),
            ),
            const SizedBox(height: 24),

            // FIX: Replaced layout-shifting ternary with isLoading property
            NeonGlowButton(
              text: isRtl ? 'إنشاء ملف .torrent' : 'Create .torrent File',
              onPressed: _isCreating ? null : _handleCreate,
              isLoading: _isCreating,
              color: accentClr,
              glowColor: accentClr,
              icon: Icons.create_new_folder_outlined,
              isExpanded: true,
              isFilled: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final Color color;

  const _SectionLabel({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: color,
        fontWeight: FontWeight.w700,
        fontSize: 12,
        letterSpacing: 0.5,
      ),
    );
  }
}
