import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import '../../../core/app_theme.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/url_utils.dart';
import '../../../core/utils/bencode_decoder.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../core/utils/haptic_helper.dart';

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

  final List<String> _categories = [
    'Auto',
    'Video',
    'Audio',
    'Document',
    'Archive',
    'APK',
    'Other',
  ];
  final List<int> _threadsList = [1, 2, 4, 5, 8, 16];

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
    final path = await PermissionService().defaultDownloadDirectory();
    if (!mounted) return;
    _pathController.text = path;
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
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

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
                                  setState(() => _isSubmitting = true);
                                  final provider = Provider.of<DownloadProvider>(
                                    context,
                                    listen: false,
                                  );
                                   await provider.addDownload(
                                     name: _nameController.text.trim(),
                                     url: _urlController.text.trim(),
                                     size: 0,
                                     category: _selectedCategory == 'Auto'
                                         ? ''
                                         : _selectedCategory,
                                     savePath: _pathController.text.trim(),
                                     threadCount: _selectedThreads,
                                     scheduledAt: _isScheduled ? _scheduledDateTime : null,
                                   );
                                  if (!context.mounted) return;
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
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['torrent'],
      );
      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        final file = File(filePath);
        final bytes = await file.readAsBytes();
        final meta = BencodeDecoder.parseTorrentBytes(bytes);
        if (meta != null) {
          setState(() {
            _urlController.text = 'file://$filePath';
            _nameController.text = meta['name'] ?? '';
            _selectedCategory = 'Archive';
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
}
