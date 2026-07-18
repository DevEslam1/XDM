import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import '../../../core/app_theme.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/url_utils.dart';
import '../../../core/utils/bencode_decoder.dart';
import '../../downloads/provider/download_provider.dart';
import '../../downloads/models/download_task.dart';
import '../../settings/provider/settings_provider.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/constants.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/services/download_engine.dart';
import '../widgets/youtube_quality_sheet.dart';
import '../widgets/youtube_playlist_sheet.dart';

class AddScreen extends StatefulWidget {
  final String? prefilledUrl;
  final String? prefilledName;
  final String? downloadPageUrl;
  const AddScreen({super.key, this.prefilledUrl, this.prefilledName, this.downloadPageUrl});

  @override
  State<AddScreen> createState() => _AddScreenState();
}

class _AddScreenState extends State<AddScreen> with HapticHelper {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _pathController = TextEditingController();

  String _selectedCategory = 'Auto';
  int _selectedThreads = 5;
  bool _isSubmitting = false;
  bool _showAdvanced = false;

  bool _isScheduled = false;
  DateTime? _scheduledDateTime;

  bool _isMetadataResolved = false;
  bool _isResolvingLink = false;
  String _resolvedFileName = '';
  int _resolvedFileSize = 0;
  String _resolvedCategory = 'Auto';
  bool _supportsResume = false;
  List<Map<String, dynamic>> _torrentFiles = [];
  String _lastCheckedUrl = '';
  Timer? _ytDebounceTimer;
  String? _resolvedYoutubePageUrl; // Original YT page URL preserved for stream refresh

