import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/config/env_config.dart';
import '../models/hris_attendance_models.dart';
import '../models/scan_record_model.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';
import '../services/update_service.dart';
import 'kiosk_provider.dart';

class HrisAttendanceState {
  final bool isInitializing;
  final bool requiresPasscode;
  final bool schoolHasPasscode;
  final bool isVerifyingPasscode;
  final String? passcodeError;
  final String? passcodeLogoUrl;
  final HrisPortalConfig config;
  final int selectedTimeInType; // 1 = QR Code, 2 = RFID
  final bool isSubmittingTap;
  final HrisEmployeeInfo? activeEmployee;
  final String? activeLogMessage;
  final bool activeLogType;
  final String? activeVoicePrompt;
  final bool isSavedOfflineFeedback;
  final String? submitTimeFormatted;
  final HrisQuote? activeQuote;
  final String? toastMessage;
  final bool toastIsError;
  final List<HrisTodayLogEntry> todayLogs;
  final bool isLoadingLogs;
  final String? cachedSchoolLogoPath;
  final String? cachedBgImagePath;

  const HrisAttendanceState({
    this.isInitializing = true,
    this.requiresPasscode = false,
    this.schoolHasPasscode = false,
    this.isVerifyingPasscode = false,
    this.passcodeError,
    this.passcodeLogoUrl,
    this.config = const HrisPortalConfig(),
    this.selectedTimeInType = 2,
    this.isSubmittingTap = false,
    this.activeEmployee,
    this.activeLogMessage,
    this.activeLogType = false,
    this.activeVoicePrompt,
    this.isSavedOfflineFeedback = false,
    this.submitTimeFormatted,
    this.activeQuote,
    this.toastMessage,
    this.toastIsError = true,
    this.todayLogs = const [],
    this.isLoadingLogs = false,
    this.cachedSchoolLogoPath,
    this.cachedBgImagePath,
  });

  HrisAttendanceState copyWith({
    bool? isInitializing,
    bool? requiresPasscode,
    bool? schoolHasPasscode,
    bool? isVerifyingPasscode,
    String? passcodeError,
    bool clearPasscodeError = false,
    String? passcodeLogoUrl,
    HrisPortalConfig? config,
    int? selectedTimeInType,
    bool? isSubmittingTap,
    HrisEmployeeInfo? activeEmployee,
    bool clearActiveEmployee = false,
    String? activeLogMessage,
    bool clearActiveLogMessage = false,
    bool? activeLogType,
    String? activeVoicePrompt,
    bool clearActiveVoicePrompt = false,
    bool? isSavedOfflineFeedback,
    String? submitTimeFormatted,
    bool clearSubmitTimeFormatted = false,
    HrisQuote? activeQuote,
    bool clearActiveQuote = false,
    String? toastMessage,
    bool clearToastMessage = false,
    bool? toastIsError,
    List<HrisTodayLogEntry>? todayLogs,
    bool? isLoadingLogs,
    String? cachedSchoolLogoPath,
    String? cachedBgImagePath,
  }) {
    return HrisAttendanceState(
      isInitializing: isInitializing ?? this.isInitializing,
      requiresPasscode: requiresPasscode ?? this.requiresPasscode,
      schoolHasPasscode: schoolHasPasscode ?? this.schoolHasPasscode,
      isVerifyingPasscode: isVerifyingPasscode ?? this.isVerifyingPasscode,
      passcodeError: clearPasscodeError ? null : (passcodeError ?? this.passcodeError),
      passcodeLogoUrl: passcodeLogoUrl ?? this.passcodeLogoUrl,
      config: config ?? this.config,
      selectedTimeInType: selectedTimeInType ?? this.selectedTimeInType,
      isSubmittingTap: isSubmittingTap ?? this.isSubmittingTap,
      activeEmployee: clearActiveEmployee ? null : (activeEmployee ?? this.activeEmployee),
      activeLogMessage: clearActiveLogMessage ? null : (activeLogMessage ?? this.activeLogMessage),
      activeLogType: activeLogType ?? this.activeLogType,
      activeVoicePrompt: clearActiveVoicePrompt ? null : (activeVoicePrompt ?? this.activeVoicePrompt),
      isSavedOfflineFeedback: isSavedOfflineFeedback ?? this.isSavedOfflineFeedback,
      submitTimeFormatted:
          clearSubmitTimeFormatted ? null : (submitTimeFormatted ?? this.submitTimeFormatted),
      activeQuote: clearActiveQuote ? null : (activeQuote ?? this.activeQuote),
      toastMessage: clearToastMessage ? null : (toastMessage ?? this.toastMessage),
      toastIsError: toastIsError ?? this.toastIsError,
      todayLogs: todayLogs ?? this.todayLogs,
      isLoadingLogs: isLoadingLogs ?? this.isLoadingLogs,
      cachedSchoolLogoPath: cachedSchoolLogoPath ?? this.cachedSchoolLogoPath,
      cachedBgImagePath: cachedBgImagePath ?? this.cachedBgImagePath,
    );
  }
}

