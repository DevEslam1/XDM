import 'package:flutter/material.dart';
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
  String? _errorMessage;

  Future<void> _handleSubmit() async {
    final pin = _pinController.text.trim();
    if (pin.length < 4) {
      setState(() {
        _errorMessage = 'PIN must be at least 4 digits';
      });
      return;
    }

    if (widget.isSettingUp) {
      await AppLockService.setPin(pin);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Security PIN set successfully')),
        );
        Navigator.of(context).pop();
      }
    } else {
      final isValid = await AppLockService.verifyPin(pin);
      if (isValid) {
        if (widget.onUnlocked != null) {
          widget.onUnlocked!();
        } else if (mounted) {
          Navigator.of(context).pop();
        }
      } else {
        setState(() {
          _errorMessage = 'Incorrect PIN. Please try again.';
          _pinController.clear();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
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
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, letterSpacing: 8),
              decoration: InputDecoration(
                counterText: '',
                errorText: _errorMessage,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onSubmitted: (_) => _handleSubmit(),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _handleSubmit,
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
  }
}
