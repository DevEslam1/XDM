import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/services/app_lock_service.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_design.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../provider/settings_provider.dart';

/// Screen for entering or setting up PIN lock.
class AppLockScreen extends StatefulWidget {
  final bool isSettingUp;
  final VoidCallback? onUnlocked;

  const AppLockScreen({
    super.key,
    this.isSettingUp = false,
    this.onUnlocked,
  });

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final TextEditingController _pinController = TextEditingController();
  Timer? _lockoutTimer;
  String? _errorMessage;
  int _remainingSeconds = 0;

  bool get _isLockedOut => _remainingSeconds > 0;

  @override
  void initState() {
    super.initState();
    if (!widget.isSettingUp) _refreshLockout();
  }

  @override
  void dispose() {
    _lockoutTimer?.cancel();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _refreshLockout() async {
    final remaining = await AppLockService.lockoutRemaining();
    if (!mounted) return;
    _lockoutTimer?.cancel();
    final seconds = remaining.inSeconds.ceil();
    setState(() {
      _remainingSeconds = seconds;
      if (seconds > 0) {
        _errorMessage = null;
      }
    });
    if (seconds > 0) {
      _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        _refreshLockout();
      });
    }
  }

  Future<void> _handleSubmit() async {
    if (_isLockedOut) return;
    final pin = _pinController.text.trim();
    if (pin.length < 4) {
      setState(() => _errorMessage = 'PIN must be at least 4 digits');
      return;
    }

    if (widget.isSettingUp) {
      await AppLockService.setPin(pin);
      if (!mounted) return;
      ThemedSnackbar.show(
        context,
        message: L10n.of(context, 'security_pin_set'),
        color: AppTheme.neonGreen,
        icon: Icons.check_circle_outline,
      );
      Navigator.of(context).pop();
      return;
    }

    final isValid = await AppLockService.verifyPin(pin);
    if (!mounted) return;
    if (isValid) {
      if (widget.onUnlocked != null) {
        widget.onUnlocked!();
      } else {
        Navigator.of(context).pop();
      }
      return;
    }

    _pinController.clear();
    await _refreshLockout();
    if (!mounted || _isLockedOut) return;
    setState(() => _errorMessage = 'Incorrect PIN. Please try again.');
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<SettingsProvider>().isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;

    final screen = GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(
            (widget.isSettingUp ? 'Set Security PIN' : 'Enter PIN').toUpperCase(),
            style: TextStyle(
              fontFamily: 'Space Grotesk',
              fontWeight: FontWeight.bold,
              fontSize: 14,
              letterSpacing: 1.5,
              color: textClr,
            ),
          ),
          centerTitle: true,
        ),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: DmxCardShell(
                accent: accent,
                radius: 20,
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: accent.withValues(alpha: 0.12),
                        ),
                        child: Icon(
                          Icons.lock_rounded,
                          size: 40,
                          color: accent,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        widget.isSettingUp
                            ? 'Enter a 4 to 6 digit PIN to secure XDM'
                            : 'Enter your Security PIN to unlock',
                        style: TextStyle(
                          fontFamily: 'Space Grotesk',
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: textClr,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _pinController,
                        enabled: !_isLockedOut,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        obscureText: true,
                        maxLength: 6,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 22,
                          letterSpacing: 8,
                          color: textClr,
                          fontFamily: 'Space Grotesk',
                        ),
                        decoration: InputDecoration(
                          counterText: '',
                          errorText: _isLockedOut
                              ? 'Too many attempts. Try again in ${_remainingSeconds}s.'
                              : _errorMessage,
                          filled: true,
                          fillColor: AppTheme.panelBg(isDark),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle,
                            ),
                          ),
                        ),
                        onSubmitted: (_) => _handleSubmit(),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: DmxButton.filled(
                          label: widget.isSettingUp ? 'Save PIN' : 'Unlock',
                          onPressed: _isLockedOut ? null : _handleSubmit,
                          color: accent,
                        ),
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

    return widget.isSettingUp
        ? screen
        : PopScope(canPop: false, child: screen);
  }
}