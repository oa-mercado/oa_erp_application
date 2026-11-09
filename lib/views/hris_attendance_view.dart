import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import '../core/config/env_config.dart';
import '../models/hris_attendance_models.dart';
import '../providers/hris_attendance_provider.dart';
import '../providers/kiosk_provider.dart';
import '../services/update_service.dart';
import 'activity_logs_dialog.dart';
import 'date_time_settings_dialog.dart';
import 'hris_passcode_view.dart';

/// Top-level HRIS Desktop Attendance shell that automatically handles:
/// 1. Passcode detection & verification (`/hris/attendance/passcode`) when required by the school
/// 2. Online Attendance Tapping Portal (`/hris/online_attendance`)
/// 3. Offline SQLite queueing, Activity Logs, Date/Time Settings, and App Updates/Maintenance
class HrisAttendanceShell extends ConsumerStatefulWidget {
  const HrisAttendanceShell({super.key});

  @override
  ConsumerState<HrisAttendanceShell> createState() => _HrisAttendanceShellState();
}

class _HrisAttendanceShellState extends ConsumerState<HrisAttendanceShell> with WindowListener {
  final TextEditingController _scannerController = TextEditingController();
  final FocusNode _scannerFocusNode = FocusNode();

  Timer? _clockAndFocusTimer;
  bool _isFullScreen = true;
  bool _isModalOpen = false;
  bool _isManualSyncing = false;