class HrisAttendanceNotifier extends Notifier<HrisAttendanceState> {
  late ApiService _apiService;
  late LocalDbService _localDb;
  late UpdateAndMaintenanceService _updateService;

  Timer? _heartbeatTimer;
  Timer? _employeeClearTimer;
  Timer? _toastClearTimer;

  String? _lastScannedCode;
  DateTime? _lastScannedTime;
  final Map<String, DateTime> _employeeCooldownMap = {};
  final Set<String> _inFlightUuids = <String>{};
  final Set<String> _inFlightCodes = <String>{};
  bool _isCheckingConnectivity = false;

  String get _originKey {
    final raw = EnvConfig.releaseHrisBaseUrl.toLowerCase().trim();
    try {
      final uri = Uri.parse(raw);
      if (uri.host.isNotEmpty) {
        return uri.host.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
      }
    } catch (_) {}
    return EnvConfig.schoolBranch;
  }

  @override
  HrisAttendanceState build() {
    _apiService = ref.watch(apiServiceProvider);
    _localDb = ref.watch(localDbServiceProvider);
    _updateService = ref.watch(updateServiceProvider);

    ApiService.onServerTimeReceived = (serverTime) {
      _localDb.setServerTime(serverTime);
    };
    ApiService.onCookiesChanged = (_, cookies) {
      _localDb.saveHrisCookies(cookies, originKey: _originKey);
    };

    // Restore saved cookies (including `attendance_unlocked` 5-year cookie) before probing portal
    final savedCookies = _localDb.getHrisCookies(originKey: _originKey);
    if (savedCookies.isNotEmpty) {
      _apiService.restoreCookies(savedCookies, _apiService.baseUrl);
    }

    final cachedConfig = _localDb.getHrisPortalConfig(originKey: _originKey) ??
        HrisPortalConfig(
          schoolName: EnvConfig.appName,
          branchCode: EnvConfig.defaultBranch,
          schoolImage: EnvConfig.schoolLogoUrl,
        );
    final passcodeMeta = _localDb.getHrisPasscodeMetadata(originKey: _originKey);
    final cachedLogoPath = _localDb.getCachedSchoolLogoPath();
    final cachedBgPath = _localDb.getCachedHrisBgImagePath();

    Future.microtask(() async {
      _localDb.clearFailedOrInvalidTaps();
      ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);
      await initializePortal();
    });

    _startHeartbeat();

    ref.onDispose(() {
      _heartbeatTimer?.cancel();
      _employeeClearTimer?.cancel();
      _toastClearTimer?.cancel();
    });

