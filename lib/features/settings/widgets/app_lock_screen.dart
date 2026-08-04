import 'dart:async';

import 'package:dmx/core/utils/localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/services/app_lock_service.dart';

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context, 'security_pin_set'))),
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
    final theme = Theme.of(context);
    final screen = Scaffold(
      appBar: AppBar(
        title: Text(widget.isSettingUp ? 'Set Security PIN' : 'Enter PIN'),
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.lock_rounded,
              size: 64,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              widget.isSettingUp
                  ? 'Enter a 4-digit PIN to secure XDM'
                  : 'Enter your Security PIN to unlock',
              style: theme.textTheme.titleMedium,
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
              style: const TextStyle(fontSize: 24, letterSpacing: 8),
              decoration: InputDecoration(
                counterText: '',
                errorText: _isLockedOut
                    ? 'Too many attempts. Try again in ${_remainingSeconds}s.'
                    : _errorMessage,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onSubmitted: (_) => _handleSubmit(),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _isLockedOut ? null : _handleSubmit,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(widget.isSettingUp ? 'Save PIN' : 'Unlock'),
            ),
          ],
        ),
      ),
    );

    return widget.isSettingUp
        ? screen
        : PopScope(canPop: false, child: screen);
  }
}