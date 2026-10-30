import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/kiosk_provider.dart';

/// Live-ticking clickable Date & Time pill displayed on the Kiosk main screen.
/// Clicking opens [DateTimeSettingsDialog] so operators can adjust Date & Time
/// when a device is offline with an outdated clock or if server time is wrong.
class KioskClockPill extends ConsumerStatefulWidget {
  final VoidCallback onTap;

  const KioskClockPill({
    super.key,
    required this.onTap,
  });

  @override
  ConsumerState<KioskClockPill> createState() => _KioskClockPillState();
}

class _KioskClockPillState extends ConsumerState<KioskClockPill> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _formatShortDate(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[dt.month - 1]} ${dt.day.toString().padLeft(2, '0')}, ${dt.year}';
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '${h.toString().padLeft(2, '0')}:$m:$s $period';
  }

  @override
  Widget build(BuildContext context) {
    final localDb = ref.read(localDbServiceProvider);
    final now = localDb.now;
    final isManual = localDb.isManualTimeOffset;

    return Tooltip(
      message: isManual
          ? 'Manual Date & Time active (Click to adjust or sync with server)'
          : 'Kiosk Date & Time (Click to adjust)',
      child: Material(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          mouseCursor: SystemMouseCursors.click,
          onTap: widget.onTap,
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: isManual
                    ? const Color(0xFFF59E0B).withValues(alpha: 0.7)
                    : Colors.white24,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.access_time_filled_rounded,
                  size: 15,
                  color: isManual ? const Color(0xFFFBBF24) : Colors.white,
                ),
                const SizedBox(width: 7),
                Text(
                  '${_formatShortDate(now)}  •  ${_formatTime(now)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
                if (isManual) ...[
                  const SizedBox(width: 7),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF59E0B).withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: const Color(0xFFFBBF24), width: 0.8),
                    ),
                    child: const Text(
                      'MANUAL',
                      style: TextStyle(
                        color: Color(0xFFFDE68A),
                        fontSize: 9.5,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Modal dialog allowing the operator to inspect the current Kiosk Date & Time,
/// manually override Date & Time (persisted in SQLite for offline/outdated devices),
/// or re-sync automatically with the ERP server.
class DateTimeSettingsDialog extends ConsumerStatefulWidget {
  const DateTimeSettingsDialog({super.key});

  @override
  ConsumerState<DateTimeSettingsDialog> createState() => _DateTimeSettingsDialogState();
}

class _DateTimeSettingsDialogState extends ConsumerState<DateTimeSettingsDialog> {
  late int _year;
  late int _month;
  late int _day;
  late int _hour12;
  late int _minute;
  late int _second;
  late bool _isPm;

  bool _isSyncingServer = false;
  String? _statusMessage;
  bool _statusIsError = false;
  Timer? _livePreviewTimer;

  static const List<String> _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December'
  ];

  @override
  void initState() {
    super.initState();
    // Pause background RFID scanner while dialog is open
    try {
      final listener = ref.read(kioskProvider.notifier).listener;
      listener.isPaused = true;
      listener.clearBuffer();
    } catch (_) {}

    _loadFromCurrentKioskTime();

    _livePreviewTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _loadFromCurrentKioskTime() {
    final now = ref.read(localDbServiceProvider).now;
    _year = now.year.clamp(2020, 2035);
    _month = now.month;
    _day = now.day;
    _isPm = now.hour >= 12;
    _hour12 = now.hour > 12 ? now.hour - 12 : (now.hour == 0 ? 12 : now.hour);
    _minute = now.minute;
    _second = now.second;
  }

  @override
  void dispose() {
    _livePreviewTimer?.cancel();
    try {
      final listener = ref.read(kioskProvider.notifier).listener;
      listener.isPaused = false;
      listener.clearBuffer();
    } catch (_) {}
    super.dispose();
  }

  int _daysInMonth(int year, int month) {
    return DateTime(year, month + 1, 0).day;
  }

  DateTime _buildSelectedDateTime() {
    final maxDay = _daysInMonth(_year, _month);
    final validDay = _day.clamp(1, maxDay);
    int hour24;
    if (_isPm) {
      hour24 = _hour12 == 12 ? 12 : _hour12 + 12;
    } else {
      hour24 = _hour12 == 12 ? 0 : _hour12;
    }
    return DateTime(_year, _month, validDay, hour24, _minute, _second);
  }

  Future<void> _pickDateWithCalendar() async {
    final current = _buildSelectedDateTime();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime(2035, 12, 31),
    );
    if (picked != null && mounted) {
      setState(() {
        _year = picked.year;
        _month = picked.month;
        _day = picked.day;
      });
    }
  }

  Future<void> _pickTimeWithClock() async {
    final current = _buildSelectedDateTime();
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current.hour, minute: current.minute),
    );
    if (picked != null && mounted) {
      setState(() {
        _isPm = picked.hour >= 12;
        _hour12 = picked.hour > 12
            ? picked.hour - 12
            : (picked.hour == 0 ? 12 : picked.hour);
        _minute = picked.minute;
        _second = 0;
      });
    }
  }

  Future<void> _handleSyncWithServer() async {
    setState(() {
      _isSyncingServer = true;
      _statusMessage = null;
    });

    final ok = await ref.read(kioskProvider.notifier).syncTimeWithServer();
    if (!mounted) return;

    setState(() {
      _isSyncingServer = false;
      if (ok) {
        _loadFromCurrentKioskTime();
        _statusIsError = false;
        _statusMessage = 'Successfully synced with ERP server time.';
      } else {
        _statusIsError = true;
        _statusMessage = 'Could not reach server. You can set the Date & Time manually below.';
      }
    });
  }

  void _handleSaveManualTime() {
    final target = _buildSelectedDateTime();
    ref.read(kioskProvider.notifier).setManualKioskTime(target);
    Navigator.of(context).pop(true);
  }

  String _formatFullDateTime(DateTime dt) {
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '${_monthNames[dt.month - 1]} ${dt.day.toString().padLeft(2, '0')}, ${dt.year}  •  ${h.toString().padLeft(2, '0')}:$m:$s $period';
  }

  @override
  Widget build(BuildContext context) {
    final localDb = ref.read(localDbServiceProvider);
    final liveNow = localDb.now;
    final isManual = localDb.isManualTimeOffset;
    final isOffline = ref.watch(isOfflineProvider);
    final maxDays = _daysInMonth(_year, _month);
    if (_day > maxDays) {
      _day = maxDays;
    }

    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      elevation: 16,
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.schedule_rounded, color: Color(0xFF1E293B), size: 22),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Date & Time Settings',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1E293B),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20, color: Color(0xFF64748B)),
                  splashRadius: 18,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Live Current Kiosk Time Banner
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'CURRENT KIOSK TIME',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF64748B),
                          letterSpacing: 0.5,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: isManual
                              ? const Color(0xFFFEF3C7)
                              : const Color(0xFFDCFCE7),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          isManual ? 'Manual Override' : 'Server Synced (Auto)',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: isManual
                                ? const Color(0xFFB45309)
                                : const Color(0xFF15803D),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _formatFullDateTime(liveNow),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                ],
              ),
            ),

            if (_statusMessage != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: _statusIsError
                      ? const Color(0xFFFEF2F2)
                      : const Color(0xFFECFDF5),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: _statusIsError
                        ? const Color(0xFFFECACA)
                        : const Color(0xFFA7F3D0),
                  ),
                ),
                child: Text(
                  _statusMessage!,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: _statusIsError
                        ? const Color(0xFFDC2626)
                        : const Color(0xFF059669),
                  ),
                ),
              ),
            ],

            const SizedBox(height: 20),

            // Manual Date Selector
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Set Date',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF334155),
                  ),
                ),
                TextButton.icon(
                  onPressed: _pickDateWithCalendar,
                  icon: const Icon(Icons.calendar_month_outlined, size: 16),
                  label: const Text('Open Calendar', style: TextStyle(fontSize: 12.5)),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                // Month Dropdown
                Expanded(
                  flex: 5,
                  child: _buildDropdown<int>(
                    value: _month,
                    items: List.generate(
                      12,
                      (i) => DropdownMenuItem(
                        value: i + 1,
                        child: Text(_monthNames[i]),
                      ),
                    ),
                    onChanged: (val) {
                      if (val != null) setState(() => _month = val);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                // Day Dropdown
                Expanded(
                  flex: 3,
                  child: _buildDropdown<int>(
                    value: _day,
                    items: List.generate(
                      maxDays,
                      (i) => DropdownMenuItem(
                        value: i + 1,
                        child: Text((i + 1).toString().padLeft(2, '0')),
                      ),
                    ),
                    onChanged: (val) {
                      if (val != null) setState(() => _day = val);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                // Year Dropdown
                Expanded(
                  flex: 4,
                  child: _buildDropdown<int>(
                    value: _year,
                    items: List.generate(
                      16,
                      (i) {
                        final yr = 2020 + i;
                        return DropdownMenuItem(
                          value: yr,
                          child: Text('$yr'),
                        );
                      },
                    ),
                    onChanged: (val) {
                      if (val != null) setState(() => _year = val);
                    },
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Manual Time Selector
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Set Time',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF334155),
                  ),
                ),
                TextButton.icon(
                  onPressed: _pickTimeWithClock,
                  icon: const Icon(Icons.access_time, size: 16),
                  label: const Text('Open Clock Picker', style: TextStyle(fontSize: 12.5)),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                // Hour (1..12)
                Expanded(
                  flex: 3,
                  child: _buildDropdown<int>(
                    value: _hour12,
                    items: List.generate(
                      12,
                      (i) => DropdownMenuItem(
                        value: i + 1,
                        child: Text('${(i + 1).toString().padLeft(2, '0')} hr'),
                      ),
                    ),
                    onChanged: (val) {
                      if (val != null) setState(() => _hour12 = val);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                // Minute (00..59)
                Expanded(
                  flex: 3,
                  child: _buildDropdown<int>(
                    value: _minute,
                    items: List.generate(
                      60,
                      (i) => DropdownMenuItem(
                        value: i,
                        child: Text('${i.toString().padLeft(2, '0')} min'),
                      ),
                    ),
                    onChanged: (val) {
                      if (val != null) setState(() => _minute = val);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                // AM / PM Toggle
                Expanded(
                  flex: 3,
                  child: _buildDropdown<bool>(
                    value: _isPm,
                    items: const [
                      DropdownMenuItem(value: false, child: Text('AM')),
                      DropdownMenuItem(value: true, child: Text('PM')),
                    ],
                    onChanged: (val) {
                      if (val != null) setState(() => _isPm = val);
                    },
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // Footer Actions
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: (_isSyncingServer || isOffline) ? null : _handleSyncWithServer,
                  icon: _isSyncingServer
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync, size: 16),
                  label: const Text('Sync with Server'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF334155),
                    side: const BorderSide(color: Color(0xFFCBD5E1)),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel', style: TextStyle(color: Color(0xFF64748B))),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _handleSaveManualTime,
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Save Date & Time'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDropdown<T>({
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Color(0xFF1E293B),
          ),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}