  // App update progress state
  bool _isDownloadingUpdate = false;
  double _downloadProgress = 0.0;
  String? _updateError;
  bool _isUpdateCompleted = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.setTitle(EnvConfig.appName);
      windowManager.isFullScreen().then((isFull) {
        if (mounted && _isFullScreen != isFull) {
          setState(() => _isFullScreen = isFull);
        }
      });
    }

    // 1-second timer matching `OnlineAttendance.vue` (`dateNowUI` live clock + `focusOnInput()`)
    _clockAndFocusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      _ensureScannerFocused();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureScannerFocused();
    });
  }

  @override
  void dispose() {
    _clockAndFocusTimer?.cancel();
    windowManager.removeListener(this);
    _scannerController.dispose();
    _scannerFocusNode.dispose();
    super.dispose();
  }

  void _ensureScannerFocused() {
    if (!mounted || _isModalOpen) return;
    final hrisState = ref.read(hrisAttendanceProvider);
    if (hrisState.isInitializing || hrisState.requiresPasscode) return;

    final remoteStatus = ref.read(remoteStatusProvider);
    final softDismissed = ref.read(softLockDismissedProvider);
    if (remoteStatus.isHardLock || (remoteStatus.isSoftLock && !softDismissed)) return;

    if (!_scannerFocusNode.hasFocus) {
      _scannerFocusNode.requestFocus();
    }
  }

  @override
  void onWindowEnterFullScreen() {
    if (mounted && !_isFullScreen) setState(() => _isFullScreen = true);
  }

  @override
  void onWindowLeaveFullScreen() {
    if (mounted && _isFullScreen) setState(() => _isFullScreen = false);
  }

  Future<void> _toggleFullScreen() async {
    final isFull = await windowManager.isFullScreen();
    await windowManager.setFullScreen(!isFull);
    if (mounted) {
      setState(() => _isFullScreen = !isFull);
      _ensureScannerFocused();
    }
  }

  Future<T?> _openDialogSafely<T>(WidgetBuilder builder, {bool barrierDismissible = true}) async {
    setState(() => _isModalOpen = true);
    _scannerFocusNode.unfocus();
    try {
      return await showDialog<T>(
        context: context,
        barrierDismissible: barrierDismissible,
        builder: builder,
      );
    } finally {
      if (mounted) {
        setState(() => _isModalOpen = false);
        WidgetsBinding.instance.addPostFrameCallback((_) => _ensureScannerFocused());
      }
    }
  }

  Future<void> _handleCloseApp() async {
    final shouldClose = await _openDialogSafely<bool>(
      (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Row(
          children: [
            Icon(Icons.power_settings_new, color: Color(0xFFE11D48)),
            SizedBox(width: 8),
            Text('Close Attendance App', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: const Text(
          'Are you sure you want to close the HRIS Attendance application?',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE11D48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Close'),
          ),
        ],
      ),
      barrierDismissible: false,
    );

    if (shouldClose == true) {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        await windowManager.close();
      }
      exit(0);
    }
  }

  Future<void> _showActivityLogsDialog() async {
    await _openDialogSafely<void>((_) => const ActivityLogsDialog());
  }

  Future<void> _showDateTimeSettingsDialog() async {
    final updated = await _openDialogSafely<bool>((_) => const DateTimeSettingsDialog());
    if (updated == true && mounted) {
      setState(() {});
      ref
          .read(hrisAttendanceProvider.notifier)
          .showToast('Date & Time updated and saved.', isError: false);
    }
  }

  Future<void> _handleManualResync() async {
    if (_isManualSyncing) return;
    setState(() => _isManualSyncing = true);
    try {
      final notifier = ref.read(hrisAttendanceProvider.notifier);
      final isOnline = await notifier.checkConnectivity(forceSync: true);
      if (!isOnline) {
        notifier.showToast('Currently offline — pending taps will sync automatically when online.');
        return;
      }
      await notifier.syncOfflineQueue(force: true);
      await notifier.refreshTodayLogs();
      notifier.showToast('Attendance portal synced with server.', isError: false);
    } finally {
      if (mounted) {
        setState(() => _isManualSyncing = false);
        _ensureScannerFocused();
      }
    }
  }

  void _handleScannerSubmit(String rawValue) {
    final code = rawValue.trim();
    _scannerController.clear();
    if (code.isNotEmpty) {
      ref.read(hrisAttendanceProvider.notifier).submitTap(code);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureScannerFocused());
  }

  Future<void> _startAppUpdate(String downloadUrl) async {
    if (_isDownloadingUpdate || _isUpdateCompleted) return;
    setState(() {
      _isDownloadingUpdate = true;
      _downloadProgress = 0.0;
      _updateError = null;
      _isUpdateCompleted = false;
    });

    final updateService = ref.read(updateServiceProvider);
    final file = await updateService.downloadInstaller(
      downloadUrl: downloadUrl,
      onProgress: (p) {
        if (mounted) setState(() => _downloadProgress = p);
      },
    );

    if (file != null && mounted) {
      await updateService.launchInstaller(file);
      if (mounted) {
        setState(() {
          _isDownloadingUpdate = false;
          _isUpdateCompleted = true;
        });
      }
    } else if (mounted) {
      setState(() {
        _isDownloadingUpdate = false;
        _updateError = 'Download failed. Please check internet connection.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(hrisAttendanceProvider);
    final isOffline = ref.watch(isOfflineProvider);
    final unsyncedCount = ref.watch(offlineQueueCountProvider);
    final remoteStatus = ref.watch(remoteStatusProvider);
    final softLockDismissed = ref.watch(softLockDismissedProvider);

    final isUpdateRequired = !isOffline &&
        !remoteStatus.isLocked &&
        UpdateAndMaintenanceService.isUpdateAvailable(
          EnvConfig.appVersion,
          remoteStatus.latestVersion,
        );

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      body: Stack(
        children: [
          // 1. Optional Portal Background Image (`bg_img_url`)
          if (!state.requiresPasscode) _buildPortalBackground(state),

          // 2. Top Kiosk Utility Bar + Main Content Area
          Column(
            children: [
              _buildTopUtilityBar(
                state: state,
                isOffline: isOffline,
                unsyncedCount: unsyncedCount,
              ),
              Expanded(
                child: state.isInitializing
                    ? _buildInitializingLoader(state)
                    : state.requiresPasscode
                        ? const HrisPasscodeView()
                        : _buildOnlineAttendancePortal(state, isOffline),
              ),
            ],
          ),

          // 3. Element-UI Style Floating Prompt / Toast (`Message`)
          if (state.toastMessage != null && state.toastMessage!.isNotEmpty)
            Positioned(
              top: 58,
              left: 0,
              right: 0,
              child: Center(
                child: _buildFloatingToast(state.toastMessage!, state.toastIsError),
              ),
            ),

          // 4. Maintenance / App Update Overlays
          if (remoteStatus.isHardLock)
            _buildMaintenanceOverlay(remoteStatus, isHardLock: true)
          else if (remoteStatus.isSoftLock && !softLockDismissed)
            _buildMaintenanceOverlay(remoteStatus, isHardLock: false)
          else if (isUpdateRequired)
            _buildForceUpdateOverlay(remoteStatus),
        ],
      ),
    );
  }

  Widget _buildPortalBackground(HrisAttendanceState state) {
    final localBg = state.cachedBgImagePath;
    if (localBg != null && localBg.isNotEmpty && File(localBg).existsSync()) {
      return Positioned.fill(
        child: Image.file(
          File(localBg),
          fit: BoxFit.cover,
        ),
      );
    }

    final remoteBg = state.config.bgImgUrl.trim();
    if (remoteBg.isNotEmpty &&
        (remoteBg.startsWith('http://') || remoteBg.startsWith('https://'))) {
      return Positioned.fill(
        child: Image.network(
          remoteBg,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildTopUtilityBar({
    required HrisAttendanceState state,
    required bool isOffline,
    required int unsyncedCount,
  }) {
    final barColor = state.config.primaryColor;

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: barColor,
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        children: [
          // Online / Offline Badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.white24),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isOffline ? Icons.wifi_off_rounded : Icons.wifi_rounded,
                  size: 15,
                  color: isOffline ? const Color(0xFFFBBF24) : const Color(0xFF4ADE80),
                ),
                const SizedBox(width: 6),
                Text(
                  isOffline ? 'OFFLINE MODE' : 'ONLINE',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          ),

          if (unsyncedCount > 0) ...[
            const SizedBox(width: 8),
            InkWell(
              onTap: _showActivityLogsDialog,
              borderRadius: BorderRadius.circular(4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.schedule_rounded, size: 14, color: Colors.white),
                    const SizedBox(width: 5),
                    Text(
                      'Pending Sync: $unsyncedCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],

          const Spacer(),

          // Resync Button
          _buildTopIconBtn(
            tooltip: _isManualSyncing ? 'Syncing...' : 'Sync & Refresh Portal',
            onTap: _isManualSyncing ? null : _handleManualResync,
            child: _isManualSyncing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : const Icon(Icons.sync_rounded, size: 17, color: Colors.white),
          ),
          const SizedBox(width: 6),

          // Activity Logs Button
          _buildTopIconBtn(
            tooltip: 'Activity Logs',
            onTap: _showActivityLogsDialog,
            child: const Icon(Icons.history_rounded, size: 17, color: Colors.white),
          ),
          const SizedBox(width: 6),

          // Date & Time Settings Pill
          KioskClockPill(onTap: _showDateTimeSettingsDialog),

          // Lock Passcode Button (only if school uses passcode & currently unlocked)
          if (state.schoolHasPasscode && !state.requiresPasscode) ...[
            const SizedBox(width: 6),
            _buildTopIconBtn(
              tooltip: 'Lock Attendance Passcode',
              onTap: () => ref.read(hrisAttendanceProvider.notifier).lockPasscode(),
              child: const Icon(Icons.lock_outline_rounded, size: 17, color: Colors.white),
            ),
          ],

          const SizedBox(width: 6),
          // Fullscreen Toggle
          _buildTopIconBtn(
            tooltip: _isFullScreen ? 'Exit Full Screen' : 'Enter Full Screen',
            onTap: _toggleFullScreen,
            child: Icon(
              _isFullScreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
              size: 18,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 6),

          // Close Button
          _buildTopIconBtn(
            tooltip: 'Close Application',
            bgColor: const Color(0xFFE11D48),
            onTap: _handleCloseApp,
            child: const Icon(Icons.close_rounded, size: 18, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildTopIconBtn({
    required String tooltip,
    required VoidCallback? onTap,
    required Widget child,
    Color bgColor = Colors.black26,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: bgColor,
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.white24),
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _buildInitializingLoader(HrisAttendanceState state) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(state.config.primaryColor),
          ),
          const SizedBox(height: 16),
          const Text(
            'Connecting to HRIS Attendance Portal...',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFF475569),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOnlineAttendancePortal(HrisAttendanceState state, bool isOffline) {
    final config = state.config;
    final themeColor = config.primaryColor;
    final headerTextColor = config.textColor;

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 1560,
                minHeight: (constraints.maxHeight - 36).clamp(480.0, 2000.0),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 1. School Header (`#nav-header` in `OnlineAttendance.vue`)
                  _buildSchoolNavHeader(state, themeColor),
                  const SizedBox(height: 16),

                  // 2. Main `el-card` (`#attendance-card` in `OnlineAttendance.vue`)
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: const Color(0xFFEBEEF5)),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x1A000000),
                          blurRadius: 12,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Card Header (`ONLINE ATTENDANCE PORTAL`)
                        Container(
                          color: themeColor,
                          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
                          child: Text(
                            config.portalHeaderTitle,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: headerTextColor,
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),

                        // Card 2-Column Body
                        Padding(
                          padding: const EdgeInsets.fromLTRB(28, 26, 28, 28),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // LEFT COLUMN (`:md="14"`): Live Date/Clock + Today's Attendance Table + Note
                              Expanded(
                                flex: 14,
                                child: _buildLeftPortalColumn(state, themeColor),
                              ),
                              const SizedBox(width: 28),

                              // RIGHT COLUMN (`:md="10"`): RFID/QR Input + Scanned Employee Info
                              Expanded(
                                flex: 10,
                                child: _buildRightPortalColumn(state, themeColor),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSchoolNavHeader(HrisAttendanceState state, Color themeColor) {
    final config = state.config;
    final displaySchoolName = config.schoolName.trim().isNotEmpty
        ? config.schoolName.trim()
        : EnvConfig.appName;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _buildHeaderLogoWidget(state),
        const SizedBox(width: 16),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                displaySchoolName,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: themeColor,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  height: 1.2,
                ),
              ),
              if (config.schoolBranch.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  config.schoolBranch.trim(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: themeColor,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHeaderLogoWidget(HrisAttendanceState state) {
    final localPath = state.cachedSchoolLogoPath;
    if (localPath != null && localPath.isNotEmpty && File(localPath).existsSync()) {
      return Image.file(
        File(localPath),
        height: 90,
        fit: BoxFit.contain,
      );
    }

    final url = state.config.schoolImage.trim();
    if (url.isNotEmpty && (url.startsWith('http://') || url.startsWith('https://'))) {
      return Image.network(
        url,
        height: 90,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _fallbackHeaderLogo(state.config.primaryColor),
      );
    }

    return _fallbackHeaderLogo(state.config.primaryColor);
  }

  Widget _fallbackHeaderLogo(Color themeColor) {
    return Image.asset(
      'assets/images/logo.png',
      height: 80,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => Icon(
        Icons.school_rounded,
        size: 68,
        color: themeColor,
      ),
    );
  }

  Widget _buildLeftPortalColumn(HrisAttendanceState state, Color themeColor) {
    final now = ref.read(localDbServiceProvider).now;
    final config = state.config;
    final fullMonth = config.schoolId == 124;

    final datePart = _formatPortalDateLine(now, fullMonth: fullMonth);
    final timeDigits = _formatPortalClockDigits(now);
    final amPm = now.hour >= 12 ? 'pm' : 'am';

    // Match `OnlineAttendance.vue` `showTable` logic
    final showTable = config.schoolId != 74 &&
        config.schoolId != 124 &&
        config.schoolId != 164 &&
        (config.schoolId != 125 || state.activeEmployee != null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Live Date & Clock (`<h1 :style="{ 'color': color, 'font-size': '3.8rem' }">`)
        Text(
          datePart,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: themeColor,
            fontSize: 40,
            fontWeight: FontWeight.w400,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 4),
        RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            style: TextStyle(
              color: themeColor,
              fontSize: 48,
              fontFamily: 'Segoe UI',
              height: 1.15,
            ),
            children: [
              TextSpan(
                text: timeDigits,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              TextSpan(
                text: ' $amPm',
                style: const TextStyle(fontWeight: FontWeight.w400),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Crafted with ♡ by the OrangeApps Team.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: themeColor,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 18),

        // Today's Attendance Table (`el-table`)
        if (showTable) ...[
          _buildTodayAttendanceTable(state),
          const SizedBox(height: 14),
        ],

        // Info Note (`Employee's first tap of the day...`)
        if (config.schoolId != 124)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(Icons.info_rounded, size: 15, color: themeColor),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    "Note : Employee's first tap of the day will serve as their official Time In and last tap of the day will serve as their official Time Out.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: themeColor,
                      fontSize: config.schoolId == 147 ? 15 : 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildTodayAttendanceTable(HrisAttendanceState state) {
    final schoolId = state.config.schoolId;
    final logs = state.todayLogs;

    List<({String label, int flex})> columns;
    if (schoolId == 129) {
      columns = const [
        (label: 'Name', flex: 4),
        (label: 'Time In (AM)', flex: 2),
        (label: 'Time Out (AM)', flex: 2),
        (label: 'Time In (PM)', flex: 2),
        (label: 'Time Out (PM)', flex: 2),
      ];
    } else if (schoolId == 125) {
      columns = const [
        (label: 'Time In', flex: 1),
        (label: 'Time Out', flex: 1),
      ];
    } else {
      columns = const [
        (label: 'Name', flex: 5),
        (label: 'Time In', flex: 3),
        (label: 'Time Out', flex: 3),
      ];
    }

    return FractionallySizedBox(
      widthFactor: 0.94,
      child: Container(
        constraints: const BoxConstraints(minHeight: 160, maxHeight: 330),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(
            color: schoolId == 147 ? const Color(0xFFCCCCCC) : const Color(0xFFEBEEF5),
            width: schoolId == 147 ? 2.5 : 1.0,
          ),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Stack(
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Table Header
                Container(
                  decoration: const BoxDecoration(
                    color: Color(0xFFF8FAFC),
                    border: Border(bottom: BorderSide(color: Color(0xFFEBEEF5))),
                  ),
                  child: Row(
                    children: [
                      for (int i = 0; i < columns.length; i++)
                        Expanded(
                          flex: columns[i].flex,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                            decoration: BoxDecoration(
                              border: i < columns.length - 1
                                  ? const Border(right: BorderSide(color: Color(0xFFEBEEF5)))
                                  : null,
                            ),
                            child: Text(
                              columns[i].label,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF606266),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                // Table Rows or Empty State
                if (logs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 38),
                    child: Center(
                      child: Text(
                        'No records found.',
                        style: TextStyle(
                          fontSize: 13.5,
                          color: Color(0xFF909399),
                        ),
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: logs.length,
                      itemBuilder: (context, idx) {
                        final row = logs[idx];
                        final cells = _cellsForLogRow(row, schoolId);
                        return Container(
                          decoration: BoxDecoration(
                            color: row.isPendingOffline
                                ? const Color(0xFFFFFBEB)
                                : (idx.isEven ? Colors.white : const Color(0xFFFAFAFA)),
                            border: const Border(
                              bottom: BorderSide(color: Color(0xFFEBEEF5)),
                            ),
                          ),
                          child: Row(
                            children: [
                              for (int i = 0; i < cells.length; i++)
                                Expanded(
                                  flex: columns[i].flex,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      border: i < cells.length - 1
                                          ? const Border(
                                              right: BorderSide(color: Color(0xFFEBEEF5)),
                                            )
                                          : null,
                                    ),
                                    child: Text(
                                      cells[i],
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: i == 0 && schoolId != 125
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        color: row.isPendingOffline
                                            ? const Color(0xFFB45309)
                                            : const Color(0xFF606266),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
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

            if (state.isLoadingLogs)
              Positioned.fill(
                child: Container(
                  color: Colors.white.withValues(alpha: 0.72),
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Loading attendance...',
                          style: TextStyle(fontSize: 12.5, color: Color(0xFF409EFF)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<String> _cellsForLogRow(HrisTodayLogEntry row, int schoolId) {
    String cleanCell(String? v) => (v == null || v.trim().isEmpty) ? '-' : v.trim();

    if (schoolId == 129) {
      return [
        cleanCell(row.employeeName),
        cleanCell(row.amIn),
        cleanCell(row.amOut),
        cleanCell(row.pmIn),
        cleanCell(row.pmOut),
      ];
    }
    if (schoolId == 125) {
      return [
        cleanCell(row.timeIn),
        cleanCell(row.timeOut),
      ];
    }
    return [
      cleanCell(row.employeeName),
      cleanCell(row.timeIn),
      cleanCell(row.timeOut),
    ];
  }

  Widget _buildRightPortalColumn(HrisAttendanceState state, Color themeColor) {
    final emp = state.activeEmployee;
    final showIdTypeDropdown =
        emp == null && state.config.idType == 2 && state.config.schoolId != 125;
    final placeholder = state.selectedTimeInType == 1 ? 'QR CODE' : 'RFID CODE';

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Optional ID Type Selector (`id_type == 2` in `OnlineAttendance.vue`)
        if (showIdTypeDropdown) ...[
          Center(
            child: SizedBox(
              width: 240,
              child: DropdownButtonFormField<int>(
                initialValue: state.selectedTimeInType,
                decoration: InputDecoration(
                  labelText: 'ID Type',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: Color(0xFFDCDFE6)),
                  ),
                ),
                items: const [
                  DropdownMenuItem(value: 2, child: Text('RFID')),
                  DropdownMenuItem(value: 1, child: Text('QR Code')),
                ],
                onChanged: (val) {
                  if (val != null) {
                    ref.read(hrisAttendanceProvider.notifier).setSelectedTimeInType(val);
                    _ensureScannerFocused();
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],

        // 2. Scanned Employee Card Display (`v-if="employee"`)
        if (emp != null) ...[
          _buildEmployeeFeedbackDisplay(state, emp, themeColor),
          const SizedBox(height: 18),
        ],

        // 3. Persistent `el-card` Scanner Input (always mounted so consecutive taps never drop!)
        Container(
          padding: EdgeInsets.all(emp != null ? 14 : 22),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: const Color(0xFFEBEEF5)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x14000000),
                blurRadius: 10,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _scannerController,
                focusNode: _scannerFocusNode,
                autofocus: true,
                onSubmitted: _handleScannerSubmit,
                style: const TextStyle(
                  fontSize: 15,
                  color: Color(0xFF303133),
                ),
                decoration: InputDecoration(
                  hintText: emp != null ? 'Ready for next scan ($placeholder)...' : placeholder,
                  hintStyle: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF909399),
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                  filled: true,
                  fillColor: Colors.white,
                  suffixIcon: state.isSubmittingTap
                      ? const Padding(
                          padding: EdgeInsets.all(11),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          icon: const Icon(
                            Icons.keyboard_return_rounded,
                            size: 18,
                            color: Color(0xFF909399),
                          ),
                          tooltip: 'Submit ID',
                          onPressed: () => _handleScannerSubmit(_scannerController.text),
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: Color(0xFFCED4DA)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: Color(0xFFCED4DA)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: themeColor, width: 1.5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEmployeeFeedbackDisplay(
    HrisAttendanceState state,
    HrisEmployeeInfo emp,
    Color themeColor,
  ) {
    final schoolId = state.config.schoolId;
    final double imgSize = (schoolId == 192 || schoolId == 82) ? 260 : 200;
    final hrisBaseUrl = ref.read(hrisAttendanceProvider.notifier).activeHrisBaseUrl;

    final logMsg = state.activeLogMessage?.trim() ?? '';
    final bool isPositiveStatus = state.isSavedOfflineFeedback ||
        (state.activeLogType &&
            !logMsg.toLowerCase().contains('invalid') &&
            !logMsg.toLowerCase().contains('no schedule'));

    final Color statusColor = state.isSavedOfflineFeedback
        ? const Color(0xFFD97706)
        : (isPositiveStatus ? const Color(0xFF16A34A) : const Color(0xFFF56C6C));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Employee Photo
        Container(
          width: imgSize,
          height: imgSize,
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFFE2E8F0), width: 2),
            boxShadow: const [
              BoxShadow(
                color: Color(0x14000000),
                blurRadius: 8,
                offset: Offset(0, 3),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: _buildEmployeePhoto(emp, hrisBaseUrl, imgSize),
        ),

        if (emp.isBirthday == 1) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFF59E0B)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cake_rounded, size: 15, color: Color(0xFFD97706)),
                SizedBox(width: 5),
                Text(
                  'Happy Birthday!',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFB45309),
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 14),

        // Greeting: `Hi <fullName>,`
        RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            style: TextStyle(
              color: themeColor,
              fontSize: schoolId == 192 ? 24 : 20,
              fontFamily: 'Segoe UI',
            ),
            children: [
              const TextSpan(text: 'Hi '),
              TextSpan(
                text: emp.fullName,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const TextSpan(text: ','),
            ],
          ),
        ),

        if (schoolId == 147 && state.submitTimeFormatted != null) ...[
          const SizedBox(height: 6),
          Text(
            state.submitTimeFormatted!,
            style: TextStyle(
              color: themeColor,
              fontSize: 34,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],

        // Status Message (`logMessage`)
        if (logMsg.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                state.isSavedOfflineFeedback
                    ? Icons.cloud_upload_outlined
                    : (isPositiveStatus
                        ? Icons.check_circle_outline_rounded
                        : Icons.cancel_outlined),
                color: statusColor,
                size: 24,
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  logMsg,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 21,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],

        // Inspirational Quote
        if (state.activeQuote != null) ...[
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              state.activeQuote!.text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFF334155),
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          if (state.activeQuote!.author != null &&
              state.activeQuote!.author!.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '- ${state.activeQuote!.author}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF6C757D),
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildEmployeePhoto(HrisEmployeeInfo emp, String hrisBaseUrl, double size) {
    if (emp.localImagePath != null &&
        emp.localImagePath!.isNotEmpty &&
        File(emp.localImagePath!).existsSync()) {
      return Image.file(
        File(emp.localImagePath!),
        width: size,
        height: size,
        fit: BoxFit.cover,
      );
    }

    final netUrl = emp.resolveNetworkPictureUrl(hrisBaseUrl);
    if (netUrl != null && netUrl.isNotEmpty) {
      return Image.network(
        netUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _defaultEmployeeAvatar(size),
      );
    }

    return _defaultEmployeeAvatar(size);
  }

  Widget _defaultEmployeeAvatar(double size) {
    return Container(
      width: size,
      height: size,
      color: const Color(0xFFE2E8F0),
      alignment: Alignment.center,
      child: Icon(
        Icons.person_rounded,
        size: size * 0.55,
        color: const Color(0xFF94A3B8),
      ),
    );
  }

  Widget _buildFloatingToast(String message, bool isError) {
    final bgColor = isError ? const Color(0xFFFEF0F0) : const Color(0xFFF0F9EB);
    final borderColor = isError ? const Color(0xFFFDE2E2) : const Color(0xFFE1F3D8);
    final textColor = isError ? const Color(0xFFF56C6C) : const Color(0xFF67C23A);

    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(minWidth: 320, maxWidth: 560),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: borderColor),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1F000000),
              blurRadius: 10,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isError ? Icons.error_rounded : Icons.check_circle_rounded,
              size: 18,
              color: textColor,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                message,
                style: TextStyle(
                  color: textColor,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 10),
            InkWell(
              onTap: () => ref.read(hrisAttendanceProvider.notifier).clearToast(),
              child: Icon(Icons.close, size: 16, color: textColor),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMaintenanceOverlay(AppRemoteStatus status, {required bool isHardLock}) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.72),
        alignment: Alignment.center,
        child: Container(
          width: 480,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isHardLock ? Icons.lock_rounded : Icons.build_circle_outlined,
                size: 56,
                color: isHardLock ? const Color(0xFFE11D48) : const Color(0xFFD97706),
              ),
              const SizedBox(height: 14),
              Text(
                isHardLock ? 'System Under Maintenance' : 'Server Maintenance Notice',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1E293B),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                status.maintenanceMessage,
                style: const TextStyle(fontSize: 14, color: Color(0xFF475569)),
                textAlign: TextAlign.center,
              ),
              if (!isHardLock) ...[
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: () {
                    ref.read(softLockDismissedProvider.notifier).dismiss();
                    _ensureScannerFocused();
                  },
                  icon: const Icon(Icons.offline_bolt_rounded, size: 18),
                  label: const Text('Continue in Offline Mode'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildForceUpdateOverlay(AppRemoteStatus status) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.72),
        alignment: Alignment.center,
        child: Container(
          width: 460,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.system_update_alt_rounded, size: 54, color: Color(0xFF2563EB)),
              const SizedBox(height: 14),
              const Text(
                'Update Available',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1E293B),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'A newer version (${status.latestVersion}) is required to continue.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Color(0xFF475569)),
              ),
              const SizedBox(height: 20),
              if (_isDownloadingUpdate) ...[
                LinearProgressIndicator(value: _downloadProgress > 0 ? _downloadProgress : null),
                const SizedBox(height: 8),
                Text(
                  'Downloading update... ${(_downloadProgress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 13, color: Color(0xFF475569)),
                ),
              ] else if (_isUpdateCompleted) ...[
                const Text(
                  'Installer launched! Please close the app to complete installation.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: Color(0xFF16A34A),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: () => exit(0),
                  child: const Text('Close App Now'),
                ),
              ] else ...[
                if (_updateError != null) ...[
                  Text(
                    _updateError!,
                    style: const TextStyle(fontSize: 13, color: Color(0xFFDC2626)),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                ],
                FilledButton.icon(
                  onPressed: status.downloadUrl.isNotEmpty
                      ? () => _startAppUpdate(status.downloadUrl)
                      : null,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Download & Install Update'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _formatPortalDateLine(DateTime dt, {required bool fullMonth}) {
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    const shortMonths = [
      'Jan.',
      'Feb.',
      'Mar.',
      'Apr.',
      'May.',
      'Jun.',
      'Jul.',
      'Aug.',
      'Sep.',
      'Oct.',
      'Nov.',
      'Dec.',
    ];
    const fullMonths = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final wd = weekdays[dt.weekday - 1];
    final m = fullMonth ? fullMonths[dt.month - 1] : shortMonths[dt.month - 1];
    final dd = dt.day.toString().padLeft(2, '0');
    return '$wd, $m $dd, ${dt.year}';
  }

  static String _formatPortalClockDigits(DateTime dt) {
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$h:$mm:$ss';
  }
}
