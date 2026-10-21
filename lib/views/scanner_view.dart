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

class _ScannerViewState extends ConsumerState<ScannerView> {
  final FocusNode _focusNode = FocusNode();
  bool _isFullScreen = false;
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

  Future<void> _loadSchoolLogo() async {
    final apiService = ref.read(apiServiceProvider);
    final url = await apiService.ensureSessionAndFetchLogo();
    if (mounted && url != null && url.isNotEmpty && url != _dynamicLogoUrl) {
      setState(() {
        _dynamicLogoUrl = url;
      });
    }
  }

  @override
  void initState() {
    super.initState();

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
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _showGateSelectionDialog() async {
    final currentGate = ref.read(activeGateProvider);
    final selectedGate = await showDialog<GateModel>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => GateSelectionDialog(currentBranchCode: currentGate.branchCode),
    );

    if (selectedGate != null && mounted) {
      ref.read(kioskProvider.notifier).setGate(selectedGate);
      _loadSchoolLogo();
    }
    _focusNode.requestFocus();
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

  Widget _buildSchoolLogo(bool isOffline) {
    if (isOffline) {
      return _buildPlaceholderLogo();
    }
    final logoUrl =
        widget.networkLogoUrl ?? _dynamicLogoUrl ?? ref.read(apiServiceProvider).schoolLogoUrl;
    if (logoUrl != null && logoUrl.trim().isNotEmpty) {
      return Image.network(
        logoUrl.trim(),
        width: 390,
        height: 390,
        fit: BoxFit.contain,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return _buildPlaceholderLogo();
        },
        errorBuilder: (context, error, stackTrace) => _buildPlaceholderLogo(),
      );
    }
    return _buildPlaceholderLogo();
  }

