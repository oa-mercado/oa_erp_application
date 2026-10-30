import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import '../core/config/env_config.dart';
import '../core/constants/api_constants.dart';
import '../models/gate_model.dart';
import '../models/kiosk_state.dart';
import '../models/scan_response_model.dart';
import '../providers/kiosk_provider.dart';
import '../services/update_service.dart';
import 'activity_logs_dialog.dart';
import 'date_time_settings_dialog.dart';
import 'gate_selection_dialog.dart';

/// RFID Kiosk View faithful to the OrangeApps ERP web kiosk:
/// https://espserp.orangeapps.ph/qr/rfid/esps/c20ad4d76fe97759aa27a0c99bff6710
class ScannerView extends ConsumerStatefulWidget {
  final GateModel? initialGate;
  final String? networkLogoUrl;

  const ScannerView({
    super.key,
    this.initialGate,
    this.networkLogoUrl,
  });

  @override
  ConsumerState<ScannerView> createState() => _ScannerViewState();
}

class _ScannerViewState extends ConsumerState<ScannerView> with WindowListener {
  final FocusNode _focusNode = FocusNode();
  bool _isFullScreen = true;
  String? _dynamicLogoUrl;

  bool _isDownloadingUpdate = false;
  double _downloadProgress = 0.0;
  String? _updateError;
  bool _isUpdateCompleted = false;

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
        if (mounted) {
          setState(() {
            _downloadProgress = p;
          });
        }
      },
    );

    if (file != null && mounted) {
      // Launch installer detached so it installs the new build in the background
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

  void _closeAppAfterUpdate() {
    exit(0);
  }

  Future<void> _toggleFullScreen() async {
    final isFull = await windowManager.isFullScreen();
    await windowManager.setFullScreen(!isFull);
    if (mounted) {
      setState(() {
        _isFullScreen = !isFull;
      });
      _focusNode.requestFocus();
    }
  }

  Future<void> _handleCloseApp() async {
    final shouldClose = await _showKioskDialog<bool>(
      (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Row(
          children: [
            Icon(Icons.power_settings_new, color: Color(0xFFE11D48)),
            SizedBox(width: 8),
            Text('Close Kiosk', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: const Text(
          'Are you sure you want to close the RFID Kiosk application?',
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

  Future<void> _loadSchoolLogo() async {
    final localDb = ref.read(localDbServiceProvider);
    final directLogo = ref.read(apiServiceProvider).schoolLogoUrl ?? EnvConfig.schoolLogoUrl;
    if (directLogo.isNotEmpty) {
      if (mounted && _dynamicLogoUrl != directLogo) {
        setState(() {
          _dynamicLogoUrl = directLogo;
        });
      }
      if (localDb.getCachedSchoolLogoPath() == null) {
        unawaited(localDb.downloadAndCacheSchoolLogo(directLogo).then((saved) {
          if (mounted && saved != null) setState(() {});
        }));
      }
    }
    final activeGate = ref.read(activeGateProvider);
    final scraped = await ref.read(apiServiceProvider).scrapeKioskAppearance(
      branchCode: activeGate.branchCode,
      gateId: activeGate.id,
      localDb: localDb,
    );
    final discoveredLogo = scraped['logo_url'];
    if (discoveredLogo != null && discoveredLogo.isNotEmpty) {
      if (mounted && _dynamicLogoUrl != discoveredLogo) {
        setState(() {
          _dynamicLogoUrl = discoveredLogo;
        });
      }
      unawaited(localDb.downloadAndCacheSchoolLogo(discoveredLogo).then((saved) {
        if (mounted && saved != null) setState(() {});
      }));
    }
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.setTitle(EnvConfig.appName);
    }
    windowManager.isFullScreen().then((isFull) {
      if (mounted && _isFullScreen != isFull) {
        setState(() => _isFullScreen = isFull);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadSchoolLogo();
      if (widget.initialGate != null) {
        ref.read(kioskProvider.notifier).setGate(widget.initialGate!);
      } else {
        // If a previously saved gate exists in Local DB, use it automatically!
        final savedGate = ref.read(localDbServiceProvider).getSavedGate();
        if (savedGate != null) {
          ref.read(kioskProvider.notifier).setGate(savedGate);
        } else {
          _showGateSelectionDialog();
        }
      }
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void onWindowEnterFullScreen() {
    if (mounted && !_isFullScreen) {
      setState(() => _isFullScreen = true);
    }
  }

  @override
  void onWindowLeaveFullScreen() {
    if (mounted && _isFullScreen) {
      setState(() => _isFullScreen = false);
    }
  }

  @override
  void onWindowMaximize() {
    if (mounted && !_isFullScreen) {
      setState(() => _isFullScreen = true);
    }
  }

  @override
  void onWindowUnmaximize() {
    windowManager.isFullScreen().then((isFull) {
      if (mounted && _isFullScreen != isFull) {
        setState(() => _isFullScreen = isFull);
      }
    });
  }

  Future<T?> _showKioskDialog<T>(WidgetBuilder builder, {bool barrierDismissible = true}) async {
    try {
      final listener = ref.read(kioskProvider.notifier).listener;
      listener.isPaused = true;
      listener.clearBuffer();
    } catch (_) {}

    try {
      return await showDialog<T>(
        context: context,
        barrierDismissible: barrierDismissible,
        builder: builder,
      );
    } finally {
      try {
        final listener = ref.read(kioskProvider.notifier).listener;
        listener.isPaused = false;
        listener.clearBuffer();
      } catch (_) {}
      if (mounted) {
        _focusNode.requestFocus();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _focusNode.requestFocus();
          }
        });
      }
    }
  }

  Future<void> _showGateSelectionDialog() async {
    final currentGate = ref.read(activeGateProvider);
    final localDb = ref.read(localDbServiceProvider);
    final selectedGate = await _showKioskDialog<GateModel>(
      (ctx) => GateSelectionDialog(
        currentBranchCode: currentGate.branchCode,
        localDb: localDb,
      ),
    );

    if (selectedGate != null && mounted) {
      ref.read(kioskProvider.notifier).setGate(selectedGate);
      _loadSchoolLogo();
    }
  }

  Future<void> _showActivityLogsDialog() async {
    await _showKioskDialog<void>(
      (ctx) => const ActivityLogsDialog(),
    );
  }

  Future<void> _showDateTimeSettingsDialog() async {
    final updated = await _showKioskDialog<bool>(
      (ctx) => const DateTimeSettingsDialog(),
    );
    if (updated == true && mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Kiosk Date & Time updated and saved.'),
          backgroundColor: Color(0xFF16A34A),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _manualSyncRoster() async {
    final isOffline = ref.read(isOfflineProvider);
    if (isOffline) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot resync while offline.'),
            backgroundColor: Color(0xFFDC2626),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    try {
      await ref.read(kioskProvider.notifier).syncRosterFromServer();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Application has been resynced.'),
            backgroundColor: Color(0xFF16A34A),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Resync error: $e'),
            backgroundColor: const Color(0xFFDC2626),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      _focusNode.requestFocus();
    }
  }

  String _formatDate(DateTime dt) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s $period';
  }

  Widget _buildSchoolLogo(bool isOffline, {bool isLargeLayout = false}) {
    final localDb = ref.watch(localDbServiceProvider);
    final cachedLocalPath = localDb.getCachedSchoolLogoPath();
    final maxW = isLargeLayout ? 960.0 : 580.0;
    final maxH = isLargeLayout ? 600.0 : 420.0;

    // 1. If we have a local cached image on disk, ALWAYS render directly from local disk!
    // Passing explicit width & height with BoxFit.contain forces images smaller than
    // the box (such as 612x342) to scale UP to fill the available space!
    if (cachedLocalPath != null && File(cachedLocalPath).existsSync()) {
      return Image.file(
        File(cachedLocalPath),
        width: maxW,
        height: maxH,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        errorBuilder: (ctx, err, stack) => _buildPlaceholderLogo(isLargeLayout: isLargeLayout),
      );
    }

    // 2. If not yet saved on disk, attempt Image.network and kick off disk caching
    final logoUrl = widget.networkLogoUrl ??
        _dynamicLogoUrl ??
        ref.watch(apiServiceProvider).schoolLogoUrl ??
        EnvConfig.schoolLogoUrl;

    if (logoUrl.trim().isNotEmpty) {
      return Image.network(
        logoUrl.trim(),
        width: maxW,
        height: maxH,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return _buildPlaceholderLogo(isLargeLayout: isLargeLayout);
        },
        errorBuilder: (context, error, stackTrace) =>
            _buildPlaceholderLogo(isLargeLayout: isLargeLayout),
      );
    }

    // 3. Fallback to built-in placeholder asset
    return _buildPlaceholderLogo(isLargeLayout: isLargeLayout);
  }

  Widget _buildPlaceholderLogo({bool isLargeLayout = false}) {
    final logoSize = isLargeLayout ? 540.0 : 380.0;
    return Image.asset(
      'assets/images/placeholder_logo.png',
      width: logoSize,
      height: logoSize,
      fit: BoxFit.contain,
      errorBuilder: (ctx, err, stack) => Icon(
        Icons.school_outlined,
        size: logoSize * 0.7,
        color: Colors.white,
      ),
    );
  }

  Widget _buildAssetDownloadProgressBar(AssetSyncProgress assetProgress) {
    if (assetProgress.isFinished) {
      return Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.black45,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: const Color(0xFF22C55E).withValues(alpha: 0.6)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              Icons.check_circle,
              size: 15,
              color: Color(0xFF22C55E),
            ),
            SizedBox(width: 6),
            Text(
              'Assets downloaded',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    final processed = assetProgress.processed;
    final total = assetProgress.total;
    final ratio = assetProgress.progressRatio;

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Downloading assets ($processed / $total)',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 90,
            height: 6,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: ratio,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeGate = ref.watch(activeGateProvider);
    final isOffline = ref.watch(isOfflineProvider);
    final isSyncingRoster = ref.watch(isSyncingRosterProvider);
    final assetProgress = ref.watch(assetSyncProgressProvider);
    final kioskState = ref.watch(kioskScanProvider);
    final remoteStatus = ref.watch(remoteStatusProvider);

    final isUpdateAvailable = !isOffline &&
        UpdateAndMaintenanceService.isUpdateAvailable(
          EnvConfig.appVersion,
          remoteStatus.latestVersion,
        );

    final placeName = activeGate.placeName.isNotEmpty
        ? activeGate.placeName
        : EnvConfig.defaultGateName;

    final screenWidth = MediaQuery.of(context).size.width;
    final isLargeLayout = _isFullScreen || screenWidth >= 1400;

    return Scaffold(
      backgroundColor: EnvConfig.backgroundColor,
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.escape) {
              if (_isFullScreen) {
                _toggleFullScreen();
                return KeyEventResult.handled;
              }
            }
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => _focusNode.requestFocus(),
          child: Stack(
            children: [
              SafeArea(
                child: Column(
                  children: [
                    const SizedBox(height: 14),

                    // Main 2-Column Section (Left: Gate Name & Logo, Right: Tapping Graphic)
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // LEFT COLUMN (~58%): Gate Name on Top + Large School Logo
                          Expanded(
                            flex: 14,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                // Gate Name (Clickable to switch gate if needed)
                                MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: InkWell(
                                    onTap: _showGateSelectionDialog,
                                    splashColor: Colors.transparent,
                                    highlightColor: Colors.transparent,
                                    mouseCursor: SystemMouseCursors.click,
                                    child: Text(
                                      placeName,
                                      style: const TextStyle(
                                        fontSize: 30,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                        letterSpacing: 0.5,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 35),

                                // Dynamic School Logo (with offline white circular placeholder)
                                _buildSchoolLogo(isOffline, isLargeLayout: isLargeLayout),
                              ],
                            ),
                          ),

                          // RIGHT COLUMN (~42%): RFID Tapping Graphic (Dynamically expands when fullscreen)
                          Expanded(
                            flex: 10,
                            child: Center(
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeInOut,
                                width: isLargeLayout ? 620 : 440,
                                height: isLargeLayout ? 620 : 440,
                                child: Image.asset(
                                  'assets/images/rfid_logo_new.png',
                                  fit: BoxFit.contain,
                                  errorBuilder: (ctx, err, stack) => Icon(
                                    Icons.contactless,
                                    size: isLargeLayout ? 380 : 260,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // BOTTOM BRANDING: "Powered by" + oa1.png
                    Padding(
                      padding: const EdgeInsets.only(bottom: 24.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Powered by',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Image.asset(
                            'assets/images/oa1.png',
                            width: 200,
                            height: 70,
                            fit: BoxFit.contain,
                            errorBuilder: (ctx, err, stack) => const Text(
                              'OrangeApps',
                              style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // DETERMINISTIC FLOATING CARD STACK (Push-Left & Stacking)
              if (kioskState.hasActiveCards)
                Container(
                  color: Colors.black54,
                  alignment: Alignment.center,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          for (int i = 0; i < kioskState.activeCards.length; i++) ...[
                            if (i > 0) const SizedBox(width: 16),
                            _buildAnimatedKioskCard(
                              card: kioskState.activeCards[i],
                              isPrevious: i < kioskState.activeCards.length - 1,
                              branchCode: activeGate.branchCode,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),


              // Top Left Status & Action Controls
              Positioned(
                top: 14,
                left: 14,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Connection Signal Icon (Green = Online, Gray = Offline)
                    Tooltip(
                      message: isOffline ? 'Offline' : 'Online',
                      child: Container(
                        width: 32,
                        height: 32,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Icon(
                          Icons.wifi,
                          size: 18,
                          color: isOffline
                              ? const Color(0xFF9CA3AF) // Gray when offline
                              : const Color(0xFF22C55E), // Green when online
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Manual Resync Button
                    Tooltip(
                      message: isSyncingRoster
                          ? 'Resyncing application...'
                          : 'Resync application',
                      child: Material(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(4),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(4),
                          onTap: (isSyncingRoster || isOffline) ? null : _manualSyncRoster,
                          child: Container(
                            width: 32,
                            height: 32,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: isSyncingRoster
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                    ),
                                  )
                                : Icon(
                                    Icons.sync,
                                    size: 18,
                                    color: isOffline ? Colors.white38 : Colors.white,
                                  ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Activity Logs Button
                    Tooltip(
                      message: 'Activity Logs',
                      child: Material(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(4),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(4),
                          onTap: _showActivityLogsDialog,
                          child: Container(
                            width: 32,
                            height: 32,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: const Icon(
                              Icons.history,
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Live Kiosk Clock & Date (Clickable to adjust Date & Time)
                    KioskClockPill(onTap: _showDateTimeSettingsDialog),

                    // Asset Download Progress Bar
                    if (assetProgress.isDownloading || assetProgress.isFinished) ...[
                      const SizedBox(width: 8),
                      _buildAssetDownloadProgressBar(assetProgress),
                    ],
                  ],
                ),
              ),

              // Top-Right Window Controls: Fullscreen Toggle & Close Button
              Positioned(
                top: 14,
                right: 14,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Fullscreen Toggle Button (matching el-button in RfidReaderLink.vue)
                    Tooltip(
                      message: _isFullScreen ? 'Exit Fullscreen' : 'Fullscreen',
                      child: Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(4),
                        elevation: 2,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(4),
                          mouseCursor: SystemMouseCursors.click,
                          onTap: _toggleFullScreen,
                          child: Container(
                            width: 32,
                            height: 32,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: const Color(0xFFDCDFE6)),
                            ),
                            child: Icon(
                              _isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
                              size: 20,
                              color: const Color(0xFF606266),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Close Application Button
                    Tooltip(
                      message: 'Close Application',
                      child: Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(4),
                        elevation: 2,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(4),
                          mouseCursor: SystemMouseCursors.click,
                          onTap: _handleCloseApp,
                          child: Container(
                            width: 32,
                            height: 32,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: const Color(0xFFDCDFE6)),
                            ),
                            child: const Icon(
                              Icons.close,
                              size: 20,
                              color: Color(0xFF606266),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // FULL-SCREEN FORCE UPDATE BLOCKER & DOWNLOAD PROGRESS
              if (isUpdateAvailable && !_isUpdateCompleted)
                Container(
                  color: const Color(0xEB000000), // ~92% dark backdrop
                  alignment: Alignment.center,
                  child: Container(
                    width: 480,
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 36),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black54,
                          blurRadius: 24,
                          offset: Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFF6FF),
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFFBFDBFE), width: 2),
                          ),
                          child: Icon(
                            _isDownloadingUpdate ? Icons.downloading : Icons.system_update_alt,
                            size: 38,
                            color: const Color(0xFF2563EB),
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'APP UPDATE REQUIRED',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.8,
                            color: Color(0xFF1E3A8A),
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'A required update (${remoteStatus.latestVersion}) is available. Please update the application to continue scanning.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Color(0xFF475569),
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 20),

                        if (!_isDownloadingUpdate) ...[
                          if (_updateError != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 14.0),
                              child: Text(
                                _updateError!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFFDC2626),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: ElevatedButton.icon(
                              onPressed: () => _startAppUpdate(remoteStatus.downloadUrl),
                              icon: const Icon(Icons.download, color: Colors.white, size: 20),
                              label: Text(
                                'Update to ${remoteStatus.latestVersion}',
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF2563EB),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                elevation: 2,
                              ),
                            ),
                          ),
                        ] else ...[
                          Text(
                            'Downloading update... ${(_downloadProgress * 100).toInt()}%',
                            style: const TextStyle(
                              fontSize: 14,
                              color: Color(0xFF1E293B),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              minHeight: 8,
                              value: _downloadProgress > 0 ? _downloadProgress : null,
                              backgroundColor: const Color(0xFFE2E8F0),
                              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF2563EB)),
                            ),
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            'Please wait while the update is being downloaded...',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

              // UPDATE COMPLETED PROMPT (Does NOT close immediately; prompts user with Close App button)
              if (_isUpdateCompleted)
                Container(
                  color: const Color(0xEB000000), // ~92% dark backdrop
                  alignment: Alignment.center,
                  child: Container(
                    width: 480,
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 36),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black54,
                          blurRadius: 24,
                          offset: Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: const Color(0xFFECFDF5),
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFFA7F3D0), width: 2),
                          ),
                          child: const Icon(
                            Icons.check_circle_outline,
                            size: 42,
                            color: Color(0xFF059669),
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'DOWNLOAD SUCCESSFUL!',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.8,
                            color: Color(0xFF065F46),
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'The installer has finished downloading and has been launched. Please close this app, and reopen it once the installation finishes.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            color: Color(0xFF334155),
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: ElevatedButton.icon(
                            onPressed: _closeAppAfterUpdate,
                            icon: const Icon(Icons.exit_to_app, color: Colors.white, size: 20),
                            label: const Text(
                              'Close App and Complete Setup',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF059669),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              elevation: 2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // Fullscreen Maintenance Mode Blocker (blocks all scanning and interactions)
              if (remoteStatus.maintenance && !isOffline)
                Container(
                  color: const Color(0xEB000000), // ~92% black
                  alignment: Alignment.center,
                  child: Container(
                    width: 500,
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 40),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black54,
                          blurRadius: 20,
                          offset: Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF2F2),
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFFFECACA), width: 2),
                          ),
                          child: const Icon(
                            Icons.construction,
                            size: 38,
                            color: Color(0xFFDC2626),
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'SYSTEM UNDER MAINTENANCE',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.8,
                            color: Color(0xFF991B1B),
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          remoteStatus.maintenanceMessage,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Color(0xFF475569),
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 24),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.block, size: 16, color: Color(0xFF64748B)),
                              SizedBox(width: 8),
                              Text(
                                'Card scanning is temporarily disabled',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF475569),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // Subtle Version Indicator (Far Bottom-Left)
              Positioned(
                bottom: 8,
                left: 12,
                child: Text(
                  EnvConfig.appVersion,
                  style: const TextStyle(
                    color: Colors.white24,
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }


  /// Animated Kiosk Card: expands to 800px when active (newest),
  /// or smoothly shrinks to 280px when pushed to the left by a newer card.
  /// Fixed height (480px) guarantees cards never stretch or wrap into a tall ribbon.
  Widget _buildAnimatedKioskCard({
    required ActiveKioskCard card,
    required bool isPrevious,
    required String branchCode,
  }) {
    const cardHeight = 480.0;
    final cardWidth = isPrevious ? 280.0 : 800.0;

    return AnimatedContainer(
      key: ValueKey('kiosk_card_${card.id}'),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      width: cardWidth,
      height: cardHeight,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 28, offset: Offset(0, 12)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
          return Stack(
            alignment: Alignment.topCenter,
            children: <Widget>[
              ...previousChildren,
              ?currentChild,
            ],
          );
        },
        child: isPrevious
            ? SizedBox(
                key: ValueKey('min_${card.id}'),
                width: 280.0,
                height: cardHeight,
                child: _buildMinimizedCardContent(card, branchCode),
              )
            : SizedBox(
                key: ValueKey('full_${card.id}'),
                width: 800.0,
                height: cardHeight,
                child: _buildFullCardContent(card, branchCode),
              ),
      ),
    );
  }

  /// Compact Minimized Card when pushed to the left
  Widget _buildMinimizedCardContent(ActiveKioskCard card, String branchCode) {
    final info = card.studentInfo;
    String title = 'CARD SCANNED';
    if (card.isSuccess && info != null) {
      title = info.name.toUpperCase();
    } else if (card.isError) {
      title = 'NOT FOUND';
    } else if (card.isOfflineSaved) {
      title = 'PLEASE CONTINUE';
    } else if (card.isCooldown) {
      title = 'COOLDOWN';
    }

    final fullImageUrl = (info != null)
        ? info.getFullImageUrl(
            branchCode.isNotEmpty ? EnvConfig.getBranchBaseUrl(branchCode) : ApiConstants.defaultBaseUrl,
          )
        : null;

    return Column(
      children: [
        // Compact Dynamic School Header
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
          color: EnvConfig.backgroundColor,
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),

        // Compact Body (Expanded with spaceEvenly to perfectly fill card height)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Avatar (115x115)
                ClipOval(
                  child: Container(
                    width: 115,
                    height: 115,
                    color: const Color(0xFFF1F5F9),
                    child: card.isProcessing
                        ? Stack(
                            alignment: Alignment.center,
                            children: [
                              const Icon(Icons.person, size: 70, color: Color(0xFFCBD5E1)),
                              SizedBox(
                                width: 48,
                                height: 48,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                  valueColor: AlwaysStoppedAnimation<Color>(EnvConfig.backgroundColor),
                                ),
                              ),
                            ],
                          )
                        : card.isSuccess
                            ? _buildStudentAvatarImage(info, fullImageUrl, 115)
                            : (card.isError)
                                ? const Icon(Icons.error_outline_rounded, size: 68, color: Color(0xFFDC2626))
                                : (card.isOfflineSaved)
                                    ? const Icon(Icons.check_circle_outline_rounded, size: 68, color: Color(0xFF059669))
                                    : (card.isCooldown)
                                        ? const Icon(Icons.timer_outlined, size: 68, color: Color(0xFFD97706))
                                        : _buildDefaultAvatar(115),
                  ),
                ),

                // Student ID (never display RFID code; show Student/Person ID or status)
                Text(
                  (info != null && info.personId.isNotEmpty)
                      ? info.personId
                      : (card.isSuccess
                          ? 'N/A'
                          : (card.isError
                              ? 'NOT FOUND'
                              : (card.isOfflineSaved
                                  ? 'PLEASE CONTINUE'
                                  : (card.isCooldown
                                      ? 'WAIT ${card.cooldownSecondsRemaining ?? 15}s'
                                      : 'LOADING...')))),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                    color: Color(0xFF0F172A),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),

                // Date & Time or Status Badge (never show Entrance/Exit badge)
                if (card.isSuccess) ...[
                  Text(
                    info?.date ?? _formatDate(card.scannedAt),
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xFF64748B),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    info?.time ?? _formatTime(card.scannedAt),
                    style: const TextStyle(
                      fontSize: 15,
                      color: Color(0xFF1E293B),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ] else ...[
                  if (card.isOfflineSaved)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFECFDF5),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFA7F3D0)),
                      ),
                      child: const Text(
                        'Scanned',
                        style: TextStyle(
                          color: Color(0xFF059669),
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    )
                  else if (card.isCooldown)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFFBEB),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFFDE68A)),
                      ),
                      child: Text(
                        'Wait ${card.cooldownSecondsRemaining ?? 15}s',
                        style: const TextStyle(
                          color: Color(0xFFD97706),
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    )
                  else if (card.isError)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFFECACA)),
                      ),
                      child: const Text(
                        'Invalid',
                        style: TextStyle(
                          color: Color(0xFFDC2626),
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: const Text(
                        'Loading...',
                        style: TextStyle(
                          color: Color(0xFF64748B),
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  Text(
                    _formatTime(card.scannedAt),
                    style: const TextStyle(
                      fontSize: 15,
                      color: Color(0xFF64748B),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Renders student avatar prioritizing downloaded local file in `local_db/images/`, then network URL, then default silhouette
  Widget _buildStudentAvatarImage(StudentInfoModel? info, String? fullImageUrl, double size) {
    final localPath = info?.localImagePath;
    if (localPath != null && localPath.isNotEmpty) {
      final file = File(localPath);
      if (file.existsSync()) {
        return Image.file(
          file,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (ctx, err, stack) => _buildDefaultAvatar(size),
        );
      }
    }

    if (fullImageUrl != null &&
        fullImageUrl.isNotEmpty &&
        !fullImageUrl.contains('default-picture.png')) {
      return Image.network(
        fullImageUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (ctx, err, stack) => _buildDefaultAvatar(size),
      );
    }

    return _buildDefaultAvatar(size);
  }

  Widget _buildDefaultAvatar(double size) {
    return Image.asset(
      'assets/images/default-picture.png',
      width: size,
      height: size,
      fit: BoxFit.cover,
      errorBuilder: (ctx, err, stack) => Icon(
        Icons.person,
        size: size * 0.6,
        color: const Color(0xFF94A3B8),
      ),
    );
  }

  /// Full Card Content when active and prominent
  Widget _buildFullCardContent(ActiveKioskCard card, String branchCode) {
    if (card.isProcessing) {
      return _buildProcessingContent(card.scannedAt);
    }
    if (card.isSuccess && card.studentInfo != null) {
      return _buildStudentCardContent(card.studentInfo!, card.scannedAt, branchCode);
    }
    if (card.isCooldown) {
      return _buildCooldownContent(card.cooldownSecondsRemaining ?? 15, card.scannedAt);
    }
    if (card.isError) {
      return _buildCardNotFoundContent(card.errorMessage ?? 'Card Not Found');
    }
    if (card.isOfflineSaved) {
      return _buildOfflineSavedContent(card.queuedCount ?? 1, card.scannedAt);
    }
    return const SizedBox.shrink();
  }

  /// Scenario 1 (Online, not in Local DB yet): Shows "YOUR CARD HAS BEEN SCANNED" while loading
  Widget _buildProcessingContent(DateTime scannedAt) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Card Header: Animated status
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 28),
          color: EnvConfig.backgroundColor,
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              SizedBox(width: 16),
              Text(
                'YOUR CARD HAS BEEN SCANNED',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),

        // Card Body
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(40, 28, 40, 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Circular Profile Placeholder with loading indicator
                ClipOval(
                  child: Container(
                    width: 190,
                    height: 190,
                    color: const Color(0xFFF1F5F9),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        const Icon(
                          Icons.person,
                          size: 110,
                          color: Color(0xFFCBD5E1),
                        ),
                        SizedBox(
                          width: 76,
                          height: 76,
                          child: CircularProgressIndicator(
                            strokeWidth: 4,
                            valueColor: AlwaysStoppedAnimation<Color>(EnvConfig.backgroundColor),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 36),

                // Details Column with loading indicators
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Row(
                        children: [
                          Text(
                            'STATUS : ',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF64748B),
                              fontSize: 18,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              'LOADING PROFILE...',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 24,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      // DATE
                      Row(
                        children: [
                          const Text(
                            'DATE : ',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF64748B),
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            _formatDate(scannedAt),
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 18,
                              color: Color(0xFF1E293B),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // TIME
                      Row(
                        children: [
                          const Text(
                            'TIME : ',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF64748B),
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            _formatTime(scannedAt),
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 18,
                              color: Color(0xFF1E293B),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),

                      // Linear Progress bar
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          minHeight: 10,
                          backgroundColor: const Color(0xFFF1F5F9),
                          valueColor: AlwaysStoppedAnimation<Color>(EnvConfig.backgroundColor),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Your card has been scanned. Fetching credentials...',
                        style: TextStyle(
                          fontSize: 14,
                          color: Color(0xFF94A3B8),
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // Card Footer
        Padding(
          padding: const EdgeInsets.only(bottom: 20.0),
          child: Image.asset(
            'assets/images/oa.png',
            width: 190,
            height: 58,
            fit: BoxFit.contain,
            errorBuilder: (ctx, err, stack) => Text(
              'OrangeApps',
              style: TextStyle(color: EnvConfig.backgroundColor, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ],
    );
  }

  /// Full student tap confirmation card (works both Online and Offline via Local DB)
  Widget _buildStudentCardContent(StudentInfoModel info, DateTime scannedAt, String branchCode) {
    final isStudent = info.type?.toLowerCase() != 'employee';
    final idLabel = isStudent ? 'STUDENT # : ' : 'EMPLOYEE # : ';
    final fullImageUrl = info.getFullImageUrl(
      branchCode.isNotEmpty ? EnvConfig.getBranchBaseUrl(branchCode) : ApiConstants.defaultBaseUrl,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Card Header: Student Name (flush at top, outer AnimatedContainer clips corners)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 24),
          color: EnvConfig.backgroundColor,
          child: Text(
            info.name.toUpperCase(),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),

        // Card Body
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(40, 24, 40, 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Circular Profile Picture (prioritizes downloaded local image for 0ms & offline display)
                ClipOval(
                  child: Container(
                    width: 190,
                    height: 190,
                    color: const Color(0xFFF1F5F9),
                    child: _buildStudentAvatarImage(info, fullImageUrl, 190),
                  ),
                ),
                const SizedBox(width: 36),

                // Details Column
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Student ID
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            idLabel,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF64748B),
                              fontSize: 18,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              info.personId.isNotEmpty ? info.personId : 'N/A',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 32,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      // DATE
                      Row(
                        children: [
                          const Text(
                            'DATE : ',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF64748B),
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            info.date ?? _formatDate(scannedAt),
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 18,
                              color: Color(0xFF1E293B),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // TIME
                      Row(
                        children: [
                          const Text(
                            'TIME : ',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF64748B),
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            info.time ?? _formatTime(scannedAt),
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 18,
                              color: Color(0xFF1E293B),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // Card Footer: Powered by OrangeApps logo
        Padding(
          padding: const EdgeInsets.only(bottom: 20.0),
          child: Image.asset(
            'assets/images/oa.png',
            width: 190,
            height: 58,
            fit: BoxFit.contain,
            errorBuilder: (ctx, err, stack) => Text(
              'OrangeApps',
              style: TextStyle(color: EnvConfig.backgroundColor, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ],
    );
  }

  /// Error overlay for unregistered RFID cards
  Widget _buildCardNotFoundContent(String errorMessage) {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 76,
            color: Color(0xFFDC2626),
          ),
          const SizedBox(height: 16),
          const Text(
            'CARD NOT FOUND',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Color(0xFFDC2626),
              letterSpacing: 0.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Text(
            errorMessage,
            style: const TextStyle(
              fontSize: 15,
              color: Color(0xFF475569),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          Image.asset(
            'assets/images/oa.png',
            width: 140,
            height: 40,
            fit: BoxFit.contain,
            errorBuilder: (ctx, err, stack) => const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  /// Scenario 1 (Offline & not in Local DB yet): No loading spinner, says "PLEASE CONTINUE"
  Widget _buildOfflineSavedContent(int queuedCount, DateTime scannedAt) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Card Header
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 24),
          color: EnvConfig.backgroundColor,
          child: const Text(
            'YOUR CARD HAS BEEN SCANNED',
            style: TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(40, 24, 40, 20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                const Icon(
                  Icons.check_circle_outline_rounded,
                  size: 96,
                  color: Color(0xFF059669),
                ),
                const Text(
                  'PLEASE CONTINUE',
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF059669),
                    letterSpacing: 0.8,
                  ),
                  textAlign: TextAlign.center,
                ),
                Text(
                  '${_formatDate(scannedAt)} • ${_formatTime(scannedAt)}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1E293B),
                  ),
                  textAlign: TextAlign.center,
                ),
                const Text(
                  'Tap recorded locally and will sync automatically when online.',
                  style: TextStyle(
                    fontSize: 16,
                    color: Color(0xFF64748B),
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
        // Card Footer
        Padding(
          padding: const EdgeInsets.only(bottom: 20.0),
          child: Image.asset(
            'assets/images/oa.png',
            width: 190,
            height: 58,
            fit: BoxFit.contain,
            errorBuilder: (ctx, err, stack) => const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  /// Tap Cooldown warning confirmation content
  Widget _buildCooldownContent(int remainingSeconds, DateTime scannedAt) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.access_time_rounded,
            size: 80,
            color: Color(0xFFD97706),
          ),
          const SizedBox(height: 14),
          const Text(
            'ALREADY SCANNED',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: Color(0xFFD97706),
              letterSpacing: 0.8,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Text(
            'Please wait $remainingSeconds seconds before tapping again',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: Color(0xFF475569),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Image.asset(
            'assets/images/oa.png',
            width: 140,
            height: 40,
            fit: BoxFit.contain,
            errorBuilder: (ctx, err, stack) => const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}
