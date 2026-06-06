import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import '../../../../core/app_theme.dart';
import '../../../../shared/widgets/geometric_grid_background.dart';
import '../../../../shared/widgets/dmx_app_icon.dart';
import '../../../../shared/widgets/neon_glow_button.dart';

class BiometricLockScreen extends StatefulWidget {
  final bool isDark;
  final bool isRtl;
  const BiometricLockScreen({super.key, required this.isDark, required this.isRtl});

  @override
  State<BiometricLockScreen> createState() => _BiometricLockScreenState();
}

class _BiometricLockScreenState extends State<BiometricLockScreen> {
  final LocalAuthentication _auth = LocalAuthentication();
  bool _authFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _authenticate();
    });
  }

  Future<void> _authenticate() async {
    try {
      final bool canCheck = await _auth.canCheckBiometrics;
      final bool isSupported = await _auth.isDeviceSupported();
      if (canCheck || isSupported) {
        final bool didAuth = await _auth.authenticate(
          localizedReason: widget.isRtl
              ? 'يرجى تأكيد هويتك لفتح لوحة قيادة XDM'
              : 'Please authenticate to open XDM dashboard',
          persistAcrossBackgrounding: true,
        );
        if (didAuth && mounted) {
          Navigator.pop(context, true);
        } else {
          if (mounted) {
            setState(() {
              _authFailed = true;
            });
          }
        }
      } else {
        // Device genuinely has no biometrics/hardware support; let the user
        // through. This is an intentional device-level decision, not a
        // catch-all error path.
        if (mounted) {
          Navigator.pop(context, true);
        }
      }
    } catch (e) {
      // Don't auto-grant access on a plugin/runtime error: the lock is
      // supposed to be enforced. Show the retry state so the user can try
      // again, or back out to the OS lock screen.
      if (mounted) {
        setState(() {
          _authFailed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final textClr = widget.isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final alertClr = widget.isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: widget.isDark ? AppTheme.background : AppTheme.lightBackground,
        body: GeometricGridBackground(
          child: Center(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(28.0),
                child: Container(
                  decoration: AppTheme.glassAccentDecoration(
                    accentColor: alertClr,
                    isDark: widget.isDark,
                    borderRadius: 24.0,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 40.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DmxAppIcon(
                        size: 80,
                        customColor: alertClr,
                        showGlow: true,
                      ),
                      const SizedBox(height: 32),
                      Text(
                        widget.isRtl ? 'تم قفل الاتصال' : 'TRANSMISSION LOCKED',
                        style: TextStyle(
                          color: textClr,
                          fontFamily: 'Space Grotesk',
                          fontWeight: FontWeight.bold,
                          fontSize: 20,
                          letterSpacing: 2.0,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _authFailed
                            ? (widget.isRtl
                                ? 'فشل التحقق من الهوية. يرجى المحاولة مرة أخرى.'
                                : 'IDENTITY VERIFICATION FAILED. PLEASE TRY AGAIN.')
                            : (widget.isRtl
                                ? 'قفل بيومتري آمن نشط. يرجى التحقق من الهوية للمتابعة.'
                                : 'SECURE BIOMETRIC GATE ACTIVE. AUTHENTICATE TO RESUME.'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: widget.isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 40),
                      NeonGlowButton(
                        isFilled: true,
                        color: alertClr,
                        onPressed: _authenticate,
                        text: widget.isRtl ? 'إعادة التحقق' : 'RETRY VERIFICATION',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