  Widget _buildPlaceholderLogo() {
    return Image.asset(
      'assets/images/placeholder_logo.png',
      color: Colors.white, // White circular logo on maroon background
      width: 390,
      height: 390,
      fit: BoxFit.contain,
      errorBuilder: (ctx, err, stack) => const Icon(
        Icons.school_outlined,
        size: 260,
        color: Colors.white,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeGate = ref.watch(activeGateProvider);
    final isOffline = ref.watch(isOfflineProvider);
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
                                InkWell(
                                  onTap: _showGateSelectionDialog,
                                  splashColor: Colors.transparent,
                                  highlightColor: Colors.transparent,
                                  child: Text(
                                    placeName,
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                      letterSpacing: 0.5,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                                const SizedBox(height: 20),

                                // Dynamic School Logo (with offline white circular placeholder)
                                _buildSchoolLogo(isOffline),
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
                                width: _isFullScreen ? 520 : 360,
                                height: _isFullScreen ? 520 : 360,
                                child: Image.asset(
                                  'assets/images/rfid_logo_new.png',
                                  fit: BoxFit.contain,
                                  errorBuilder: (ctx, err, stack) => Icon(
                                    Icons.contactless,
                                    size: _isFullScreen ? 320 : 220,
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


              // Minimal Connection Signal Icon (Top Left: Green = Online, Gray = Offline - UI only)
              Positioned(
                top: 14,
                left: 14,
                child: Tooltip(
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
              ),

              // Fullscreen Toggle Button (matching el-button in RfidReaderLink.vue)
              Positioned(
                top: 14,
                right: 14,
                child: Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(4),
                  elevation: 2,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(4),
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


  /// Animated Kiosk Card: expands to 560px when active (newest),
  /// or smoothly shrinks to 210px when pushed to the left by a newer card.
  /// Fixed height (340px) guarantees cards never stretch or wrap into a tall ribbon.
  Widget _buildAnimatedKioskCard({
    required ActiveKioskCard card,
    required bool isPrevious,
    required String branchCode,
  }) {
    const cardHeight = 340.0;
    final cardWidth = isPrevious ? 210.0 : 560.0;

    return AnimatedContainer(
      key: ValueKey('kiosk_card_${card.id}'),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      width: cardWidth,
      height: cardHeight,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 24, offset: Offset(0, 10)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: isPrevious
            ? SizedBox(
                key: ValueKey('min_${card.id}'),
                width: 210.0,
                height: cardHeight,
                child: _buildMinimizedCardContent(card, branchCode),
              )
            : SizedBox(
                key: ValueKey('full_${card.id}'),
                width: 560.0,
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
        // Compact Maroon Header
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
          color: const Color(0xFF610303),
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),

        // Compact Body (Expanded with spaceEvenly to perfectly fill 340px height)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Avatar (80x80)
                ClipOval(
                  child: Container(
                    width: 80,
                    height: 80,
                    color: const Color(0xFFF1F5F9),
                    child: card.isProcessing
                        ? const Stack(
                            alignment: Alignment.center,
                            children: [
                              Icon(Icons.person, size: 50, color: Color(0xFFCBD5E1)),
                              SizedBox(
                                width: 36,
                                height: 36,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF610303)),
                                ),
                              ),
                            ],
                          )
                        : card.isSuccess
                            ? _buildStudentAvatarImage(info, fullImageUrl, 80)
                            : (card.isError)
                                ? const Icon(Icons.error_outline_rounded, size: 48, color: Color(0xFFDC2626))
                                : (card.isOfflineSaved)
                                    ? const Icon(Icons.check_circle_outline_rounded, size: 48, color: Color(0xFF059669))
                                    : (card.isCooldown)
                                        ? const Icon(Icons.timer_outlined, size: 48, color: Color(0xFFD97706))
                                        : _buildDefaultAvatar(80),
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
                    fontSize: 16,
                    color: Color(0xFF0F172A),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),

                // Status Badge
                if (card.isSuccess && info != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0xFFBFDBFE)),
                    ),
                    child: Text(
                      info.ent ?? 'Entrance',
                      style: const TextStyle(
                        color: Color(0xFF1D4ED8),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  )
                else if (card.isOfflineSaved)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFECFDF5),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0xFFA7F3D0)),
                    ),
                    child: const Text(
                      'Scanned',
                      style: TextStyle(
                        color: Color(0xFF059669),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  )
                else if (card.isCooldown)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFFBEB),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0xFFFDE68A)),
                    ),
                    child: Text(
                      'Wait ${card.cooldownSecondsRemaining ?? 15}s',
                      style: const TextStyle(
                        color: Color(0xFFD97706),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  )
                else if (card.isError)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0xFFFECACA)),
                    ),
                    child: const Text(
                      'Invalid',
                      style: TextStyle(
                        color: Color(0xFFDC2626),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: const Text(
                      'Loading...',
                      style: TextStyle(
                        color: Color(0xFF64748B),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),

                // Time
                Text(
                  _formatTime(card.scannedAt),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF64748B),
                    fontWeight: FontWeight.w500,
                  ),
                ),
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
      mainAxisSize: MainAxisSize.min,
      children: [
        // Card Header: Animated status
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          decoration: BoxDecoration(
            color: EnvConfig.backgroundColor,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
            ),
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              SizedBox(width: 12),
              Text(
                'YOUR CARD HAS BEEN SCANNED',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),

        // Card Body
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Circular Profile Placeholder with loading indicator
              ClipOval(
                child: Container(
                  width: 130,
                  height: 130,
                  color: const Color(0xFFF1F5F9),
                  child: const Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(
                        Icons.person,
                        size: 76,
                        color: Color(0xFFCBD5E1),
                      ),
                      SizedBox(
                        width: 54,
                        height: 54,
                        child: CircularProgressIndicator(
                          strokeWidth: 3.5,
                          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF610303)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 24),

              // Details Column with loading indicators
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Text(
                          'STATUS : ',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF64748B),
                            fontSize: 14,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            'LOADING PROFILE...',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // DATE
                    Row(
                      children: [
                        const Text(
                          'DATE : ',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF64748B),
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          _formatDate(scannedAt),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // TIME
                    Row(
                      children: [
                        const Text(
                          'TIME : ',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF64748B),
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          _formatTime(scannedAt),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Linear Progress bar
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: const LinearProgressIndicator(
                        minHeight: 6,
                        backgroundColor: Color(0xFFF1F5F9),
                        valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF610303)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Your card has been scanned. Fetching credentials...',
                      style: TextStyle(
                        fontSize: 12,
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

        // Card Footer
        Padding(
          padding: const EdgeInsets.only(bottom: 16.0),
          child: Image.asset(
            'assets/images/oa.png',
            width: 160,
            height: 48,
            fit: BoxFit.contain,
            errorBuilder: (ctx, err, stack) => const Text(
              'OrangeApps',
              style: TextStyle(color: Color(0xFF610303), fontWeight: FontWeight.bold),
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
      mainAxisSize: MainAxisSize.min,
      children: [
        // Card Header: Student Name
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          decoration: BoxDecoration(
            color: EnvConfig.backgroundColor,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
            ),
          ),
          child: Text(
            info.name.toUpperCase(),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),

        // Card Body
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Circular Profile Picture (prioritizes downloaded local image for 0ms & offline display)
              ClipOval(
                child: Container(
                  width: 130,
                  height: 130,
                  color: const Color(0xFFF1F5F9),
                  child: _buildStudentAvatarImage(info, fullImageUrl, 130),
                ),
              ),
              const SizedBox(width: 24),

              // Details Column
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
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
                            fontSize: 14,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            info.personId.isNotEmpty ? info.personId : 'N/A',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 22,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // DATE
                    Row(
                      children: [
                        const Text(
                          'DATE : ',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF64748B),
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          info.date ?? _formatDate(scannedAt),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // TIME
                    Row(
                      children: [
                        const Text(
                          'TIME : ',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF64748B),
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          info.time ?? _formatTime(scannedAt),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Badges Row: Entrance/Exit
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFF6FF),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFFBFDBFE)),
                          ),
                          child: Text(
                            info.ent ?? 'Entrance',
                            style: const TextStyle(
                              color: Color(0xFF1D4ED8),
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
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

        // Card Footer: Powered by OrangeApps logo
        Padding(
          padding: const EdgeInsets.only(bottom: 16.0),
          child: Image.asset(
            'assets/images/oa.png',
            width: 160,
            height: 48,
            fit: BoxFit.contain,
            errorBuilder: (ctx, err, stack) => const Text(
              'OrangeApps',
              style: TextStyle(color: Color(0xFF610303), fontWeight: FontWeight.bold),
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
      mainAxisSize: MainAxisSize.min,
      children: [
        // Card Header
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          decoration: const BoxDecoration(
            color: Color(0xFF610303),
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
            ),
          ),
          child: const Text(
            'YOUR CARD HAS BEEN SCANNED',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.check_circle_outline_rounded,
                size: 72,
                color: Color(0xFF059669),
              ),
              const SizedBox(height: 12),
              const Text(
                'PLEASE CONTINUE',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF059669),
                  letterSpacing: 0.8,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                '${_formatDate(scannedAt)} • ${_formatTime(scannedAt)}',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1E293B),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              const Text(
                'Tap recorded locally and will sync automatically when online.',
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF64748B),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              Image.asset(
                'assets/images/oa.png',
                width: 140,
                height: 40,
                fit: BoxFit.contain,
                errorBuilder: (ctx, err, stack) => const SizedBox.shrink(),
              ),
            ],
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