  final List<String> _categories = [
    'Auto',
    'Video',
    'Audio',
    'Document',
    'Archive',
    'APK',
    'Other',
  ];
  final List<int> _threadsList = kAvailableThreadOptions;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsProvider>();
    if (_threadsList.contains(settings.defaultThreadCount)) {
      _selectedThreads = settings.defaultThreadCount;
    }
    _loadDefaultPath();
    _urlController.addListener(_onUrlChanged);
    if (widget.prefilledUrl != null) {
      _urlController.text = widget.prefilledUrl!;
      final url = widget.prefilledUrl!;
      if (YoutubeService.isYoutubeVideoUrl(url) || YoutubeService.isPlaylistUrl(url)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _resolveLinkMetadata();
        });
      } else if (url.trim().toLowerCase().startsWith('magnet:')) {
        final parsed = parseMagnetUrl(url);
        final dnName = parsed['name'] ?? 'Torrent Download';
        _nameController.text = dnName;
        _resolvedFileName = dnName;
        _resolvedCategory = 'Archive';
        _selectedCategory = 'Archive';
        _isMetadataResolved = true;
      }
    }
    if (widget.prefilledName != null) {
      _nameController.text = widget.prefilledName!;
      _resolvedFileName = widget.prefilledName!;
      _isMetadataResolved = true;
    }
  }

  void _onUrlChanged() {
    final url = _urlController.text.trim();
    if (url == _lastCheckedUrl) return;
    _lastCheckedUrl = url;

    _ytDebounceTimer?.cancel();

    if (url.toLowerCase().startsWith('magnet:')) {
      final parsed = parseMagnetUrl(url);
      final dnName = parsed['name'] ?? 'Torrent Download';
      setState(() {
        if (_nameController.text.isEmpty || _nameController.text == 'Torrent Download') {
          _nameController.text = dnName;
        }
        _resolvedFileName = _nameController.text.isNotEmpty ? _nameController.text : dnName;
        _resolvedCategory = 'Archive';
        _selectedCategory = 'Archive';
        _isMetadataResolved = true;
      });
    } else if (YoutubeService.isYoutubeVideoUrl(url) || YoutubeService.isPlaylistUrl(url)) {
      if (!_isResolvingLink && !_isMetadataResolved) {
        _ytDebounceTimer = Timer(const Duration(milliseconds: 800), () {
          if (_urlController.text.trim() == url && mounted) {
            _resolveLinkMetadata();
          }
        });
      }
    } else {
      if (_isMetadataResolved && _torrentFiles.isEmpty && _resolvedFileSize == 0 && _resolvedCategory == 'Archive') {
        setState(() {
          _isMetadataResolved = false;
          _resolvedFileName = '';
          _nameController.clear();
        });
      }
    }
  }

  Future<void> _loadDefaultPath() async {
    final settings = context.read<SettingsProvider>();
    final path = settings.customDownloadPath?.isNotEmpty == true
        ? settings.customDownloadPath!
        : await PermissionService().defaultDownloadDirectory();
    if (!mounted) return;
    if (_pathController.text.isEmpty) {
      _pathController.text = path;
    }
  }

  @override
  void dispose() {
    _ytDebounceTimer?.cancel();
    _urlController.removeListener(_onUrlChanged);
    _urlController.dispose();
    _nameController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      if (!mounted) return;
      _urlController.text = data.text!;
      _urlController.selection = TextSelection.fromPosition(
        TextPosition(offset: _urlController.text.length),
      );
      final url = data.text!.trim();
      if (YoutubeService.isYoutubeVideoUrl(url) || YoutubeService.isPlaylistUrl(url)) {
        _resolveLinkMetadata();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;

    return GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          automaticallyImplyLeading: false,
          title: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: blueClr.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: blueClr.withValues(alpha: 0.25), width: 0.8),
                ),
                child: Icon(Icons.add_circle_outline, color: blueClr, size: 18),
              ),
              const SizedBox(width: 12),
              Text(
                isRtl ? 'إرسال جديد' : 'NEW TRANSMISSION',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: textClr,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                  fontSize: 18,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.close, color: textClr, size: 22),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        body: Directionality(
          textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Center(
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        children: [
                          _buildSection(
                            isDark: isDark,
                            title: isRtl ? 'مصدر الإشارة' : 'SOURCE',
                            subtitle: isRtl ? 'أدخل رابط التحميل أو ملف التورنت' : 'Enter URL, magnet, or torrent file',
                            icon: Icons.link_rounded,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  decoration: BoxDecoration(
                                    color: (isDark ? const Color(0xFF0F0F16) : const Color(0xFFF1F5F9)).withValues(alpha: 0.7),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: isDark ? const Color(0x15FFFFFF) : const Color(0x0D000000),
                                    ),
                                  ),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: TextFormField(
                                          controller: _urlController,
                                          minLines: 1,
                                          maxLines: 4,
                                          style: TextStyle(color: textClr, fontSize: 14),
                                          decoration: InputDecoration(
                                            hintText: isRtl ? 'أدخل رابط التحميل أو المغناطيس' : 'Enter download URL or Magnet link',
                                            hintStyle: TextStyle(color: secClr.withValues(alpha: 0.6), fontSize: 13),
                                            border: InputBorder.none,
                                            enabledBorder: InputBorder.none,
                                            focusedBorder: InputBorder.none,
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                          ),
                                          validator: (value) {
                                            if (value == null || value.trim().isEmpty) {
                                              return isRtl ? 'رابط الإشارة مطلوب' : 'URL signal required';
                                            }
                                            final urls = value.split(RegExp(r'[\r\n]+')).map((u) => u.trim()).where((u) => u.isNotEmpty).toList();
                                            if (urls.isEmpty) return isRtl ? 'رابط الإشارة مطلوب' : 'URL signal required';
                                            final allValid = urls.every((u) => isValidTransmissionUrl(u));
                                            if (!allValid) return isRtl ? 'تأكد من صحة جميع الروابط' : 'Ensure all URLs are valid';
                                            return null;
                                          },
                                        ),
                                      ),
                                      Column(
                                        children: [
                                          _ActionButton(icon: Icons.content_paste, color: blueClr, tooltip: isRtl ? 'لصق من الحافظة' : 'Paste', onTap: () { triggerHaptic(settings); _pasteFromClipboard(); }),
                                          _ActionButton(icon: Icons.file_open_outlined, color: blueClr, tooltip: isRtl ? 'استيراد ملف تورنت' : 'Import .torrent', onTap: () { triggerHaptic(settings); _pickTorrentFile(settings); }),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                if (_isResolvingLink)
                                  const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 4),
                                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                                  )
                                else
                                  Align(
                                    alignment: isRtl ? Alignment.centerLeft : Alignment.centerRight,
                                    child: TextButton.icon(
                                      onPressed: _resolveLinkMetadata,
                                      icon: Icon(Icons.search_rounded, size: 16, color: blueClr),
                                      label: Text(
                                        isRtl ? 'تحقق من الرابط' : 'VERIFY LINK',
                                        style: TextStyle(color: blueClr, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (_isMetadataResolved)
                            _buildMetadataPanel(context, isDark, isRtl, textClr, secClr, blueClr),
                          _buildSection(
                            isDark: isDark,
                            title: isRtl ? 'الإعدادات' : 'SETTINGS',
                            subtitle: isRtl ? 'تخصيص اسم الملف ومسار الحفظ' : 'Configure file name and save path',
                            icon: Icons.settings_rounded,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildLabel(context, isRtl ? 'اسم الملف (اختياري)' : 'FILE NAME (OPTIONAL)', secClr),
                                const SizedBox(height: 6),
                                _buildTextField(
                                  controller: _nameController,
                                  hint: isRtl ? 'اتركه فارغاً للكشف التلقائي' : 'Leave blank to auto-detect',
                                  isDark: isDark,
                                ),
                                const SizedBox(height: 16),
                                _buildLabel(context, isRtl ? 'مسار الحفظ' : 'SAVE PATH', secClr),
                                const SizedBox(height: 6),
                                _buildTextField(
                                  controller: _pathController,
                                  hint: isRtl ? 'مجلد الوجهة' : 'Destination folder',
                                  isDark: isDark,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          _buildAdvancedSection(context, isDark, isRtl, textClr, secClr, blueClr),
                          const SizedBox(height: 20),
                          NeonGlowButton(
                            isExpanded: true,
                            isFilled: true,
                            onPressed: _isSubmitting ? null : () async {
                              triggerHaptic(settings);
                              if (_formKey.currentState!.validate()) {
                                final url = _urlController.text.trim();
                                if ((YoutubeService.isYoutubeVideoUrl(url) || YoutubeService.isPlaylistUrl(url)) && !_isMetadataResolved) {
                                  await _resolveLinkMetadata();
                                  return;
                                }
                                if (_isMetadataResolved && _torrentFiles.isNotEmpty) {
                                  final hasSelected = _torrentFiles.any((f) => f['selected'] == true);
                                  if (!hasSelected) {
                                    ThemedSnackbar.show(context, message: isRtl ? 'يجب تحديد ملف واحد على الأقل' : 'Select at least one file', color: redClr, icon: Icons.warning_amber_outlined, isDarkMode: isDark);
                                    return;
                                  }
                                }
                                final provider = context.read<DownloadProvider>();
                                await _handleDuplicateOrSubmit(context, provider, settings, isDark, isRtl);
                              }
                            },
                            text: _isSubmitting
                                ? (isRtl ? 'جاري حل المصدر...' : 'RESOLVING SOURCE...')
                                : (isRtl ? 'إنشاء اتصال النقل' : 'ESTABLISH TRANSFER'),
                            isLoading: _isSubmitting,
                            icon: Icons.rocket_launch_outlined,
                            color: blueClr,
                            glowColor: blueClr,
                          ),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSection({
    required bool isDark,
    required String title,
    required String subtitle,
    required IconData icon,
    required Widget child,
  }) {
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    return GlassCard(
      borderRadius: 20,
      padding: const EdgeInsets.all(16),
      isDarkMode: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: secClr),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  color: secClr,
                  fontSize: 10,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: Text(
              subtitle,
              style: TextStyle(
                color: secClr.withValues(alpha: 0.6),
                fontSize: 9,
              ),
            ),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _buildLabel(BuildContext context, String text, Color color) {
    return Text(
      text,
      style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    required bool isDark,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: (isDark ? const Color(0xFF0F0F16) : const Color(0xFFF1F5F9)).withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? const Color(0x15FFFFFF) : const Color(0x0D000000)),
      ),
      child: TextFormField(
        controller: controller,
        style: TextStyle(color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary, fontSize: 13),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
            color: (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted).withValues(alpha: 0.6),
            fontSize: 12,
          ),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
    );
  }

  Widget _buildAdvancedSection(BuildContext context, bool isDark, bool isRtl, Color textClr, Color secClr, Color blueClr) {
    final glassBorder = isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;
    return GlassCard(
      borderRadius: 20,
      padding: const EdgeInsets.all(16),
      isDarkMode: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () {
              triggerHaptic(context.read<SettingsProvider>());
              setState(() => _showAdvanced = !_showAdvanced);
            },
            child: Row(
              children: [
                Icon(Icons.tune_rounded, size: 16, color: secClr),
                const SizedBox(width: 8),
                Text(
                  (isRtl ? 'خيارات متقدمة' : 'ADVANCED OPTIONS').toUpperCase(),
                  style: TextStyle(color: blueClr, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.0),
                ),
                const Spacer(),
                Icon(_showAdvanced ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: blueClr, size: 20),
              ],
            ),
          ),
          if (_showAdvanced) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildLabel(context, isRtl ? 'الفئة' : 'CATEGORY', secClr),
                      const SizedBox(height: 6),
                      _buildDropdown<String>(value: _selectedCategory, items: _categories, isDark: isDark, onChanged: (val) { if (val != null) setState(() => _selectedCategory = val); }),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildLabel(context, isRtl ? 'الخيوط' : 'THREADS', secClr),
                      const SizedBox(height: 6),
                      _buildDropdown<int>(value: _selectedThreads, items: _threadsList, isDark: isDark, onChanged: (val) { if (val != null) setState(() => _selectedThreads = val); }),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                SizedBox(
                  width: 20, height: 20,
                  child: Checkbox(
                    value: _isScheduled,
                    activeColor: blueClr,
                    side: BorderSide(color: glassBorder, width: 1.0),
                    onChanged: (val) {
                      setState(() {
                        _isScheduled = val ?? false;
                        if (_isScheduled && _scheduledDateTime == null) {
                          _scheduledDateTime = DateTime.now().add(const Duration(minutes: 5));
                        }
                      });
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  isRtl ? 'جدولة التنزيل' : 'SCHEDULE DOWNLOAD',
                  style: TextStyle(color: textClr, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                ),
                if (_isScheduled) ...[
                  const Spacer(),
                  TextButton.icon(
                    icon: Icon(Icons.calendar_month, size: 16, color: blueClr),
                    label: Text(
                      _scheduledDateTime != null
                        ? '${_scheduledDateTime!.hour.toString().padLeft(2, '0')}:${_scheduledDateTime!.minute.toString().padLeft(2, '0')}'
                        : (isRtl ? 'حدد الوقت' : 'SELECT TIME'),
                      style: TextStyle(color: blueClr, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                    onPressed: () async {
                      final date = await showDatePicker(
                        context: context,
                        initialDate: _scheduledDateTime ?? DateTime.now(),
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 30)),
                        builder: (context, child) => Theme(
                          data: Theme.of(context).copyWith(
                            colorScheme: isDark
                                ? ColorScheme.dark(primary: blueClr, onPrimary: AppTheme.background, surface: AppTheme.surface, onSurface: AppTheme.textPrimary)
                                : ColorScheme.light(primary: blueClr, onPrimary: Colors.white, surface: AppTheme.lightSurface, onSurface: AppTheme.lightTextPrimary),
                          ),
                          child: child!,
                        ),
                      );
                      if (date != null && mounted) {
                        if (!context.mounted) return;
                        final time = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(_scheduledDateTime ?? DateTime.now()),
                          builder: (context, child) => Theme(
                            data: Theme.of(context).copyWith(
                              colorScheme: isDark
                                  ? ColorScheme.dark(primary: blueClr, onPrimary: AppTheme.background, surface: AppTheme.surface, onSurface: AppTheme.textPrimary)
                                  : ColorScheme.light(primary: blueClr, onPrimary: Colors.white, surface: AppTheme.lightSurface, onSurface: AppTheme.lightTextPrimary),
                            ),
                            child: child!,
                          ),
                        );
                        if (time != null) {
                          setState(() {
                            _scheduledDateTime = DateTime(date.year, date.month, date.day, time.hour, time.minute);
                          });
                        }
                      }
                    },
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDropdown<T>({
    required T value,
    required List<T> items,
    required ValueChanged<T?> onChanged,
    required bool isDark,
  }) {
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final bgClr = isDark ? AppTheme.background : AppTheme.lightBackground;
    final glassBorder = isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;
    final surfaceClr = isDark ? AppTheme.surface : AppTheme.lightSurface;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: bgClr.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: glassBorder, width: 0.8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          dropdownColor: surfaceClr,
          value: value,
          isExpanded: true,
          icon: Icon(Icons.arrow_drop_down, color: secClr),
          style: TextStyle(color: textClr, fontSize: 13, fontWeight: FontWeight.bold),
          items: items.map((item) => DropdownMenuItem<T>(value: item, child: Text(item.toString().toUpperCase()))).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildMetadataPanel(BuildContext context, bool isDark, bool isRtl, Color textClr, Color secClr, Color blueClr) {
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;

    IconData categoryIcon;
    switch (_resolvedCategory) {
      case 'Video': categoryIcon = Icons.movie_outlined; break;
      case 'Audio': categoryIcon = Icons.audiotrack_outlined; break;
      case 'Document': categoryIcon = Icons.description_outlined; break;
      case 'Archive': categoryIcon = Icons.folder_zip_outlined; break;
      case 'APK': categoryIcon = Icons.android_outlined; break;
      default: categoryIcon = Icons.insert_drive_file_outlined;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        borderRadius: 20,
        padding: const EdgeInsets.all(16),
        isDarkMode: isDark,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: blueClr.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: blueClr.withValues(alpha: 0.2), width: 0.8),
                  ),
                  child: Icon(categoryIcon, color: blueClr, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isRtl ? 'تم التحقق من البيانات' : 'VERIFIED METADATA',
                        style: TextStyle(color: secClr, fontSize: 9, letterSpacing: 0.8, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _resolvedFileName,
                        style: TextStyle(color: textClr, fontSize: 13, fontWeight: FontWeight.bold),
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _buildBadge(label: formatBytes(_resolvedFileSize), color: textClr, isDark: isDark),
                const SizedBox(width: 8),
                _buildBadge(
                  label: _supportsResume ? (isRtl ? 'يدعم الاستكمال' : 'RESUME') : (isRtl ? 'لا يدعم الاستكمال' : 'NO RESUME'),
                  color: _supportsResume ? greenClr : redClr,
                  isDark: isDark,
                ),
                if (_resolvedCategory != 'Auto') ...[
                  const SizedBox(width: 8),
                  _buildBadge(label: _resolvedCategory.toUpperCase(), color: blueClr, isDark: isDark),
                ],
              ],
            ),
            if (_torrentFiles.isNotEmpty) ...[
              const SizedBox(height: 14),
              Divider(height: 1, thickness: 0.5, color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.folder_outlined, size: 14, color: secClr),
                  const SizedBox(width: 6),
                  Text(
                    isRtl ? 'الملفات المضمنة (${_torrentFiles.length})' : 'FILES (${_torrentFiles.length})',
                    style: TextStyle(color: secClr, fontSize: 9, letterSpacing: 0.5, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 150),
                decoration: BoxDecoration(
                  color: (isDark ? AppTheme.background : AppTheme.lightBackground).withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder, width: 0.6),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                  itemCount: _torrentFiles.length,
                  separatorBuilder: (context, index) => Divider(height: 8, thickness: 0.3, color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder),
                  itemBuilder: (context, index) {
                    final f = _torrentFiles[index];
                    final name = f['name'] as String? ?? 'unknown';
                    final length = f['length'] as int? ?? 0;
                    final selected = f['selected'] as bool? ?? true;
                    return Row(
                      children: [
                        SizedBox(
                          width: 18, height: 18,
                          child: Checkbox(
                            value: selected,
                            activeColor: blueClr,
                            side: BorderSide(color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder, width: 0.8),
                            onChanged: (val) {
                              if (val != null) {
                                setState(() {
                                  _torrentFiles[index] = {...f, 'selected': val};
                                  _resolvedFileSize = _torrentFiles.where((file) => file['selected'] == true).fold(0, (sum, file) => sum + (file['length'] as int));
                                });
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(Icons.insert_drive_file_outlined, size: 13, color: selected ? textClr : secClr),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            name,
                            style: TextStyle(color: selected ? textClr : secClr, fontSize: 11, decoration: selected ? null : TextDecoration.lineThrough),
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (selected) ...[
                          const SizedBox(width: 6),
                          _buildPrioritySelector(context: context, priority: f['priority'] as int? ?? 4, isDark: isDark, isRtl: isRtl, onChanged: (newPriority) { setState(() { _torrentFiles[index] = {...f, 'priority': newPriority}; }); }),
                        ],
                        const SizedBox(width: 6),
                        Text(formatBytes(length), style: TextStyle(color: selected ? secClr : secClr.withValues(alpha: 0.5), fontSize: 10, fontWeight: FontWeight.w600)),
                      ],
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBadge({required String label, required Color color, required bool isDark}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 0.6),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
    );
  }

  Future<void> _pickTorrentFile(SettingsProvider settings) async {
    try {
      final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['torrent']);
      if (!mounted) return;
      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        final file = File(filePath);
        final bytes = await file.readAsBytes();
        final meta = BencodeDecoder.parseTorrentBytes(bytes);
        if (!mounted) return;
        if (meta != null) {
          setState(() {
            _urlController.text = 'file://$filePath';
            _nameController.text = meta['name'] ?? '';
            _selectedCategory = 'Archive';
            _resolvedFileName = meta['name'] ?? '';
            _resolvedFileSize = meta['length'] ?? 0;
            _resolvedCategory = 'Archive';
            _supportsResume = true;
            _torrentFiles = (meta['files'] as List? ?? []).map((f) => {
              'name': f['name'] as String? ?? '',
              'length': f['length'] as int? ?? 0,
              'selected': true, 'priority': 4, 'downloadedBytes': 0, 'speed': 0.0,
            }).toList();
            _isMetadataResolved = true;
          });
          if (mounted) {
            ThemedSnackbar.show(context, message: L10n.isRtl(context) ? 'تم استيراد بيانات التورنت' : 'Torrent imported', color: AppTheme.neonBlue, icon: Icons.check_circle_outline, isDarkMode: settings.isDarkMode);
          }
        } else {
          if (mounted) ThemedSnackbar.show(context, message: L10n.isRtl(context) ? 'فشل قراءة ملف التورنت' : 'Failed to read torrent', color: AppTheme.neonRed, icon: Icons.error_outline, isDarkMode: settings.isDarkMode);
        }
      }
    } catch (e) {
      if (mounted) ThemedSnackbar.show(context, message: 'Error: $e', color: AppTheme.neonRed, icon: Icons.error_outline, isDarkMode: settings.isDarkMode);
    }
  }

  Future<void> _resolveLinkMetadata() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ThemedSnackbar.show(context, message: L10n.isRtl(context) ? 'أدخل الرابط أولاً' : 'Enter a URL first', color: AppTheme.neonRed, icon: Icons.error_outline, isDarkMode: context.read<SettingsProvider>().isDarkMode);
      return;
    }

    if (YoutubeService.isPlaylistUrl(url)) {
      // Check if it's a mixed URL (has both v= and list=) and ask the user.
      final isMixed = YoutubeService.isYoutubeVideoUrl(url);
      if (isMixed && mounted) {
        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) {
            final isDark = context.read<SettingsProvider>().isDarkMode;
            final isRtl = L10n.isRtl(context);
            return AlertDialog(
              backgroundColor: isDark ? const Color(0xFF1A1A2E) : Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Text(isRtl ? 'ماذا تريد تحميل؟' : 'What do you want to download?',
                  style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 16, fontWeight: FontWeight.bold)),
              content: Text(isRtl ? 'هذا الرابط يحتوي على فيديو وقائمة تشغيل.' : 'This link contains both a single video and a playlist.',
                  style: TextStyle(color: isDark ? Colors.white70 : Colors.black54, fontSize: 13)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'video'),
                  child: Text(isRtl ? 'فيديو واحد فقط' : 'Single Video',
                      style: const TextStyle(color: Colors.blue, fontWeight: FontWeight.bold)),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'playlist'),
                  child: Text(isRtl ? 'قائمة التشغيل كاملة' : 'Entire Playlist',
                      style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
        if (!mounted) return;
        if (choice == 'video') {
          // Fall through to single-video handling below
        } else if (choice == 'playlist') {
          final result = await YoutubePlaylistSheet.show(context, url);
          if (result != null && mounted) {
            final isDark = context.read<SettingsProvider>().isDarkMode;
            ThemedSnackbar.show(context, message: L10n.isRtl(context) ? 'تم إضافة ${result.selectedVideos.length} فيديو' : '${result.selectedVideos.length} videos enqueued', color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen, icon: Icons.playlist_add_check, isDarkMode: isDark);
            if (mounted) Navigator.pop(context);
          }
          return;
        } else {
          return; // dismissed
        }
      } else if (!isMixed && mounted) {
        // Pure playlist URL — go straight to the playlist sheet
        final result = await YoutubePlaylistSheet.show(context, url);
        if (result != null && mounted) {
          final isDark = context.read<SettingsProvider>().isDarkMode;
          ThemedSnackbar.show(context, message: L10n.isRtl(context) ? 'تم إضافة ${result.selectedVideos.length} فيديو' : '${result.selectedVideos.length} videos enqueued', color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen, icon: Icons.playlist_add_check, isDarkMode: isDark);
          if (mounted) Navigator.pop(context);
        }
        return;
      }
    }

    if (YoutubeService.isYoutubeVideoUrl(url)) {
      if (!mounted) return;
      final stream = await YoutubeQualitySheet.show(context, url);
      if (!mounted) return;
      if (stream == null) {
        if (mounted) Navigator.pop(context);
        return;
      }
      if (stream['type'] == 'combined') {
        // Handled directly inside the sheet; close add screen
        if (mounted) Navigator.pop(context);
        return;
      }
      if (mounted) {
        final title = stream['title'] as String? ?? 'YouTube Video';
        final ext = stream['ext'] as String? ?? 'mp4';
        setState(() {
          _resolvedYoutubePageUrl = url; // Save original YT page URL for expiry refresh
          _urlController.text = stream['src'] as String;
          _resolvedFileName = '$title.$ext';
          _nameController.text = _resolvedFileName;
          _resolvedFileSize = stream['size'] as int? ?? 0;
          _resolvedCategory = (stream['type'] as String? ?? 'muxed') == 'audio' ? 'Audio' : 'Video';
          _selectedCategory = _resolvedCategory;
          _supportsResume = true;
          _torrentFiles = [];
          _isMetadataResolved = true;
        });
      }
      return;
    }

    if (!isValidTransmissionUrl(url)) {
      ThemedSnackbar.show(context, message: L10n.isRtl(context) ? 'رابط غير صالح' : 'Invalid URL', color: AppTheme.neonRed, icon: Icons.error_outline, isDarkMode: context.read<SettingsProvider>().isDarkMode);
      return;
    }

    setState(() { _isResolvingLink = true; _isMetadataResolved = false; _torrentFiles = []; });

    try {
      final settings = context.read<SettingsProvider>();
      if (url.startsWith('file://')) {
        final filePath = Uri.parse(url).toFilePath();
        final file = File(filePath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final meta = BencodeDecoder.parseTorrentBytes(bytes);
          if (meta != null) {
            setState(() {
              _resolvedFileName = meta['name'] ?? '';
              _resolvedFileSize = meta['length'] ?? 0;
              _resolvedCategory = 'Archive';
              _supportsResume = true;
              _torrentFiles = (meta['files'] as List? ?? []).map((f) => ({
                'name': f['name'] as String? ?? '', 'length': f['length'] as int? ?? 0,
                'selected': true, 'priority': 4, 'downloadedBytes': 0, 'speed': 0.0,
              })).toList();
              _isMetadataResolved = true;
              _nameController.text = _resolvedFileName;
              _selectedCategory = 'Archive';
            });
            return;
          }
        }
      }

      final engine = DownloadEngine();
      final meta = await engine.resolveMetadata(
        url: url,
        requestedFileName: _nameController.text.trim().isNotEmpty ? _nameController.text.trim() : null,
        customUserAgent: settings.customUserAgent, enableProxy: settings.enableProxy,
        proxyAddress: settings.proxyAddress, proxyHost: settings.proxyHost, proxyPort: settings.proxyPort,
        proxyUsername: settings.proxyUsername, proxyPassword: settings.proxyPassword, bypassSSL: settings.bypassSSL,
      );

      setState(() {
        _resolvedFileName = meta.fileName; _resolvedFileSize = meta.fileSize;
        _resolvedCategory = meta.category; _supportsResume = meta.supportsResume;
        _torrentFiles = meta.torrentFiles ?? []; _isMetadataResolved = true;
        _nameController.text = _resolvedFileName;
        if (_categories.contains(_resolvedCategory)) _selectedCategory = _resolvedCategory;
      });
    } catch (e) {
      if (mounted) ThemedSnackbar.show(context, message: 'Error: $e', color: AppTheme.neonRed, icon: Icons.error_outline, isDarkMode: context.read<SettingsProvider>().isDarkMode);
    } finally {
      if (mounted) setState(() => _isResolvingLink = false);
    }
  }

  Future<void> _handleDuplicateOrSubmit(BuildContext context, DownloadProvider provider, SettingsProvider settings, bool isDark, bool isRtl) async {
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    final enteredName = _nameController.text.trim();
    final finalFileName = enteredName.isNotEmpty ? safeFileName(enteredName) : fileNameFromUrl(_urlController.text.trim());
    final int finalSize = _isMetadataResolved ? _resolvedFileSize : 0;

    DownloadTask? duplicateTask;
    if (finalSize > 0) {
      for (final task in provider.tasks) {
        if (task.fileName.toLowerCase() == finalFileName.toLowerCase() && task.fileSize == finalSize) {
          duplicateTask = task;
          break;
        }
      }
    }

    if (duplicateTask != null) {
      showDialog(context: context, barrierDismissible: false, builder: (context) {
        return AlertDialog(
          backgroundColor: isDark ? AppTheme.surface : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder)),
          title: Text(isRtl ? 'ملف مكرر' : 'DUPLICATE', style: TextStyle(color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber, fontWeight: FontWeight.bold, fontSize: 16)),
          content: Text(isRtl ? 'يوجد ملف بنفس الاسم والحجم. اختر إجراء:' : 'A file with the same name and size exists. Choose an action:', style: TextStyle(color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary, fontSize: 13)),
          actionsAlignment: MainAxisAlignment.center,
          actionsOverflowButtonSpacing: 8,
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: blueClr.withValues(alpha: 0.1), side: BorderSide(color: blueClr), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              onPressed: () async {
                triggerHaptic(settings); Navigator.pop(context);
                setState(() => _isSubmitting = true);
                try {
                  await provider.updateTaskUrlAndResume(duplicateTask!.id, _urlController.text.trim());
                  if (!mounted) return; setState(() => _isSubmitting = false);
                  if (!context.mounted) return;
                  ThemedSnackbar.show(context, message: isRtl ? 'تم تحديث الرابط' : 'Link updated', color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen, icon: Icons.check_circle_outline, isDarkMode: isDark);
                  Navigator.pop(context);
                } catch (e) { if (!mounted) return; setState(() => _isSubmitting = false); if (!context.mounted) return; ThemedSnackbar.show(context, message: e.toString(), color: redClr, icon: Icons.error_outline, isDarkMode: isDark); }
              },
              child: Text(isRtl ? 'تحديث الرابط' : 'UPDATE LINK', style: TextStyle(color: blueClr, fontWeight: FontWeight.bold, fontSize: 11)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: (isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet).withValues(alpha: 0.1), side: BorderSide(color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              onPressed: () async {
                triggerHaptic(settings); Navigator.pop(context);
                setState(() => _isSubmitting = true);
                try {
                  await provider.startOverTask(duplicateTask!.id, _urlController.text.trim());
                  if (!mounted) return; setState(() => _isSubmitting = false);
                  if (!context.mounted) return;
                  ThemedSnackbar.show(context, message: isRtl ? 'بدأ من جديد' : 'Started over', color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen, icon: Icons.refresh, isDarkMode: isDark);
                  Navigator.pop(context);
                } catch (e) { if (!mounted) return; setState(() => _isSubmitting = false); if (!context.mounted) return; ThemedSnackbar.show(context, message: e.toString(), color: redClr, icon: Icons.error_outline, isDarkMode: isDark); }
              },
              child: Text(isRtl ? 'بدء من جديد' : 'START OVER', style: TextStyle(color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet, fontWeight: FontWeight.bold, fontSize: 11)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen).withValues(alpha: 0.1), side: BorderSide(color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              onPressed: () async {
                triggerHaptic(settings); Navigator.pop(context);
                setState(() => _isSubmitting = true);
                String numberedName = finalFileName;
                final ext = p.extension(finalFileName);
                final base = p.basenameWithoutExtension(finalFileName);
                var counter = 1;
                while (true) {
                  final candidate = '${base}_$counter$ext';
                  final exists = provider.tasks.any((t) => t.fileName.toLowerCase() == candidate.toLowerCase());
                  if (!exists) { numberedName = candidate; break; }
                  counter++;
                }
                try {
                  await provider.addDownload(name: numberedName, url: _urlController.text.trim(), size: finalSize, category: _selectedCategory == 'Auto' ? '' : _selectedCategory, savePath: _pathController.text.trim(), threadCount: _selectedThreads, scheduledAt: _isScheduled ? _scheduledDateTime : null, torrentFiles: _torrentFiles.isNotEmpty ? _torrentFiles : null, downloadPageUrl: widget.downloadPageUrl);
                  if (!mounted) return; setState(() => _isSubmitting = false);
                  if (!context.mounted) return; Navigator.pop(context);
                } catch (e) { if (!mounted) return; setState(() => _isSubmitting = false); if (!context.mounted) return; ThemedSnackbar.show(context, message: e.toString(), color: redClr, icon: Icons.error_outline, isDarkMode: isDark); }
              },
              child: Text(isRtl ? 'إضافة كملف مرقم' : 'ADD NUMBERED', style: TextStyle(color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen, fontWeight: FontWeight.bold, fontSize: 11)),
            ),
            TextButton(
              onPressed: () { triggerHaptic(settings); Navigator.pop(context); },
              child: Text(L10n.of(context, 'cancel_btn'), style: TextStyle(color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted)),
            ),
          ],
        );
      });
    } else {
      setState(() => _isSubmitting = true);
      await provider.addDownload(
        name: enteredName, url: _urlController.text.trim(), size: finalSize,
        category: _selectedCategory == 'Auto' ? '' : _selectedCategory, savePath: _pathController.text.trim(),
        threadCount: _selectedThreads, scheduledAt: _isScheduled ? _scheduledDateTime : null,
        torrentFiles: _torrentFiles.isNotEmpty ? _torrentFiles : null,
        downloadPageUrl: _resolvedYoutubePageUrl ?? widget.downloadPageUrl,
      );
      if (!mounted) return; setState(() => _isSubmitting = false);
      if (!context.mounted) return;
      if (provider.lastError != null) {
        ThemedSnackbar.show(context, message: provider.lastError!, color: redClr, icon: Icons.error_outline, isDarkMode: isDark);
        return;
      }
      ThemedSnackbar.show(context, message: isRtl ? 'تم إنشاء الاتصال' : 'TRANSMISSION ESTABLISHED', color: blueClr, icon: Icons.rocket_launch_outlined, isDarkMode: isDark);
      Navigator.pop(context);
    }
  }

  Widget _buildPrioritySelector({required BuildContext context, required int priority, required bool isDark, required bool isRtl, required ValueChanged<int> onChanged}) {
    final Color priorityColor;
    final String label;
    switch (priority) {
      case 7: priorityColor = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed; label = isRtl ? 'عالية' : 'High'; break;
      case 1: priorityColor = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet; label = isRtl ? 'منخفضة' : 'Low'; break;
      case 4: default: priorityColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue; label = isRtl ? 'عادية' : 'Normal'; break;
    }

    return PopupMenuButton<int>(
      tooltip: isRtl ? 'تحديد الأولوية' : 'Set priority',
      padding: EdgeInsets.zero,
      onSelected: onChanged,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: priorityColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: priorityColor.withValues(alpha: 0.3), width: 0.8)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 5, height: 5, decoration: BoxDecoration(color: priorityColor, shape: BoxShape.circle)),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: priorityColor, fontSize: 10, fontWeight: FontWeight.bold)),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down, size: 12, color: priorityColor),
          ],
        ),
      ),
      itemBuilder: (context) => [
        PopupMenuItem<int>(value: 7, child: Row(children: [Container(width: 8, height: 8, decoration: BoxDecoration(color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed, shape: BoxShape.circle)), const SizedBox(width: 8), Text(isRtl ? 'عالية' : 'High', style: TextStyle(color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed, fontWeight: FontWeight.bold, fontSize: 13))])),
        PopupMenuItem<int>(value: 4, child: Row(children: [Container(width: 8, height: 8, decoration: BoxDecoration(color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue, shape: BoxShape.circle)), const SizedBox(width: 8), Text(isRtl ? 'عادية' : 'Normal', style: TextStyle(color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue, fontWeight: FontWeight.bold, fontSize: 13))])),
        PopupMenuItem<int>(value: 1, child: Row(children: [Container(width: 8, height: 8, decoration: BoxDecoration(color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet, shape: BoxShape.circle)), const SizedBox(width: 8), Text(isRtl ? 'منخفضة' : 'Low', style: TextStyle(color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet, fontWeight: FontWeight.bold, fontSize: 13))])),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  const _ActionButton({required this.icon, required this.color, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 4, right: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2), width: 0.8),
      ),
      child: IconButton(
        icon: Icon(icon, color: color, size: 18),
        tooltip: tooltip,
        onPressed: onTap,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        padding: EdgeInsets.zero,
      ),
    );
  }
}
