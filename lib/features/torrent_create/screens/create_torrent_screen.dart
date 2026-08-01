import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
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
    final source = _sourceController.text.trim();
    var output = _outputController.text.trim();
    if (source.isEmpty) {
      ThemedSnackbar.show(
        context,
        message: 'Please select a source file or folder',
        color: Colors.redAccent,
        icon: Icons.error_outline,
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
      setState(() => _isCreating = false);

      if (res != null || File(output).existsSync()) {
        ThemedSnackbar.show(
          context,
          message: 'Torrent file created successfully!',
          color: Colors.greenAccent,
          icon: Icons.check_circle_outline,
        );
        Navigator.pop(context, output);
      } else {
        ThemedSnackbar.show(
          context,
          message: 'Torrent creation returned empty result',
          color: Colors.orangeAccent,
          icon: Icons.warning_amber_rounded,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isCreating = false);
      ThemedSnackbar.show(
        context,
        message: 'Creation failed: $e',
        color: Colors.redAccent,
        icon: Icons.error_outline,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<SettingsProvider>().isDarkMode;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          L10n.isRtl(context) ? 'إنشاء ملف تورنت' : 'Create Torrent',
          style: TextStyle(color: textClr, fontWeight: FontWeight.bold),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Source Path',
              style: TextStyle(color: textClr, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _sourceController,
                    decoration: const InputDecoration(
                      hintText: 'Select file or folder...',
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.insert_drive_file),
                  onPressed: _pickSourceFile,
                  tooltip: 'Pick File',
                ),
                IconButton(
                  icon: const Icon(Icons.folder),
                  onPressed: _pickSourceFolder,
                  tooltip: 'Pick Folder',
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Output .torrent File Path',
              style: TextStyle(color: textClr, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _outputController,
              decoration: const InputDecoration(
                hintText: 'Path to save created .torrent file',
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Trackers',
              style: TextStyle(color: textClr, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _trackerInputController,
                    decoration: const InputDecoration(
                      hintText: 'udp://tracker.example.com:80/announce',
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: _addTracker,
                  tooltip: 'Add Tracker',
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              children: _trackers.map((t) {
                return Chip(
                  label: Text(t, style: const TextStyle(fontSize: 11)),
                  onDeleted: () {
                    setState(() => _trackers.remove(t));
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            Text(
              'Comment',
              style: TextStyle(color: textClr, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _commentController,
              decoration: const InputDecoration(
                hintText: 'Optional comment...',
              ),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('Private Torrent'),
              subtitle: const Text('Disables DHT and PEX peer discovery'),
              value: _isPrivate,
              onChanged: (val) => setState(() => _isPrivate = val),
            ),
            const SizedBox(height: 24),
            _isCreating
                ? const Center(child: CircularProgressIndicator())
                : NeonGlowButton(
                    text: 'Create .torrent File',
                    onPressed: _handleCreate,
                  ),
          ],
        ),
      ),
    );
  }
}
