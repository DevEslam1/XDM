import 'dart:async';

import 'package:dmx/shared/design/dmx_design.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

enum ScheduleRepeat {
  none,
  daily,
  weekly,
}

class SchedulePickerWidget extends StatefulWidget {
  const SchedulePickerWidget({
    super.key,
    this.initialDateTime,
    this.initialRepeat = ScheduleRepeat.none,
    required this.onScheduled,
    this.onCancelSchedule,
  });

  final DateTime? initialDateTime;
  final ScheduleRepeat initialRepeat;
  final Function(DateTime scheduledTime, ScheduleRepeat repeat) onScheduled;
  final VoidCallback? onCancelSchedule;

  @override
  State<SchedulePickerWidget> createState() => _SchedulePickerWidgetState();
}

class _SchedulePickerWidgetState extends State<SchedulePickerWidget> {
  late DateTime _selectedDateTime;
  late ScheduleRepeat _selectedRepeat;
  Timer? _countdownTimer;
  Duration _remaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    _selectedDateTime =
        widget.initialDateTime ?? DateTime.now().add(const Duration(hours: 1));
    _selectedRepeat = widget.initialRepeat;
    _updateRemaining();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateRemaining();
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _updateRemaining() {
    if (mounted) {
      final diff = _selectedDateTime.difference(DateTime.now());
      setState(() {
        _remaining = diff.isNegative ? Duration.zero : diff;
      });
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _selectedDateTime.isBefore(now) ? now : _selectedDateTime,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );

    if (pickedDate != null) {
      setState(() {
        _selectedDateTime = DateTime(
          pickedDate.year,
          pickedDate.month,
          pickedDate.day,
          _selectedDateTime.hour,
          _selectedDateTime.minute,
        );
      });
      _updateRemaining();
    }
  }

  Future<void> _pickTime() async {
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_selectedDateTime),
    );

    if (pickedTime != null) {
      setState(() {
        _selectedDateTime = DateTime(
          _selectedDateTime.year,
          _selectedDateTime.month,
          _selectedDateTime.day,
          pickedTime.hour,
          pickedTime.minute,
        );
      });
      _updateRemaining();
    }
  }

  String _formatCountdown() {
    if (_remaining == Duration.zero) return 'Starts now';
    final hours = _remaining.inHours;
    final mins = _remaining.inMinutes % 60;
    final secs = _remaining.inSeconds % 60;
    if (hours > 0) {
      return '$hours h $mins m';
    }
    return '$mins m $secs s';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isValidFuture = _selectedDateTime.isAfter(DateTime.now());
    final dateFormat = DateFormat('EEE, MMM d, yyyy');
    final timeFormat = DateFormat('hh:mm a');

    return DmxCardShell(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.schedule_rounded, size: 22),
                const SizedBox(width: 8),
                Text(
                  'Schedule Download',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: _pickDate,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: isDark ? Colors.white24 : Colors.black12,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.calendar_today_rounded, size: 18),
                          const SizedBox(width: 8),
                          Text(dateFormat.format(_selectedDateTime)),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: InkWell(
                    onTap: _pickTime,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: isDark ? Colors.white24 : Colors.black12,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.access_time_rounded, size: 18),
                          const SizedBox(width: 8),
                          Text(timeFormat.format(_selectedDateTime)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Text('Repeat: ',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                DropdownButton<ScheduleRepeat>(
                  value: _selectedRepeat,
                  onChanged: (repeat) {
                    if (repeat != null) {
                      setState(() => _selectedRepeat = repeat);
                    }
                  },
                  items: const [
                    DropdownMenuItem(
                      value: ScheduleRepeat.none,
                      child: Text('Does not repeat'),
                    ),
                    DropdownMenuItem(
                      value: ScheduleRepeat.daily,
                      child: Text('Daily'),
                    ),
                    DropdownMenuItem(
                      value: ScheduleRepeat.weekly,
                      child: Text('Weekly'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isValidFuture
                    ? Colors.blue.withValues(alpha: 0.1)
                    : Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    isValidFuture
                        ? Icons.timer_outlined
                        : Icons.error_outline_rounded,
                    color: isValidFuture ? Colors.blue : Colors.red,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isValidFuture
                        ? 'Starts in: ${_formatCountdown()}'
                        : 'Scheduled time must be in the future',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isValidFuture ? Colors.blue : Colors.red,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (widget.onCancelSchedule != null)
                  TextButton(
                    onPressed: widget.onCancelSchedule,
                    child: const Text('Cancel Schedule'),
                  ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: isValidFuture
                      ? () =>
                          widget.onScheduled(_selectedDateTime, _selectedRepeat)
                      : null,
                  child: const Text('Save Schedule'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
