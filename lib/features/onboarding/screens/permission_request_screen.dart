import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/main_navigation_container.dart';
import '../../settings/provider/settings_provider.dart';

class PermissionRequestScreen extends StatefulWidget {
  const PermissionRequestScreen({super.key});

  @override
  State<PermissionRequestScreen> createState() =>
      _PermissionRequestScreenState();
}

class _PermissionRequestScreenState extends State<PermissionRequestScreen>
    with WidgetsBindingObserver {
  final PermissionService _permissionService = PermissionService();
  bool _storageGranted = false;
  bool _storageOpening = false;
  bool _storagePermanentlyDenied = false;
  bool _notificationsGranted = false;
  bool _notificationsOpening = false;
  bool _notificationsPermanentlyDenied = false;
  bool _batteryGranted = false;
  bool _isNavigating = false;
  bool _batteryOpening = false;
  String? _downloadPath;
  bool _isPickingPath = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb || !Platform.isAndroid) {
      _storageGranted = true;
      _notificationsGranted = true;
      _batteryGranted = true;
    }
    _loadDownloadPath();
    if (!kIsWeb && Platform.isAndroid) {
      WidgetsBinding.instance.addObserver(this);
    }
  }

  Future<void> _loadDownloadPath() async {
    final settings = context.read<SettingsProvider>();
    if (settings.customDownloadPath?.isNotEmpty == true) {
      _downloadPath = settings.customDownloadPath;
    } else if (_isAndroidPlatform()) {
      // On Android the calculated default may resolve to the app-private
      // Android/data folder — force the user to explicitly pick a folder
      // instead of silently accepting a wrong default.
      _downloadPath = null;
    } else {
      _downloadPath = await _permissionService.defaultDownloadDirectory();
    }
    if (mounted) setState(() {});
  }

  /// On Android the user must explicitly choose a download folder before
  /// continuing, so files never land in the app-private Android/data path.
  bool get _folderChosen =>
      !_isAndroidPlatform() || (_downloadPath?.isNotEmpty ?? false);

  Future<void> _pickDownloadPath() async {
    if (_isPickingPath) return;
    setState(() => _isPickingPath = true);
    try {
      final dialogTitle = L10n.of(
        context,
        'permission_download_location_title',
      );
      final settingsProvider = context.read<SettingsProvider>();
      String? initialDir;
      if (!kIsWeb && Platform.isAndroid) {
        initialDir = '/storage/emulated/0/Download';
      } else {
        final dl = await getDownloadsDirectory();
        initialDir = dl?.path;
      }
      final result = await FilePicker.getDirectoryPath(
        dialogTitle: dialogTitle,
        initialDirectory: initialDir,
      );
      if (result != null && mounted) {
        final xdmPath = result;
        final xdmDir = Directory(xdmPath);
        if (!await xdmDir.exists()) {
          await xdmDir.create(recursive: true);
        }
        await settingsProvider.setCustomDownloadPath(xdmPath);
        if (mounted) setState(() => _downloadPath = xdmPath);
      }
    } catch (e) {
      debugPrint('[PermissionScreen] Pick download path failed: $e');
    } finally {
      if (mounted) setState(() => _isPickingPath = false);
    }
  }

  @override
  void dispose() {
    if (!kIsWeb && Platform.isAndroid) {
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAllPermissions();
    }
  }

  Future<void> _checkAllPermissions() async {
    if (!_isAndroidPlatform()) return;
    final storageGranted =
        (await Permission.storage.isGranted) ||
        (await Permission.photos.isGranted &&
            await Permission.videos.isGranted &&
            await Permission.audio.isGranted);
    final notificationsGranted = await Permission.notification.isGranted;
    final batteryGranted = await _permissionService
        .isBatteryOptimizationExempt();

    final storagePermanentlyDenied = await _permissionService
        .isStoragePermanentlyDenied();
    final notificationsPermanentlyDenied =
        await Permission.notification.isPermanentlyDenied;

    if (mounted) {
      setState(() {
        _storageGranted = storageGranted;
        _notificationsGranted = notificationsGranted;
        _batteryGranted = batteryGranted;
        _storagePermanentlyDenied = storagePermanentlyDenied;
        _notificationsPermanentlyDenied = notificationsPermanentlyDenied;
      });
    }
  }

  static bool _isAndroidPlatform() {
    return !kIsWeb && Platform.isAndroid;
  }

  Future<void> _requestStorage() async {
    if (_storageOpening || !_isAndroidPlatform()) return;
    setState(() {
      _storageOpening = true;
    });
    try {
      final isPermanentlyDenied = await _permissionService
          .isStoragePermanentlyDenied();
      if (isPermanentlyDenied) {
        setState(() => _storagePermanentlyDenied = true);
        await openAppSettings();
      } else {
        final granted = await _permissionService.ensureStorageAccess();
        if (mounted) {
          setState(() {
            _storageGranted = granted;
            if (!granted) {
              _permissionService.isStoragePermanentlyDenied().then((denied) {
                if (mounted) setState(() => _storagePermanentlyDenied = denied);
              });
            }
          });
        }
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _storageOpening = false);
    }
  }

  Future<void> _requestNotifications() async {
    if (_notificationsOpening || !_isAndroidPlatform()) return;
    setState(() {
      _notificationsOpening = true;
    });
    try {
      final isPermanentlyDenied =
          await Permission.notification.isPermanentlyDenied;
      if (isPermanentlyDenied) {
        setState(() => _notificationsPermanentlyDenied = true);
        await openAppSettings();
      } else {
        final granted = await NotificationService()
            .requestNotificationPermission();
        if (mounted) {
          setState(() {
            _notificationsGranted = granted;
            if (!granted) {
              Permission.notification.isPermanentlyDenied.then((denied) {
                if (mounted) {
                  setState(() => _notificationsPermanentlyDenied = denied);
                }
              });
            }
          });
        }
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _notificationsOpening = false);
    }
  }

  Future<void> _requestBattery() async {
    if (_batteryOpening || !_isAndroidPlatform()) return;
    setState(() {
      _batteryOpening = true;
    });
    try {
      final granted = await _permissionService
          .requestBatteryOptimizationExemption();
      if (mounted) {
        setState(() {
          _batteryGranted = granted;
        });
      }
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() {
          _batteryOpening = false;
        });
      }
    }
  }

  void _continueToApp() {
    if (_isNavigating || !_folderChosen) return;
    _isNavigating = true;
    if (context.read<SettingsProvider>().vibration) {
      HapticFeedback.mediumImpact();
    }
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainNavigationContainer()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final secClr = isDark
        ? AppTheme.textSecondary
        : AppTheme.lightTextSecondary;

    return GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Directionality(
          textDirection: L10n.isRtl(context)
              ? TextDirection.rtl
              : TextDirection.ltr,
          child: SafeArea(
            child: Column(
              children: [
                const Spacer(flex: 1),
                // Title
                Text(
                  L10n.of(context, 'permission_title'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.textPrimary
                        : AppTheme.lightTextPrimary,
                    fontFamily: 'Space Grotesk',
                    fontWeight: FontWeight.bold,
                    fontSize: 26,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  L10n.of(context, 'permission_subtitle'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: secClr, fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: 40),

                // Permission cards
                _PermissionCard(
                  icon: Icons.folder_outlined,
                  title: L10n.of(context, 'permission_storage_title'),
                  description: L10n.of(context, 'permission_storage_desc'),
                  isLoading: _storageOpening,
                  isGranted: _storageGranted,
                  isPermanentlyDenied: _storagePermanentlyDenied,
                  onRequest: _requestStorage,
                  accentColor: isDark
                      ? AppTheme.neonBlue
                      : AppTheme.lightNeonBlue,
                  isDark: isDark,
                ),
                const SizedBox(height: 12),
                _PermissionCard(
                  icon: Icons.notifications_outlined,
                  title: L10n.of(context, 'permission_notifications_title'),
                  description: L10n.of(
                    context,
                    'permission_notifications_desc',
                  ),
                  isLoading: _notificationsOpening,
                  isGranted: _notificationsGranted,
                  isPermanentlyDenied: _notificationsPermanentlyDenied,
                  onRequest: _requestNotifications,
                  accentColor: isDark
                      ? AppTheme.neonViolet
                      : AppTheme.lightNeonViolet,
                  isDark: isDark,
                ),
                const SizedBox(height: 12),
                _PermissionCard(
                  icon: Icons.battery_std_outlined,
                  title: L10n.of(context, 'permission_battery_title'),
                  description: _batteryOpening
                      ? L10n.of(context, 'permission_battery_opening')
                      : L10n.of(context, 'permission_battery_desc'),
                  isLoading: _batteryOpening,
                  isGranted: _batteryGranted,
                  isPermanentlyDenied: false,
                  onRequest: _requestBattery,
                  accentColor: isDark
                      ? AppTheme.neonAmber
                      : AppTheme.lightNeonAmber,
                  isDark: isDark,
                ),
                const SizedBox(height: 12),
                _DownloadLocationCard(
                  path: _downloadPath,
                  isPicking: _isPickingPath,
                  onPick: _pickDownloadPath,
                  isDark: isDark,
                ),

                const Spacer(flex: 1),

                // Continue button
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                  child: Column(
                    children: [
                      if (!_folderChosen) ...[
                        Text(
                          L10n.of(
                            context,
                            'permission_download_location_required',
                          ),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isDark
                                ? AppTheme.neonAmber
                                : AppTheme.lightNeonAmber,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton(
                          onPressed: _folderChosen ? _continueToApp : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isDark
                                ? AppTheme.neonBlue
                                : AppTheme.lightNeonBlue,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor:
                                (isDark
                                        ? AppTheme.neonBlue
                                        : AppTheme.lightNeonBlue)
                                    .withValues(alpha: 0.3),
                            disabledForegroundColor: Colors.white70,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            elevation: 0,
                          ),
                          child: Text(
                            L10n.of(context, 'permission_continue'),
                            style: const TextStyle(
                              fontFamily: 'Space Grotesk',
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool isLoading;
  final bool isGranted;
  final bool isPermanentlyDenied;
  final VoidCallback onRequest;
  final Color accentColor;
  final bool isDark;

  const _PermissionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.isLoading,
    required this.isGranted,
    required this.isPermanentlyDenied,
    required this.onRequest,
    required this.accentColor,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final bgClr = isDark ? AppTheme.cardBg : AppTheme.lightCardBg;
    final txtClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr = isDark
        ? AppTheme.textSecondary
        : AppTheme.lightTextSecondary;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: bgClr,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isGranted
              ? (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
              : (isDark ? AppTheme.border : AppTheme.lightBorder),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: accentColor, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: txtClr,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: TextStyle(color: secClr, fontSize: 12, height: 1.3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (isGranted)
            Icon(
              Icons.check_circle,
              color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
              size: 24,
            )
          else if (isLoading)
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: accentColor,
              ),
            )
          else
            SizedBox(
              height: 34,
              child: ElevatedButton(
                onPressed: onRequest,
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  elevation: 0,
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: Text(
                  isPermanentlyDenied
                      ? (L10n.isRtl(context)
                            ? 'مرفوض — فتح الإعدادات'
                            : 'Denied — Open Settings')
                      : L10n.of(context, 'permission_allow'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DownloadLocationCard extends StatelessWidget {
  final String? path;
  final bool isPicking;
  final VoidCallback onPick;
  final bool isDark;

  const _DownloadLocationCard({
    required this.path,
    required this.isPicking,
    required this.onPick,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final bgClr = isDark ? AppTheme.cardBg : AppTheme.lightCardBg;
    final txtClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr = isDark
        ? AppTheme.textSecondary
        : AppTheme.lightTextSecondary;
    final accentColor = isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan;

    final shortPath = path != null ? _shortenPath(path!) : null;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: bgClr,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: path != null
              ? (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
              : (isDark ? AppTheme.border : AppTheme.lightBorder),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.folder_open, size: 22, color: accentColor),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  L10n.of(context, 'permission_download_location_title'),
                  style: TextStyle(
                    color: txtClr,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  shortPath ??
                      L10n.of(context, 'permission_download_location_desc'),
                  style: TextStyle(color: secClr, fontSize: 12, height: 1.3),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (isPicking)
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: accentColor,
              ),
            )
          else
            SizedBox(
              height: 34,
              child: ElevatedButton(
                onPressed: onPick,
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  elevation: 0,
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: Text(
                  path != null
                      ? L10n.of(context, 'permission_download_location_change')
                      : L10n.of(context, 'permission_download_location_button'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _shortenPath(String fullPath) {
    final parts = fullPath.replaceAll('\\', '/').split('/');
    if (parts.length <= 3) return fullPath;
    final last = parts.sublist(parts.length - 2).join('/');
    final first = parts.first;
    return '$first/…/$last';
  }
}
