import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import '../../../core/app_theme.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/url_utils.dart';
import '../../../core/utils/bencode_decoder.dart';
import '../../downloads/provider/download_provider.dart';
import '../../downloads/models/download_task.dart';
import '../../settings/provider/settings_provider.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/constants.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/services/download_engine.dart';

class AddScreen extends StatefulWidget {
  final String? prefilledUrl;
  const AddScreen({super.key, this.prefilledUrl});

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

  bool _isScheduled = false;
  DateTime? _scheduledDateTime;

  bool _isMetadataResolved = false;
  bool _isResolvingLink = false;
  String _resolvedFileName = '';
  int _resolvedFileSize = 0;
  String _resolvedCategory = 'Auto';
  bool _supportsResume = false;
  List<Map<String, dynamic>> _torrentFiles = [];

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
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    if (_threadsList.contains(settings.defaultThreadCount)) {
      _selectedThreads = settings.defaultThreadCount;
    }
    _loadDefaultPath();
    if (widget.prefilledUrl != null) {
      _urlController.text = widget.prefilledUrl!;
    }
  }

  Future<void> _loadDefaultPath() async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final path = settings.customDownloadPath?.isNotEmpty == true
        ? settings.customDownloadPath!
        : await PermissionService().defaultDownloadDirectory();
    if (!mounted) return;
    // Only fill the path if the user hasn't already started typing into
    // the field. Otherwise we'd silently overwrite their input.
    if (_pathController.text.isEmpty) {
      _pathController.text = path;
    }
  }

  @override
  void dispose() {
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
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final glassBorder = isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;

    return GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          flexibleSpace: ClipRect(
            child: DmxBackdropFilter(
              sigmaX: 12,
              sigmaY: 12,
              child: Container(
                color: (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(alpha: 0.5),
              ),
            ),
          ),
          title: Text(
            isRtl ? 'إرسال جديد' : 'NEW TRANSMISSION',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: textClr,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
              fontSize: 16,
            ),
          ),
          leading: IconButton(
            icon: Icon(
              isRtl ? Icons.arrow_forward_ios : Icons.arrow_back_ios_new,
              size: 18,
              color: textClr,
            ),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: Directionality(
          textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
          child: SafeArea(
            child: Form(
              key: _formKey,
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 10),
                    // URL Input Card
                    _buildInputPanel(
                      context,
                      isDark: isDark,
                      title: isRtl ? 'مصدر إشارة الرابط' : 'SOURCE INTERFACE SIGNAL',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isRtl ? 'رابط المصدر' : 'SOURCE URL',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  fontSize: 10,
                                  color: secClr,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: TextFormField(
                                  controller: _urlController,
                                  minLines: 1,
                                  maxLines: 5,
                                  style: TextStyle(
                                    color: textClr,
                                    fontSize: 13,
                                  ),
                                  decoration: _buildInputDecoration(
                                    isRtl ? 'أدخل رابط التحميل أو المغناطيس (Magnet)' : 'Enter download URL or Magnet link',
                                    isDark: isDark,
                                  ),
                                  validator: (value) {
                                    if (value == null || value.trim().isEmpty) {
                                      return isRtl ? 'رابط الإشارة مطلوب' : 'URL signal required';
                                    }
                                    final urls = value.split(RegExp(r'[\r\n]+')).map((u) => u.trim()).where((u) => u.isNotEmpty).toList();
                                    if (urls.isEmpty) {
                                      return isRtl ? 'رابط الإشارة مطلوب' : 'URL signal required';
                                    }
                                    final allValid = urls.every((u) => isValidTransmissionUrl(u));
                                    if (!allValid) {
                                      return isRtl ? 'تأكد من صحة جميع الروابط أو روابط المغناطيس (Magnet)' : 'Ensure all URLs have valid HTTP/HTTPS or Magnet protocol';
                                    }
                                    return null;
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Paste from clipboard button
                              Container(
                                margin: const EdgeInsets.only(top: 4),
                                decoration: BoxDecoration(
                                  color: blueClr.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: blueClr.withValues(alpha: 0.2), width: 0.8),
                                ),
                                child: IconButton(
                                  icon: Icon(Icons.content_paste, color: blueClr, size: 20),
                                  tooltip: isRtl ? 'لصق من الحافظة' : 'Paste from clipboard',
                                  onPressed: () {
                                    triggerHaptic(settings);
                                    _pasteFromClipboard();
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Import Torrent File button
                              Container(
                                margin: const EdgeInsets.only(top: 4),
                                decoration: BoxDecoration(
                                  color: blueClr.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: blueClr.withValues(alpha: 0.2), width: 0.8),
                                ),
                                child: IconButton(
                                  icon: Icon(Icons.file_open_outlined, color: blueClr, size: 20),
                                  tooltip: isRtl ? 'استيراد ملف تورنت' : 'Import .torrent file',
                                  onPressed: () {
                                    triggerHaptic(settings);
                                    _pickTorrentFile(settings);
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (_isResolvingLink)
                            const Center(
                              child: Padding(
                                padding: EdgeInsets.symmetric(vertical: 8.0),
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                            )
                          else
                            Align(
                              alignment: isRtl ? Alignment.centerLeft : Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: _resolveLinkMetadata,
                                icon: Icon(Icons.verified_user_outlined, size: 16, color: blueClr),
                                label: Text(
                                  isRtl ? 'التحقق من الرابط' : 'VERIFY LINK',
                                  style: TextStyle(
                                    color: blueClr,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.0,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildMetadataPanel(context, isDark),

                    // File Configuration Card
                    _buildInputPanel(
                      context,
                      isDark: isDark,
                      title: isRtl ? 'تخصيص مساحة القرص' : 'LOCAL DISK ALLOCATION',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isRtl ? 'اسم ملف مخصص (اختياري)' : 'CUSTOM FILE NAME (OPTIONAL)',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  fontSize: 10,
                                  color: secClr,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _nameController,
                            style: TextStyle(
                              color: textClr,
                              fontSize: 13,
                            ),
                            decoration: _buildInputDecoration(
                              isRtl ? 'اتركه فارغاً للكشف التلقائي' : 'Leave blank to auto-detect name',
                              isDark: isDark,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            isRtl ? 'مسار الحفظ الجذري' : 'DESTINATION ROOT DIRECTORY',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  fontSize: 10,
                                  color: secClr,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _pathController,
                            style: TextStyle(
                              color: textClr,
                              fontSize: 13,
                            ),
                            decoration: _buildInputDecoration(
                              isRtl ? 'مجلد وجهة التخزين المحلي' : 'Local storage destination folder',
                              isDark: isDark,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Configuration Details Selector (Category & Threads)
                    _buildInputPanel(
                      context,
                      isDark: isDark,
                      title: isRtl ? 'إعدادات التوجيه' : 'ROUTING CONFIGURATION',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      isRtl ? 'الفئة' : 'CATEGORY',
                                      style: Theme.of(context).textTheme.labelMedium
                                          ?.copyWith(
                                            fontSize: 10,
                                            color: secClr,
                                            fontWeight: FontWeight.bold,
                                            letterSpacing: 0.5,
                                          ),
                                    ),
                                    const SizedBox(height: 8),
                                    _buildDropdown<String>(
                                      value: _selectedCategory,
                                      items: _categories,
                                      isDark: isDark,
                                      onChanged: (val) {
                                        if (val != null) {
                                          setState(() {
                                            _selectedCategory = val;
                                          });
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      isRtl ? 'القنوات (الخيوط)' : 'CHANNELS (THREADS)',
                                      style: Theme.of(context).textTheme.labelMedium
                                          ?.copyWith(
                                            fontSize: 10,
                                            color: secClr,
                                            fontWeight: FontWeight.bold,
                                            letterSpacing: 0.5,
                                          ),
                                    ),
                                    const SizedBox(height: 8),
                                    _buildDropdown<int>(
                                      value: _selectedThreads,
                                      items: _threadsList,
                                      isDark: isDark,
                                      onChanged: (val) {
                                        if (val != null) {
                                          setState(() {
                                            _selectedThreads = val;
                                          });
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Checkbox(
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
                              Text(
                                isRtl ? 'جدولة الإرسال' : 'SCHEDULE TRANSMISSION',
                                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                  color: textClr,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
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
                                              ? ColorScheme.dark(
                                                  primary: blueClr,
                                                  onPrimary: AppTheme.background,
                                                  surface: AppTheme.surface,
                                                  onSurface: AppTheme.textPrimary,
                                                )
                                              : ColorScheme.light(
                                                  primary: blueClr,
                                                  onPrimary: Colors.white,
                                                  surface: AppTheme.lightSurface,
                                                  onSurface: AppTheme.lightTextPrimary,
                                                ),
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
                                                ? ColorScheme.dark(
                                                    primary: blueClr,
                                                    onPrimary: AppTheme.background,
                                                    surface: AppTheme.surface,
                                                    onSurface: AppTheme.textPrimary,
                                                  )
                                                : ColorScheme.light(
                                                    primary: blueClr,
                                                    onPrimary: Colors.white,
                                                    surface: AppTheme.lightSurface,
                                                    onSurface: AppTheme.lightTextPrimary,
                                                  ),
                                          ),
                                          child: child!,
                                        ),
                                      );
                                      if (time != null) {
                                        setState(() {
                                          _scheduledDateTime = DateTime(
                                            date.year,
                                            date.month,
                                            date.day,
                                            time.hour,
                                            time.minute,
                                          );
                                        });
                                      }
                                    }
                                  },
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Advanced Options Toggle
                    const SizedBox(height: 32),

                    // Submit button
                    Center(
                      child: NeonGlowButton(
                        isExpanded: true,
                        isFilled: true,
                        onPressed: _isSubmitting
                            ? null
                            : () async {
                                triggerHaptic(settings);
                                if (_formKey.currentState!.validate()) {
                                  if (_isMetadataResolved && _torrentFiles.isNotEmpty) {
                                    final hasSelected = _torrentFiles.any((f) => f['selected'] == true);
                                    if (!hasSelected) {
                                      ThemedSnackbar.show(
                                        context,
                                        message: isRtl 
                                            ? 'يجب تحديد ملف واحد على الأقل للتحميل' 
                                            : 'At least one file must be selected for download.',
                                        color: redClr,
                                        icon: Icons.warning_amber_outlined,
                                        isDarkMode: isDark,
                                      );
                                      return;
                                    }
                                  }

                                  final provider = Provider.of<DownloadProvider>(
                                    context,
                                    listen: false,
                                  );
                                  await _handleDuplicateOrSubmit(
                                    context,
                                    provider,
                                    settings,
                                    isDark,
                                    isRtl,
                                  );
                                }
                              },
                        text: _isSubmitting
                            ? (isRtl ? 'جاري حل المصدر...' : 'RESOLVING SOURCE...')
                            : (isRtl ? 'إنشاء اتصال النقل' : 'ESTABLISH TRANSFER CONNECTION'),
                        isLoading: _isSubmitting,
                        icon: Icons.rocket_launch_outlined,
                        color: blueClr,
                        glowColor: blueClr,
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }



  InputDecoration _buildInputDecoration(String hint, {required bool isDark}) {
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final bgClr = isDark ? AppTheme.background : AppTheme.lightBackground;
    final glassBorder = isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;

    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: mutedClr, fontSize: 13),
      filled: true,
      fillColor: bgClr.withValues(alpha: 0.6),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: glassBorder, width: 0.8),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: glassBorder, width: 0.8),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: blueClr, width: 1.0),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: redClr, width: 1.0),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: redClr, width: 1.0),
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
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: glassBorder, width: 0.8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          dropdownColor: surfaceClr,
          value: value,
          isExpanded: true,
          icon: Icon(
            Icons.arrow_drop_down,
            color: secClr,
          ),
          style: TextStyle(
            color: textClr,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
          items: items.map((item) {
            return DropdownMenuItem<T>(
              value: item,
              child: Text(item.toString().toUpperCase()),
            );
          }).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildInputPanel(
    BuildContext context, {
    required String title,
    required Widget child,
    required bool isDark,
  }) {
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    return GlassCard(
      borderRadius: 20,
      padding: const EdgeInsets.all(16),
      isDarkMode: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: secClr,
              fontSize: 9,
              letterSpacing: 1.0,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Future<void> _pickTorrentFile(SettingsProvider settings) async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['torrent'],
      );
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
            // Pre-resolve metadata variables immediately
            _resolvedFileName = meta['name'] ?? '';
            _resolvedFileSize = meta['length'] ?? 0;
            _resolvedCategory = 'Archive';
            _supportsResume = true;
            _torrentFiles = (meta['files'] as List? ?? [])
                .map((f) => {
                      'name': f['name'] as String? ?? '',
                      'length': f['length'] as int? ?? 0,
                      'selected': true,
                      'downloadedBytes': 0,
                      'speed': 0.0,
                    })
                .toList();
            _isMetadataResolved = true;
          });
          if (mounted) {
            ThemedSnackbar.show(
              context,
              message: L10n.isRtl(context)
                  ? 'تم استيراد بيانات التورنت بنجاح'
                  : 'Torrent metadata imported successfully',
              color: AppTheme.neonBlue,
              icon: Icons.check_circle_outline,
              isDarkMode: settings.isDarkMode,
            );
          }
        } else {
          if (mounted) {
            ThemedSnackbar.show(
              context,
              message: L10n.isRtl(context)
                  ? 'فشل في قراءة بيانات ملف التورنت'
                  : 'Failed to decode torrent file metadata',
              color: AppTheme.neonRed,
              icon: Icons.error_outline,
              isDarkMode: settings.isDarkMode,
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ThemedSnackbar.show(
          context,
          message: 'Error importing torrent: $e',
          color: AppTheme.neonRed,
          icon: Icons.error_outline,
          isDarkMode: settings.isDarkMode,
        );
      }
    }
  }

  Future<void> _resolveLinkMetadata() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ThemedSnackbar.show(
        context,
        message: L10n.isRtl(context) ? 'يرجى إدخال الرابط أولاً' : 'Please enter a URL first',
        color: AppTheme.neonRed,
        icon: Icons.error_outline,
        isDarkMode: Provider.of<SettingsProvider>(context, listen: false).isDarkMode,
      );
      return;
    }

    if (!isValidTransmissionUrl(url)) {
      ThemedSnackbar.show(
        context,
        message: L10n.isRtl(context) ? 'رابط غير صالح' : 'Invalid transmission URL',
        color: AppTheme.neonRed,
        icon: Icons.error_outline,
        isDarkMode: Provider.of<SettingsProvider>(context, listen: false).isDarkMode,
      );
      return;
    }

    setState(() {
      _isResolvingLink = true;
      _isMetadataResolved = false;
      _torrentFiles = [];
    });

    try {
      final settings = Provider.of<SettingsProvider>(context, listen: false);
      
      // If it's a local torrent file url (file://), handle it
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
              _torrentFiles = (meta['files'] as List? ?? [])
                  .map((f) => {
                        'name': f['name'] as String? ?? '',
                        'length': f['length'] as int? ?? 0,
                        'selected': true,
                        'downloadedBytes': 0,
                        'speed': 0.0,
                      })
                  .toList();
              _isMetadataResolved = true;
              
              _nameController.text = _resolvedFileName;
              _selectedCategory = 'Archive';
            });
            return;
          }
        }
      }

      // Otherwise resolve metadata from network
      final engine = DownloadEngine();
      final meta = await engine.resolveMetadata(
        url: url,
        requestedFileName: _nameController.text.trim().isNotEmpty ? _nameController.text.trim() : null,
        customUserAgent: settings.customUserAgent,
        enableProxy: settings.enableProxy,
        proxyAddress: settings.proxyAddress,
        bypassSSL: settings.bypassSSL,
      );

      setState(() {
        _resolvedFileName = meta.fileName;
        _resolvedFileSize = meta.fileSize;
        _resolvedCategory = meta.category;
        _supportsResume = meta.supportsResume;
        _torrentFiles = meta.torrentFiles ?? [];
        _isMetadataResolved = true;
        
        // Update the form inputs to prefill if appropriate
        _nameController.text = _resolvedFileName;
        if (_categories.contains(_resolvedCategory)) {
          _selectedCategory = _resolvedCategory;
        }
      });
    } catch (e) {
      if (mounted) {
        ThemedSnackbar.show(
          context,
          message: 'Error resolving link metadata: $e',
          color: AppTheme.neonRed,
          icon: Icons.error_outline,
          isDarkMode: Provider.of<SettingsProvider>(context, listen: false).isDarkMode,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isResolvingLink = false;
        });
      }
    }
  }

  Widget _buildMetadataPanel(BuildContext context, bool isDark) {
    if (!_isMetadataResolved) return const SizedBox.shrink();

    final isRtl = L10n.isRtl(context);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final glassBorder = isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;

    IconData categoryIcon;
    switch (_resolvedCategory) {
      case 'Video':
        categoryIcon = Icons.movie_outlined;
        break;
      case 'Audio':
        categoryIcon = Icons.audiotrack_outlined;
        break;
      case 'Document':
        categoryIcon = Icons.description_outlined;
        break;
      case 'Archive':
        categoryIcon = Icons.folder_zip_outlined;
        break;
      case 'APK':
        categoryIcon = Icons.android_outlined;
        break;
      default:
        categoryIcon = Icons.insert_drive_file_outlined;
    }

    return Column(
      children: [
        _buildInputPanel(
          context,
          isDark: isDark,
          title: isRtl ? 'بيانات النقل المؤكدة' : 'VERIFIED TRANSMISSION METADATA',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue).withValues(alpha: 0.2),
                        width: 0.8,
                      ),
                    ),
                    child: Icon(
                      categoryIcon,
                      color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _resolvedFileName,
                          style: TextStyle(
                            color: textClr,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text(
                              formatBytes(_resolvedFileSize),
                              style: TextStyle(
                                color: textClr,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Icon(
                              _supportsResume ? Icons.check_circle_outline : Icons.error_outline,
                              color: _supportsResume ? greenClr : redClr,
                              size: 12,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _supportsResume 
                                  ? (isRtl ? 'يدعم الاستكمال' : 'Resume Supported') 
                                  : (isRtl ? 'لا يدعم الاستكمال' : 'No Resume Support'),
                              style: TextStyle(
                                color: _supportsResume ? greenClr : redClr,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (_torrentFiles.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Divider(height: 1, thickness: 0.5),
                const SizedBox(height: 12),
                Text(
                  isRtl ? 'الملفات المضمنة (${_torrentFiles.length})' : 'INCLUDED FILES (${_torrentFiles.length})',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: secClr,
                    fontSize: 9,
                    letterSpacing: 0.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 150),
                  decoration: BoxDecoration(
                    color: (isDark ? AppTheme.background : AppTheme.lightBackground).withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: glassBorder, width: 0.6),
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                    itemCount: _torrentFiles.length,
                    separatorBuilder: (context, index) => const Divider(height: 10, thickness: 0.3),
                    itemBuilder: (context, index) {
                      final f = _torrentFiles[index];
                      final name = f['name'] as String? ?? 'unknown';
                      final length = f['length'] as int? ?? 0;
                      final selected = f['selected'] as bool? ?? true;
                      final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
                      return Row(
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: Checkbox(
                              value: selected,
                              activeColor: blueClr,
                              side: BorderSide(color: glassBorder, width: 0.8),
                              onChanged: (val) {
                                if (val != null) {
                                  setState(() {
                                    _torrentFiles[index] = {
                                      ...f,
                                      'selected': val,
                                    };
                                    // Recalculate total size
                                    final totalSize = _torrentFiles
                                        .where((file) => file['selected'] == true)
                                        .fold(0, (sum, file) => sum + (file['length'] as int));
                                    _resolvedFileSize = totalSize;
                                  });
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.insert_drive_file_outlined,
                            size: 14,
                            color: selected ? textClr : secClr,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              name,
                              style: TextStyle(
                                color: selected ? textClr : secClr,
                                fontSize: 11,
                                decoration: selected ? null : TextDecoration.lineThrough,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            formatBytes(length),
                            style: TextStyle(
                              color: selected ? secClr : secClr.withValues(alpha: 0.5),
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Future<void> _handleDuplicateOrSubmit(
    BuildContext context,
    DownloadProvider provider,
    SettingsProvider settings,
    bool isDark,
    bool isRtl,
  ) async {
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    final enteredName = _nameController.text.trim();
    final finalFileName = enteredName.isNotEmpty
        ? safeFileName(enteredName)
        : fileNameFromUrl(_urlController.text.trim());
    final int finalSize = _isMetadataResolved ? _resolvedFileSize : 0;

    DownloadTask? duplicateTask;
    if (finalSize > 0) {
      for (final task in provider.tasks) {
        if (task.fileName.toLowerCase() == finalFileName.toLowerCase() &&
            task.fileSize == finalSize) {
          duplicateTask = task;
          break;
        }
      }
    }

    if (duplicateTask != null) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return AlertDialog(
            backgroundColor: isDark ? AppTheme.surface : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
              ),
            ),
            title: Text(
              isRtl ? 'ملف مكرر مكتشف' : 'DUPLICATE FILE DETECTED',
              style: TextStyle(
                color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            content: Text(
              isRtl
                  ? 'يوجد بالفعل ملف بنفس الاسم والحجم في قائمة التحميل. يرجى اختيار إجراء:'
                  : 'A file with the same name and size is already in the download list. Please select an action:',
              style: TextStyle(
                color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                fontSize: 13,
              ),
            ),
            actionsAlignment: MainAxisAlignment.center,
            actionsOverflowButtonSpacing: 8,
            actions: [
              // Option 1: Update Link
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDark ? AppTheme.neonBlue.withValues(alpha: 0.1) : AppTheme.lightNeonBlue.withValues(alpha: 0.05),
                  side: BorderSide(color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () async {
                  triggerHaptic(settings);
                  Navigator.pop(context);
                  setState(() => _isSubmitting = true);
                  try {
                    await provider.updateTaskUrlAndResume(duplicateTask!.id, _urlController.text.trim());
                    if (mounted) {
                      setState(() => _isSubmitting = false);
                      ThemedSnackbar.show(
                        context,
                        message: isRtl ? 'تم تحديث رابط الملف واستئنافه' : 'File link updated and download resumed.',
                        color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                        icon: Icons.check_circle_outline,
                        isDarkMode: isDark,
                      );
                      Navigator.pop(context); // Close AddScreen
                    }
                  } catch (e) {
                    if (mounted) {
                      setState(() => _isSubmitting = false);
                      ThemedSnackbar.show(
                        context,
                        message: e.toString(),
                        color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                        icon: Icons.error_outline,
                        isDarkMode: isDark,
                      );
                    }
                  }
                },
                child: Text(
                  isRtl ? 'تحديث الرابط والاستئناف' : 'UPDATE LINK & RESUME',
                  style: TextStyle(color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue, fontWeight: FontWeight.bold, fontSize: 11),
                ),
              ),

              // Option 2: Start Over
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDark ? AppTheme.neonViolet.withValues(alpha: 0.1) : AppTheme.lightNeonViolet.withValues(alpha: 0.05),
                  side: BorderSide(color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () async {
                  triggerHaptic(settings);
                  Navigator.pop(context);
                  setState(() => _isSubmitting = true);
                  try {
                    await provider.startOverTask(duplicateTask!.id, _urlController.text.trim());
                    if (mounted) {
                      setState(() => _isSubmitting = false);
                      ThemedSnackbar.show(
                        context,
                        message: isRtl ? 'بدأ التحميل من جديد' : 'Download started over from scratch.',
                        color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                        icon: Icons.refresh,
                        isDarkMode: isDark,
                      );
                      Navigator.pop(context); // Close AddScreen
                    }
                  } catch (e) {
                    if (mounted) {
                      setState(() => _isSubmitting = false);
                      ThemedSnackbar.show(
                        context,
                        message: e.toString(),
                        color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                        icon: Icons.error_outline,
                        isDarkMode: isDark,
                      );
                    }
                  }
                },
                child: Text(
                  isRtl ? 'بدء من جديد' : 'START OVER',
                  style: TextStyle(color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet, fontWeight: FontWeight.bold, fontSize: 11),
                ),
              ),

              // Option 3: Add Another (Numbered)
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDark ? AppTheme.neonGreen.withValues(alpha: 0.1) : AppTheme.lightNeonGreen.withValues(alpha: 0.05),
                  side: BorderSide(color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () async {
                  triggerHaptic(settings);
                  Navigator.pop(context);
                  setState(() => _isSubmitting = true);

                  // Find a unique numbered filename
                  String numberedName = finalFileName;
                  final ext = p.extension(finalFileName);
                  final base = p.basenameWithoutExtension(finalFileName);
                  var counter = 1;
                  while (true) {
                    final candidate = '${base}_$counter$ext';
                    final exists = provider.tasks.any((t) => t.fileName.toLowerCase() == candidate.toLowerCase());
                    if (!exists) {
                      numberedName = candidate;
                      break;
                    }
                    counter++;
                  }

                  try {
                    await provider.addDownload(
                      name: numberedName,
                      url: _urlController.text.trim(),
                      size: finalSize,
                      category: _selectedCategory == 'Auto' ? '' : _selectedCategory,
                      savePath: _pathController.text.trim(),
                      threadCount: _selectedThreads,
                      scheduledAt: _isScheduled ? _scheduledDateTime : null,
                      torrentFiles: _torrentFiles.isNotEmpty ? _torrentFiles : null,
                    );
                    if (mounted) {
                      setState(() => _isSubmitting = false);
                      Navigator.pop(context); // Close AddScreen
                    }
                  } catch (e) {
                    if (mounted) {
                      setState(() => _isSubmitting = false);
                      ThemedSnackbar.show(
                        context,
                        message: e.toString(),
                        color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                        icon: Icons.error_outline,
                        isDarkMode: isDark,
                      );
                    }
                  }
                },
                child: Text(
                  isRtl ? 'إضافة كملف مرقم جديد' : 'ADD NUMBERED FILE',
                  style: TextStyle(color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen, fontWeight: FontWeight.bold, fontSize: 11),
                ),
              ),

              // Option 4: Cancel
              TextButton(
                onPressed: () {
                  triggerHaptic(settings);
                  Navigator.pop(context);
                },
                child: Text(
                  L10n.of(context, 'cancel_btn'),
                  style: TextStyle(color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted),
                ),
              ),
            ],
          );
        },
      );
    } else {
      // Normal submission
      setState(() => _isSubmitting = true);
      await provider.addDownload(
        name: enteredName,
        url: _urlController.text.trim(),
        size: finalSize,
        category: _selectedCategory == 'Auto' ? '' : _selectedCategory,
        savePath: _pathController.text.trim(),
        threadCount: _selectedThreads,
        scheduledAt: _isScheduled ? _scheduledDateTime : null,
        torrentFiles: _torrentFiles.isNotEmpty ? _torrentFiles : null,
      );
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      if (provider.lastError != null) {
        ThemedSnackbar.show(
          context,
          message: provider.lastError!,
          color: redClr,
          icon: Icons.error_outline,
          isDarkMode: isDark,
        );
        return;
      }
      ThemedSnackbar.show(
        context,
        message: isRtl
            ? 'تم إنشاء الاتصال. القنوات متصلة.'
            : 'TRANSMISSION ESTABLISHED. CHANNELS CONNECTED.',
        color: blueClr,
        icon: Icons.rocket_launch_outlined,
        isDarkMode: isDark,
      );
      Navigator.pop(context);
    }
  }
}
