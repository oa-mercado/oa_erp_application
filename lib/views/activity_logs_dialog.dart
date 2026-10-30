import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/scan_record_model.dart';
import '../providers/kiosk_provider.dart';

/// Modal dialog displaying recent RFID tap activity logs stored in `stud_entry_tbl`.
/// Synced records are retained locally for 30 days; unsynced records persist until sent.
class ActivityLogsDialog extends ConsumerStatefulWidget {
  const ActivityLogsDialog({super.key});

  @override
  ConsumerState<ActivityLogsDialog> createState() => _ActivityLogsDialogState();
}

class _ActivityLogsDialogState extends ConsumerState<ActivityLogsDialog> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  bool _todayOnly = false;
  List<ScanRecordModel> _logs = [];
  ({int totalToday, int entranceToday, int exitToday, int unsyncedTotal, int totalStored}) _stats = (
    totalToday: 0,
    entranceToday: 0,
    exitToday: 0,
    unsyncedTotal: 0,
    totalStored: 0,
  );

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_loadLogs);
    _loadLogs();
  }

  @override
  void dispose() {
    _searchController.removeListener(_loadLogs);
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _loadLogs() {
    final localDb = ref.read(localDbServiceProvider);
    final logs = localDb.getRecentTapLogs(
      limit: 300,
      searchQuery: _searchController.text,
      todayOnly: _todayOnly,
    );
    final stats = localDb.getTapStats();
    if (mounted) {
      setState(() {
        _logs = logs;
        _stats = stats;
      });
    }
  }

  String _formatDate(DateTime dt) {
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
    final syncedCount = (_stats.totalStored - _stats.unsyncedTotal).clamp(0, _stats.totalStored);

    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      elevation: 16,
      child: Container(
        width: 860,
        constraints: const BoxConstraints(maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. Header with Title & Quick Summary Pills (No Entrance/Exit status)
            Container(
              padding: const EdgeInsets.fromLTRB(24, 18, 16, 14),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFFEBEEF5))),
              ),
              child: Row(
                children: [
                  const Icon(Icons.history_rounded, color: Color(0xFF1E293B), size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Activity Logs',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Synced logs are kept for 30 days • Total stored: ${_stats.totalStored}',
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _buildStatPill(
                    label: 'Today',
                    count: _stats.totalToday,
                    bgColor: const Color(0xFFF1F5F9),
                    textColor: const Color(0xFF334155),
                  ),
                  const SizedBox(width: 8),
                  _buildStatPill(
                    label: 'Synced',
                    count: syncedCount,
                    bgColor: const Color(0xFFDCFCE7),
                    textColor: const Color(0xFF15803D),
                  ),
                  if (_stats.unsyncedTotal > 0) ...[
                    const SizedBox(width: 8),
                    _buildStatPill(
                      label: 'Pending Sync',
                      count: _stats.unsyncedTotal,
                      bgColor: const Color(0xFFFEF3C7),
                      textColor: const Color(0xFFB45309),
                    ),
                    const SizedBox(width: 6),
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () async {
                        await ref.read(kioskScanProvider.notifier).syncOfflineQueue(force: true);
                        _loadLogs();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2563EB),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.sync, size: 13, color: Colors.white),
                            SizedBox(width: 4),
                            Text(
                              'Sync Now',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 12),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20, color: Color(0xFF64748B)),
                    splashRadius: 18,
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // 2. Search & Filter Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              color: const Color(0xFFF8FAFC),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: TextField(
                        controller: _searchController,
                        focusNode: _searchFocusNode,
                        autofocus: true,
                        onChanged: (_) => _loadLogs(),
                        onSubmitted: (_) => _loadLogs(),
                        style: const TextStyle(fontSize: 13, color: Color(0xFF1E293B)),
                        decoration: InputDecoration(
                          hintText: 'Search by name, Student/Employee ID, or RFID...',
                          hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                          prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF94A3B8)),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 16, color: Color(0xFF94A3B8)),
                                  onPressed: () {
                                    _searchController.clear();
                                    _loadLogs();
                                  },
                                )
                              : null,
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: const BorderSide(color: Color(0xFF3B82F6), width: 1.5),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _buildFilterButton(
                    label: 'All (30 Days)',
                    selected: !_todayOnly,
                    onTap: () {
                      setState(() => _todayOnly = false);
                      _loadLogs();
                    },
                  ),
                  const SizedBox(width: 6),
                  _buildFilterButton(
                    label: 'Today Only',
                    selected: _todayOnly,
                    onTap: () {
                      setState(() => _todayOnly = true);
                      _loadLogs();
                    },
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 18, color: Color(0xFF475569)),
                    tooltip: 'Refresh logs',
                    splashRadius: 18,
                    onPressed: _loadLogs,
                  ),
                ],
              ),
            ),

            // 3. Table Column Headers (No Entrance/Exit STATUS column)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              decoration: const BoxDecoration(
                color: Color(0xFFF1F5F9),
                border: Border(
                  top: BorderSide(color: Color(0xFFE2E8F0)),
                  bottom: BorderSide(color: Color(0xFFE2E8F0)),
                ),
              ),
              child: const Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: Text(
                      'STUDENT / EMPLOYEE',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF475569),
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      'ID',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF475569),
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      'GATE / PLACE',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF475569),
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      'DATE & TIME',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF475569),
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Center(
                      child: Text(
                        'SYNC',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF475569),
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // 4. Scrollable Tap Log Rows
            Expanded(
              child: _logs.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.inbox_outlined, size: 48, color: Colors.grey.shade400),
                          const SizedBox(height: 10),
                          Text(
                            _searchController.text.isNotEmpty
                                ? 'No matching tap records found.'
                                : 'No tap activity recorded yet.',
                            style: const TextStyle(
                              fontSize: 14,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      itemCount: _logs.length,
                      separatorBuilder: (_, _) => const Divider(height: 1, color: Color(0xFFF1F5F9)),
                      itemBuilder: (context, index) {
                        final record = _logs[index];
                        final hasName = record.studentName.trim().isNotEmpty;
                        final displayName = hasName ? record.studentName : 'Uncached Card';
                        final displayId = record.studentIdDesc.trim().isNotEmpty
                            ? record.studentIdDesc
                            : '—';
                        final displayPlace = record.placeName.trim().isNotEmpty
                            ? record.placeName
                            : '—';
                        final subtitleParts = <String>[];
                        if (record.type.isNotEmpty) subtitleParts.add(record.type);
                        if (record.gradeLevel.isNotEmpty && record.gradeLevel != 'N/A') {
                          subtitleParts.add(record.gradeLevel);
                        }
                        if (record.section.isNotEmpty && record.section != 'N/A') {
                          subtitleParts.add(record.section);
                        }

                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                          child: Row(
                            children: [
                              // Name & Grade/Section
                              Expanded(
                                flex: 4,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      displayName,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: hasName
                                            ? const Color(0xFF1E293B)
                                            : const Color(0xFF94A3B8),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (subtitleParts.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        subtitleParts.join(' • '),
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFF64748B),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ],
                                ),
                              ),

                              // Student / Employee ID
                              Expanded(
                                flex: 2,
                                child: Text(
                                  displayId,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF334155),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),

                              // Gate / Place Name
                              Expanded(
                                flex: 3,
                                child: Text(
                                  displayPlace,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    color: Color(0xFF475569),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),

                              // Date & Time
                              Expanded(
                                flex: 3,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _formatDate(record.scannedAt),
                                      style: const TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w500,
                                        color: Color(0xFF1E293B),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _formatTime(record.scannedAt),
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        color: Color(0xFF64748B),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Sync Status
                              Expanded(
                                flex: 2,
                                child: Center(
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        record.isSynced
                                            ? Icons.check_circle_rounded
                                            : Icons.schedule_rounded,
                                        size: 14,
                                        color: record.isSynced
                                            ? const Color(0xFF16A34A)
                                            : const Color(0xFFD97706),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        record.isSynced ? 'Synced' : 'Pending',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w500,
                                          color: record.isSynced
                                              ? const Color(0xFF15803D)
                                              : const Color(0xFFB45309),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatPill({
    required String label,
    required int count,
    required Color bgColor,
    required Color textColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: textColor,
            ),
          ),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterButton({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? const Color(0xFF1E293B) : Colors.white,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? const Color(0xFF1E293B) : const Color(0xFFCBD5E1),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : const Color(0xFF475569),
            ),
          ),
        ),
      ),
    );
  }
}