    return HrisAttendanceState(
      isInitializing: true,
      schoolHasPasscode: passcodeMeta.requiresPasscode == true,
      config: cachedConfig,
      selectedTimeInType: 2,
      cachedSchoolLogoPath: cachedLogoPath,
      cachedBgImagePath: cachedBgPath,
    );
  }

  String get activeHrisBaseUrl => _apiService.baseUrl;

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      checkConnectivity();
    });
  }

  void setSelectedTimeInType(int timeInType) {
    ApiService.hrisTimeInType = timeInType;
    state = state.copyWith(selectedTimeInType: timeInType);
  }

  void showToast(String message, {bool isError = true, Duration duration = const Duration(seconds: 3)}) {
    _toastClearTimer?.cancel();
    state = state.copyWith(
      toastMessage: message,
      toastIsError: isError,
    );
    _toastClearTimer = Timer(duration, () {
      state = state.copyWith(clearToastMessage: true);
    });
  }

  void clearToast() {
    _toastClearTimer?.cancel();
    state = state.copyWith(clearToastMessage: true);
  }

  /// Manually sets and persists the Kiosk Date & Time in SQLite (used by DateTimeSettingsDialog)
  void setManualKioskTime(DateTime targetDateTime) {
    _localDb.setManualTime(targetDateTime);
    _employeeCooldownMap.clear();
  }

  /// Syncs the Kiosk Date & Time with the server and switches back to Automatic mode
  Future<bool> syncTimeWithServer() async {
    final serverTime = await _apiService.fetchServerTime();
    if (serverTime != null) {
      _localDb.setServerTime(serverTime, forceOverrideManual: true);
      _employeeCooldownMap.clear();
      return true;
    }
    // Also try lightweight connectivity check which captures HTTP Date header
    final reachable = await _apiService.checkConnectivity();
    if (reachable) {
      _localDb.setServerTime(_localDb.now, forceOverrideManual: true);
      return true;
    }
    return false;
  }

  Future<void> _checkRemoteStatus() async {
    try {
      final status = await _updateService.fetchRemoteStatus(schoolKey: EnvConfig.schoolBranch);
      if (status != null) {
        ref.read(remoteStatusProvider.notifier).updateStatus(status);
        if (status.isHardLock || !status.isSoftLock) {
          ref.read(softLockDismissedProvider.notifier).reset();
        }
      }
    } catch (_) {}
  }

  /// Probes `GET /hris/online_attendance` to determine if a passcode is required or if unlocked
  Future<void> initializePortal() async {
    state = state.copyWith(isInitializing: true, clearPasscodeError: true);

    final access = await _apiService.checkHrisPortalAccess();

    if (access.status == HrisAccessStatus.requiresPasscode) {
      ref.read(isOfflineProvider.notifier).setOffline(false);
      _localDb.setHrisPasscodeMetadata(
        originKey: _originKey,
        requiresPasscode: true,
        isUnlocked: false,
      );

      final logoUrl = access.passcodeSchoolLogoUrl ?? state.config.schoolImage;
      if (logoUrl.isNotEmpty) {
        unawaited(_localDb.downloadAndCacheSchoolLogo(logoUrl).then((path) {
          if (path != null) {
            state = state.copyWith(cachedSchoolLogoPath: path);
          }
        }));
      }

      state = state.copyWith(
        isInitializing: false,
        requiresPasscode: true,
        schoolHasPasscode: true,
        passcodeLogoUrl: logoUrl.isNotEmpty ? logoUrl : null,
      );

      unawaited(_checkRemoteStatus());
      return;
    }

    if (access.status == HrisAccessStatus.unlocked && access.config != null) {
      ref.read(isOfflineProvider.notifier).setOffline(false);
      final config = access.config!;
      final savedCookies = _localDb.getHrisCookies(originKey: _originKey);
      final hasUnlockCookie = savedCookies.containsKey('attendance_unlocked');

      _localDb.saveHrisPortalConfig(config, originKey: _originKey);
      _localDb.setHrisPasscodeMetadata(
        originKey: _originKey,
        requiresPasscode: hasUnlockCookie || state.schoolHasPasscode,
        isUnlocked: true,
      );

      if (config.schoolImage.isNotEmpty) {
        unawaited(_localDb.downloadAndCacheSchoolLogo(config.schoolImage).then((path) {
          if (path != null) {
            state = state.copyWith(cachedSchoolLogoPath: path);
          }
        }));
      }
      if (config.bgImgUrl.isNotEmpty) {
        unawaited(_localDb.downloadAndCacheHrisBgImage(config.bgImgUrl).then((path) {
          if (path != null) {
            state = state.copyWith(cachedBgImagePath: path);
          }
        }));
      }

      state = state.copyWith(
        isInitializing: false,
        requiresPasscode: false,
        schoolHasPasscode: hasUnlockCookie || state.schoolHasPasscode,
        config: config,
        clearPasscodeError: true,
      );

      await _checkRemoteStatus();
      // Priority #1: Flush pending offline taps before fetching today's attendance table
      if (_localDb.unsyncedCount > 0 && !ref.read(remoteStatusProvider).maintenance) {
        await syncOfflineQueue(force: true);
      }
      await refreshTodayLogs();
      return;
    }

    // Offline on startup
    ref.read(isOfflineProvider.notifier).setOffline(true);
    final meta = _localDb.getHrisPasscodeMetadata(originKey: _originKey);
    final mustShowOfflinePasscodeLock = meta.requiresPasscode == true && !meta.isUnlocked;

    state = state.copyWith(
      isInitializing: false,
      requiresPasscode: mustShowOfflinePasscodeLock,
      schoolHasPasscode: meta.requiresPasscode == true,
      passcodeError: mustShowOfflinePasscodeLock
          ? 'Offline: Connect to the internet once to verify the attendance passcode.'
          : null,
      todayLogs: _buildOfflineTodayLogs(),
    );
  }

  /// Submits the passcode to `POST /hris/attendance/passcode`
  Future<bool> submitPasscode(String passcode) async {
    final clean = passcode.trim();
    if (clean.isEmpty) {
      state = state.copyWith(passcodeError: 'Please enter the passcode.');
      return false;
    }

    state = state.copyWith(isVerifyingPasscode: true, clearPasscodeError: true);

    final result = await _apiService.verifyHrisPasscode(clean);
    if (!result.isSuccess) {
      if (result.isNetworkError) {
        ref.read(isOfflineProvider.notifier).setOffline(true);
      }
      state = state.copyWith(
        isVerifyingPasscode: false,
        passcodeError: result.message,
      );
      return false;
    }

    ref.read(isOfflineProvider.notifier).setOffline(false);
    _localDb.setHrisPasscodeMetadata(
      originKey: _originKey,
      requiresPasscode: true,
      isUnlocked: true,
    );

    showToast(
      result.message.isNotEmpty ? result.message : 'Passcode is correct.',
      isError: false,
    );

    state = state.copyWith(
      isVerifyingPasscode: false,
      schoolHasPasscode: true,
      clearPasscodeError: true,
    );

    await initializePortal();
    return !state.requiresPasscode;
  }

  /// Allows operator to manually re-lock the terminal if the school uses a passcode
  void lockPasscode() {
    _apiService.clearPasscodeCookie();
    _localDb.setHrisPasscodeMetadata(
      originKey: _originKey,
      requiresPasscode: true,
      isUnlocked: false,
    );
    state = state.copyWith(
      requiresPasscode: true,
      clearPasscodeError: true,
      clearActiveEmployee: true,
      clearActiveLogMessage: true,
    );
  }

  /// Fetches today's attendance table (`POST /hris/time_in_today`) and merges any unsynced offline taps
  Future<void> refreshTodayLogs({String employeeId = ''}) async {
    if (state.requiresPasscode) return;

    final isOffline = ref.read(isOfflineProvider);
    if (isOffline) {
      state = state.copyWith(todayLogs: _buildOfflineTodayLogs());
      return;
    }

    state = state.copyWith(isLoadingLogs: true);
    try {
      final now = _localDb.now;
      final dateNow = _formatIsoDate(now);
      final timeNow = _formatIsoTime(now);
      final remoteLogs = await _apiService.fetchHrisTimeInToday(
        dateNow: dateNow,
        timeNow: timeNow,
        employeeId: employeeId,
      );

      // Prepend any still-pending offline taps from today so nothing looks missing while syncing
      final pendingToday = _buildOfflineTodayLogs(onlyUnsynced: true);
      final merged = <HrisTodayLogEntry>[
        ...pendingToday,
        ...remoteLogs,
      ];

      state = state.copyWith(
        todayLogs: merged,
        isLoadingLogs: false,
      );
    } catch (_) {
      state = state.copyWith(isLoadingLogs: false);
    }
  }

  List<HrisTodayLogEntry> _buildOfflineTodayLogs({bool onlyUnsynced = false}) {
    final logs = _localDb.getRecentTapLogs(limit: 100, todayOnly: true);
    final filtered = onlyUnsynced ? logs.where((r) => !r.isSynced).toList() : logs;
    if (filtered.isEmpty) return const [];

    final byEmployee = <String, List<ScanRecordModel>>{};
    for (final rec in filtered) {
      final key = rec.studentIdDesc.trim().isNotEmpty
          ? rec.studentIdDesc.trim()
          : rec.rfidCode.trim();
      if (key.isEmpty) continue;
      byEmployee.putIfAbsent(key, () => []).add(rec);
    }

    final entries = <HrisTodayLogEntry>[];
    for (final entry in byEmployee.entries) {
      final list = entry.value..sort((a, b) => a.scannedAt.compareTo(b.scannedAt));
      final first = list.first;
      final last = list.length > 1 ? list.last : null;
      final name = first.studentName.trim().isNotEmpty
          ? first.studentName.trim()
          : 'ID: ${first.rfidCode}';
      final hasPending = list.any((r) => !r.isSynced);

      entries.add(
        HrisTodayLogEntry(
          employeeId: first.studentIdDesc.isNotEmpty ? first.studentIdDesc : first.rfidCode,
          employeeName: hasPending ? '$name (Pending Sync)' : name,
          timeIn: _format12HourTime(first.scannedAt),
          timeOut: last != null ? _format12HourTime(last.scannedAt) : '-',
          isPendingOffline: hasPending,
        ),
      );
    }
    return entries;
  }

  /// Connectivity check & prioritized offline queue flush
  Future<bool> checkConnectivity({bool forceSync = false, bool onlySyncQueue = false}) async {
    if (_isCheckingConnectivity && !forceSync) {
      return !ref.read(isOfflineProvider);
    }
    _isCheckingConnectivity = true;
    try {
      final isReachable = await _apiService.checkConnectivity();
      final wasOffline = ref.read(isOfflineProvider);
      final currentlyOffline = !isReachable;

      if (wasOffline != currentlyOffline) {
        ref.read(isOfflineProvider.notifier).setOffline(currentlyOffline);
      }

      if (currentlyOffline) {
        return false;
      }

      await _checkRemoteStatus();

      // If we were previously stuck on an offline startup before portal config loaded, initialize now
      if (wasOffline && (state.requiresPasscode || state.config.schoolName.isEmpty)) {
        await initializePortal();
        return true;
      }

      if (ref.read(remoteStatusProvider).maintenance) {
        return true;
      }

      // PRIORITY #1: Flush pending offline taps FIRST before refreshing table!
      if (_localDb.unsyncedCount > 0) {
        await syncOfflineQueue(force: forceSync || wasOffline || onlySyncQueue);
      }

      if (!onlySyncQueue && !state.requiresPasscode && (wasOffline || forceSync)) {
        await refreshTodayLogs();
      }

      return true;
    } finally {
      _isCheckingConnectivity = false;
    }
  }

  /// Processes an employee RFID / QR / ID tap on the HRIS portal
  Future<void> submitTap(String rawCode) async {
    if (state.requiresPasscode) return;

    final remoteStatus = ref.read(remoteStatusProvider);
    final softLockDismissed = ref.read(softLockDismissedProvider);

    if (remoteStatus.isHardLock) {
      return;
    }
    if (remoteStatus.isSoftLock && !softLockDismissed) {
      return;
    }

    final isBaseOffline = ref.read(isOfflineProvider);
    final isOffline = isBaseOffline || (remoteStatus.isSoftLock && softLockDismissed);

    if (!isBaseOffline && !remoteStatus.isLocked) {
      if (UpdateAndMaintenanceService.isUpdateAvailable(
        EnvConfig.appVersion,
        remoteStatus.latestVersion,
      )) {
        return;
      }
    }

    final cleanCode = rawCode.trim();
    if (cleanCode.isEmpty) return;

    final now = _localDb.now;

    // 1. Hardware key-repeat filter (< 800ms)
    if (_lastScannedCode == cleanCode &&
        _lastScannedTime != null &&
        now.difference(_lastScannedTime!).inMilliseconds < 800) {
      return;
    }

    // 2. Single-flight guard for live scan
    if (_inFlightCodes.contains(cleanCode) ||
        TapSyncCoordinator.instance.isRfidInFlight(cleanCode)) {
      return;
    }

    _lastScannedCode = cleanCode;
    _lastScannedTime = now;

    // 3. Rapid duplicate tap cooldown (10s for school 147 PCC, 3s default)
    final cooldownSec = state.config.schoolId == 147 ? 10 : 3;
    final cachedProfile = _localDb.getStudentByRfid(cleanCode);
    final cooldownKey = (cachedProfile != null && cachedProfile.personId.trim().isNotEmpty)
        ? 'emp:${cachedProfile.personId.trim()}'
        : 'code:$cleanCode';

    final lastTapAt = _employeeCooldownMap[cooldownKey];
    if (lastTapAt != null && now.difference(lastTapAt).inSeconds < cooldownSec) {
      final waitSec = cooldownSec - now.difference(lastTapAt).inSeconds;
      showToast('Please wait ${waitSec > 0 ? waitSec : 1}s before tapping again.', isError: false);
      return;
    }
    _employeeCooldownMap[cooldownKey] = now;

    final branchCode = state.config.branchCode.isNotEmpty
        ? state.config.branchCode
        : EnvConfig.defaultBranch;

    final scan = ScanRecordModel(
      rfidCode: cleanCode,
      scannedAt: now,
      branchCode: branchCode,
      placeId: 0,
      placeName: 'HRIS Online Attendance',
      studentIdDesc: cachedProfile?.personId ?? '',
      studentName: cachedProfile?.name ?? '',
      type: 'Employee',
      gradeLevel: 'Employee',
      section: 'HRIS',
    );

    // =========================================================================
    // OFFLINE PATH: Save immediately to SQLite & display employee feedback
    // =========================================================================
    if (isOffline) {
      _localDb.saveTapEntry(
        scan.copyWith(isSynced: false, errorMessage: 'OFFLINE_SAVED'),
      );
      ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);
      _showOfflineSavedEmployeeFeedback(
        cleanCode: cleanCode,
        cachedProfile: cachedProfile,
        tapTime: now,
      );
      return;
    }

    // =========================================================================
    // ONLINE PATH: Claim UUID, persist to SQLite BEFORE network call, then POST
    // =========================================================================
    _inFlightCodes.add(cleanCode);
    _inFlightUuids.add(scan.uuid);
    TapSyncCoordinator.instance.claimUuid(scan.uuid);

    _localDb.saveTapEntry(
      scan.copyWith(isSynced: false, errorMessage: 'PENDING_LIVE_SYNC'),
    );
    ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);

    ApiService.hrisTimeInType = state.selectedTimeInType;
    ApiService.hrisIsRestricted = state.config.isRestricted;

    state = state.copyWith(isSubmittingTap: true, clearToastMessage: true);

    try {
      final res = await _apiService.sendRfidScan(scan);

      // 1. Network error / timeout / 5xx -> keep queued in SQLite & show offline saved feedback
      if (res.isNetworkError || res.isServerError) {
        if (res.isConnectionFailure) {
          ref.read(isOfflineProvider.notifier).setOffline(true);
        }
        _localDb.saveTapEntry(
          scan.copyWith(isSynced: false, errorMessage: 'OFFLINE_SAVED'),
        );
        ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);
        state = state.copyWith(isSubmittingTap: false);
        _showOfflineSavedEmployeeFeedback(
          cleanCode: cleanCode,
          cachedProfile: cachedProfile,
          tapTime: now,
        );
        return;
      }

      ref.read(isOfflineProvider.notifier).setOffline(false);
      final hris = res.hrisResponse;

      // 2. Valid employee returned by HRIS server
      if (hris != null && hris.employee != null) {
        final emp = hris.employee!;
        if (hris.showIntervalPrompt) {
          // Within grace interval: server did not insert a new attendance row
          _localDb.deleteTapEntry(scan.uuid);
        } else {
          _localDb.markRecordSynced(scan.uuid, studentInfo: res.studentInfo);
        }
        ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);

        // Cache employee profile & download photo to SQLite for instant offline fallback!
        String? resolvedLocalImg = cachedProfile?.hasValidLocalImage == true
            ? cachedProfile!.localImagePath
            : null;
        if (res.studentInfo != null) {
          unawaited(
            _cacheEmployeeProfile(
              scannedCode: cleanCode,
              emp: emp,
              studentInfo: res.studentInfo!,
              branchCode: branchCode,
              tapTime: now,
            ).then((downloadedPath) {
              if (downloadedPath != null &&
                  state.activeEmployee?.employeeId == emp.employeeId) {
                state = state.copyWith(
                  activeEmployee: state.activeEmployee!.copyWith(localImagePath: downloadedPath),
                );
              }
            }),
          );
        }

        final displayEmp = emp.copyWith(localImagePath: resolvedLocalImg);
        final quote = state.config.schoolId == 164 ? null : HrisQuote.random();
        final formattedTime = _format12HourTimeFromRaw(hris.timeNow, fallback: now);

        state = state.copyWith(
          isSubmittingTap: false,
          activeEmployee: displayEmp,
          activeLogMessage: hris.logMessage,
          activeLogType: hris.logType,
          activeVoicePrompt: hris.logVoicePrompt,
          isSavedOfflineFeedback: false,
          submitTimeFormatted: formattedTime,
          activeQuote: quote,
          todayLogs: hris.inlineLogs ?? state.todayLogs,
        );

        _scheduleEmployeeAutoClear();

        if (state.config.schoolId != 124 && state.config.schoolId != 125) {
          unawaited(refreshTodayLogs(employeeId: cleanCode));
        }
        if (_localDb.unsyncedCount > 0) {
          unawaited(syncOfflineQueue());
        }
        return;
      }

      // 3. Permanent rejection (e.g. "Employee not found." or "Invalid RFID Code.")
      _localDb.deleteTapEntry(scan.uuid);
      ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);
      state = state.copyWith(isSubmittingTap: false);

      final errText = (hris?.logMessage != null && hris!.logMessage!.trim().isNotEmpty)
          ? hris.logMessage!.trim()
          : 'Employee not found.';
      showToast(errText, isError: true);
    } finally {
      _inFlightCodes.remove(cleanCode);
      _inFlightUuids.remove(scan.uuid);
      TapSyncCoordinator.instance.releaseClaimedUuid(scan.uuid);
    }
  }

  Future<String?> _cacheEmployeeProfile({
    required String scannedCode,
    required HrisEmployeeInfo emp,
    required dynamic studentInfo,
    required String branchCode,
    required DateTime tapTime,
  }) async {
    final savedPrimary = await _localDb.upsertStudentAndDownloadImage(
      rfidCode: scannedCode,
      branchCode: branchCode,
      onlineInfo: studentInfo,
      baseUrl: _apiService.baseUrl,
      tapTime: tapTime,
    );

    // If scannedCode was an RFID card number different from employeeId, cache under employeeId too
    if (emp.employeeId.isNotEmpty && emp.employeeId != scannedCode) {
      await _localDb.upsertStudentAndDownloadImage(
        rfidCode: emp.employeeId,
        branchCode: branchCode,
        onlineInfo: studentInfo,
        baseUrl: _apiService.baseUrl,
        tapTime: tapTime,
      );
    }

    return savedPrimary.localImagePath;
  }

  void _showOfflineSavedEmployeeFeedback({
    required String cleanCode,
    required CachedStudentProfile? cachedProfile,
    required DateTime tapTime,
  }) {
    final HrisEmployeeInfo offlineEmp;
    final String msg;

    if (cachedProfile != null) {
      offlineEmp = HrisEmployeeInfo(
        employeeId: cachedProfile.personId.isNotEmpty ? cachedProfile.personId : cleanCode,
        fullName: cachedProfile.name,
        picture: cachedProfile.imageUrl,
        localImagePath: cachedProfile.hasValidLocalImage ? cachedProfile.localImagePath : null,
        isBirthday: cachedProfile.birthday,
      );
      msg = 'Attendance saved offline (Pending sync)';
    } else {
      offlineEmp = HrisEmployeeInfo(
        employeeId: cleanCode,
        fullName: 'ID: $cleanCode',
      );
      msg = 'Saved offline — will verify & sync when online';
    }

    state = state.copyWith(
      isSubmittingTap: false,
      activeEmployee: offlineEmp,
      activeLogMessage: msg,
      activeLogType: true,
      activeVoicePrompt: 'time_in',
      isSavedOfflineFeedback: true,
      submitTimeFormatted: _format12HourTime(tapTime),
      activeQuote: state.config.schoolId == 164 ? null : HrisQuote.random(),
      todayLogs: _buildOfflineTodayLogs(),
    );

    _scheduleEmployeeAutoClear();
  }

  void _scheduleEmployeeAutoClear() {
    _employeeClearTimer?.cancel();
    final ms = switch (state.config.schoolId) {
      124 => 2800,
      188 => 2000,
      125 => 5000,
      147 => 6000,
      164 => 15000,
      _ => 3500,
    };
    _employeeClearTimer = Timer(Duration(milliseconds: ms), () {
      state = state.copyWith(
        clearActiveEmployee: true,
        clearActiveLogMessage: true,
        clearActiveVoicePrompt: true,
        clearSubmitTimeFormatted: true,
        clearActiveQuote: true,
        isSavedOfflineFeedback: false,
      );
    });
  }

  /// Syncs queued offline HRIS taps in strict chronological order (`scanned_at ASC`)
  Future<void> syncOfflineQueue({bool force = false}) {
    if (ref.read(remoteStatusProvider).maintenance) return Future.value();
    if (!force && ref.read(isOfflineProvider)) return Future.value();

    return TapSyncCoordinator.instance.runExclusiveOfflineSync(() async {
      final pending = _localDb.unsyncedRecords;
      if (pending.isEmpty) {
        ref.read(offlineQueueCountProvider.notifier).setCount(0);
        return;
      }

      debugPrint('[HRIS Sync] Flushing ${pending.length} queued offline attendance tap(s)...');
      bool syncedAny = false;

      for (final record in pending) {
        if (_inFlightUuids.contains(record.uuid) ||
            TapSyncCoordinator.instance.isUuidInFlight(record.uuid)) {
          continue;
        }
        if (_localDb.isRecordSynced(record.uuid)) {
          continue;
        }

        final res = await _apiService.sendRfidScan(record);

        if (res.isConnectionFailure) {
          ref.read(isOfflineProvider.notifier).setOffline(true);
          break;
        }

        if (res.isServerError || res.isNetworkError) {
          continue;
        }

        ref.read(isOfflineProvider.notifier).setOffline(false);

        if (res.isTapOnInterval) {
          _localDb.deleteTapEntry(record.uuid);
          syncedAny = true;
        } else if (res.isSuccess) {
          _localDb.markRecordSynced(record.uuid, studentInfo: res.studentInfo);
          syncedAny = true;
          if (res.hrisResponse?.employee != null && res.studentInfo != null) {
            unawaited(
              _cacheEmployeeProfile(
                scannedCode: record.rfidCode,
                emp: res.hrisResponse!.employee!,
                studentInfo: res.studentInfo!,
                branchCode: record.branchCode,
                tapTime: record.scannedAt,
              ),
            );
          }
        } else if (res.isPermanentRejection) {
          _localDb.deleteTapEntry(record.uuid);
          syncedAny = true;
        }

        ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);
      }

      ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);
      if (syncedAny && !state.requiresPasscode) {
        await refreshTodayLogs();
      }
    });
  }

  static String _formatIsoDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String _formatIsoTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  static String _format12HourTime(DateTime dt) {
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    final m = dt.minute.toString().padLeft(2, '0');
    return '${h.toString().padLeft(2, '0')}:$m $period';
  }

  static String _format12HourTimeFromRaw(String? rawTime, {required DateTime fallback}) {
    if (rawTime != null && rawTime.contains(':')) {
      final parts = rawTime.trim().split(':');
      final hh = int.tryParse(parts[0]);
      final mm = parts.length > 1 ? int.tryParse(parts[1]) : null;
      if (hh != null && mm != null) {
        final h = hh > 12 ? hh - 12 : (hh == 0 ? 12 : hh);
        final period = hh >= 12 ? 'PM' : 'AM';
        return '${h.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')} $period';
      }
    }
    return _format12HourTime(fallback);
  }
}

final hrisAttendanceProvider =
    NotifierProvider<HrisAttendanceNotifier, HrisAttendanceState>(
  HrisAttendanceNotifier.new,
);
