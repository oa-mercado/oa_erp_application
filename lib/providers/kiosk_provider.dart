import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/config/env_config.dart';
import '../core/constants/api_constants.dart';
import '../core/hardware/rfid_listener.dart';
import '../models/gate_model.dart';
import '../models/kiosk_state.dart';
import '../models/scan_record_model.dart';
import '../models/scan_response_model.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';
import '../services/update_service.dart';

/// Provider for the ApiService
final apiServiceProvider = Provider<ApiService>((ref) {
  return ApiService();
});

/// Provider for UpdateAndMaintenanceService
final updateServiceProvider = Provider<UpdateAndMaintenanceService>((ref) {
  return UpdateAndMaintenanceService();
});

/// Provider for the LocalDbService (`students_cache.json`, `images/`, `stud_entry_tbl.json`)
final localDbServiceProvider = Provider<LocalDbService>((ref) {
  final db = LocalDbService();
  db.init();
  return db;
});

/// Remote maintenance & version state notifier
class RemoteStatusNotifier extends Notifier<AppRemoteStatus> {
  @override
  AppRemoteStatus build() => const AppRemoteStatus();

  void updateStatus(AppRemoteStatus status) => state = status;
}

final remoteStatusProvider =
    NotifierProvider<RemoteStatusNotifier, AppRemoteStatus>(RemoteStatusNotifier.new);

/// Notifier for the active gate (restores last selected gate from Local DB)
class ActiveGateNotifier extends Notifier<GateModel> {
  @override
  GateModel build() {
    final localDb = ref.watch(localDbServiceProvider);
    final savedGate = localDb.getSavedGate();
    if (savedGate != null) {
      return savedGate;
    }

    return GateModel(
      id: EnvConfig.defaultGateId,
      placeName: EnvConfig.defaultGateName,
      branchCode: EnvConfig.defaultBranch,
    );
  }

  void setGate(GateModel gate) {
    state = gate;
    ref.read(localDbServiceProvider).saveGate(gate);
  }
}

final activeGateProvider = NotifierProvider<ActiveGateNotifier, GateModel>(ActiveGateNotifier.new);

/// Notifier for offline status
class IsOfflineNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void setOffline(bool offline) => state = offline;
}

final isOfflineProvider = NotifierProvider<IsOfflineNotifier, bool>(IsOfflineNotifier.new);

/// Notifier for offline queue count
class OfflineQueueCountNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void setCount(int count) => state = count;
}

final offlineQueueCountProvider =
    NotifierProvider<OfflineQueueCountNotifier, int>(OfflineQueueCountNotifier.new);

/// Main Kiosk Notifier managing local DB instant lookup, card stacking, push-left transitions, and per-card 4s timers
class KioskNotifier extends Notifier<KioskState> {
  late final ApiService _apiService;
  late final LocalDbService _localDb;
  late final RfidScannerListener _listener;

  Timer? _heartbeatTimer;
  final Map<String, Timer> _cardDismissTimers = {};

  String? _lastScannedCode;
  DateTime? _lastScannedTime;
  final Map<String, DateTime> _cardLastSuccessTapTimes = {};

  bool _isSyncingRoster = false;
  String? _lastSyncedBranch;

  late final UpdateAndMaintenanceService _updateService;

  @override
  KioskState build() {
    _apiService = ref.watch(apiServiceProvider);
    _localDb = ref.watch(localDbServiceProvider);
    _updateService = ref.watch(updateServiceProvider);
    _listener = RfidScannerListener(onScanned: handleRfidTap);
    _listener.start();

    // Initialize pending offline queue count, check remote status, and sync full roster on startup
    Future.microtask(() async {
      ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);
      // Run initial maintenance & version check immediately
      await _checkRemoteStatus();
      // Sync all K-12, College, and Employee profiles into SQLite Local DB on startup
      await syncRosterFromServer();
    });

    _startHeartbeat();

    ref.onDispose(() {
      for (final timer in _cardDismissTimers.values) {
        timer.cancel();
      }
      _cardDismissTimers.clear();
      _heartbeatTimer?.cancel();
      _listener.stop();
    });

    return const KioskState();
  }

  RfidScannerListener get listener => _listener;

  void _startHeartbeat() {
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) => _checkConnectivity());
  }

  Future<void> _checkRemoteStatus() async {
    try {
      final status = await _updateService.fetchRemoteStatus(schoolKey: EnvConfig.schoolBranch);
      if (status != null) {
        ref.read(remoteStatusProvider.notifier).updateStatus(status);
      }
    } catch (_) {}
  }

  Future<void> _checkConnectivity() async {
    final isReachable = await _apiService.checkConnectivity();
    final wasOffline = ref.read(isOfflineProvider);
    final currentlyOffline = !isReachable;

    if (wasOffline != currentlyOffline) {
      ref.read(isOfflineProvider.notifier).setOffline(currentlyOffline);
    }

    // Refresh version & maintenance status whenever online
    if (!currentlyOffline) {
      await _checkRemoteStatus();
    }

    // Check maintenance status: DO NOT flush offline queue to server if maintenance mode is active!
    final remoteStatus = ref.read(remoteStatusProvider);
    if (remoteStatus.maintenance) {
      debugPrint('[Kiosk] Maintenance active. Postponing offline sync.');
      return;
    }

    // Automatically flush offline queue whenever online and pending records exist
    if (!currentlyOffline && _localDb.unsyncedCount > 0) {
      await syncOfflineQueue();
    }

    // If we just reconnected to the internet and haven't synced the roster yet, sync it now
    if (!currentlyOffline && wasOffline) {
      unawaited(syncRosterFromServer());
    }
  }

  /// Requests all K-12 students, K-12 employees, College students, and College employees
  /// from `/kiosk_sync_roster` and saves them into the local SQLite database (`students_cache`).
  Future<void> syncRosterFromServer({String? branchOverride}) async {
    if (_isSyncingRoster) return;
    final remoteStatus = ref.read(remoteStatusProvider);
    if (remoteStatus.maintenance) return;

    final activeGate = ref.read(activeGateProvider);
    final branchCode = (branchOverride ?? activeGate.branchCode).trim();

    _isSyncingRoster = true;
    try {
      debugPrint('[Kiosk] Requesting full student & employee roster for branch "$branchCode"...');
      final profiles = await _apiService.fetchKioskRoster(branchCode: branchCode);
      if (profiles.isNotEmpty) {
        final savedCount = _localDb.bulkUpsertRoster(profiles);
        _lastSyncedBranch = branchCode;
        debugPrint(
          '[Kiosk] Roster sync complete! Upserted $savedCount profiles into SQLite (total cached: ${_localDb.cachedRosterCount}).',
        );
      } else {
        debugPrint(
          '[Kiosk] Roster sync finished: Server returned 0 profiles. Existing cached profiles intact: ${_localDb.cachedRosterCount}.',
        );
      }
    } catch (e) {
      debugPrint('[Kiosk] Roster sync error: $e');
    } finally {
      _isSyncingRoster = false;
    }
  }

  void setGate(GateModel gate) {
    final prevBranch = ref.read(activeGateProvider).branchCode;
    ref.read(activeGateProvider.notifier).setGate(gate);
    if (gate.branchCode.isNotEmpty) {
      _apiService.setBaseUrl(EnvConfig.getBranchBaseUrl(gate.branchCode));
      if (gate.branchCode != prevBranch || _lastSyncedBranch != gate.branchCode) {
        unawaited(syncRosterFromServer(branchOverride: gate.branchCode));
      }
    }
  }

  void _addCard(ActiveKioskCard newCard) {
    final current = List<ActiveKioskCard>.from(state.activeCards);
    // Keep at most 3 cards on screen (2 previous minimized on left + 1 active on right)
    if (current.length >= 3) {
      final removed = current.removeAt(0);
      _cardDismissTimers[removed.id]?.cancel();
      _cardDismissTimers.remove(removed.id);
    }
    current.add(newCard);
    state = state.copyWith(activeCards: current);
  }

  void _updateCard(
    String cardId, {
    required KioskCardType type,
    StudentInfoModel? studentInfo,
    String? errorMessage,
    int? queuedCount,
  }) {
    final updated = state.activeCards.map((c) {
      if (c.id == cardId) {
        return c.copyWith(
          type: type,
          studentInfo: studentInfo,
          errorMessage: errorMessage,
          queuedCount: queuedCount,
        );
      }
      return c;
    }).toList();
    state = state.copyWith(activeCards: updated);
  }

  void _scheduleCardDismiss(String cardId, Duration duration) {
    _cardDismissTimers[cardId]?.cancel();
    _cardDismissTimers[cardId] = Timer(duration, () {
      _removeCard(cardId);
    });
  }

  void _removeCard(String cardId) {
    _cardDismissTimers[cardId]?.cancel();
    _cardDismissTimers.remove(cardId);
    final updated = state.activeCards.where((c) => c.id != cardId).toList();
    state = state.copyWith(activeCards: updated);
  }

  /// Processes an RFID tap using Local DB first:
  /// - Scenario 1 (Not in Local DB):
  ///   - Online: Immediately shows "Your card has been scanned" loading card -> updates UI when server responds & caches profile + downloads photo to Local DB.
  ///   - Offline: Does NOT show loading; records tap locally and shows "Please continue".
  /// - Scenario 2 (Found in Local DB):
  ///   - Immediately displays the cached student profile & downloaded photo without waiting for online response.
  ///   - Online: Sends scan in background and silently updates Local DB if any info changed (or queues if network drops).
  ///   - Offline: Stores tap (`rfid_code`, `place_id`, timestamp/date, and `stud_entry_tbl` columns) to sync later.
  Future<void> handleRfidTap(String rfidCode) async {
    // 0. Maintenance & Force-Update Check: if online and maintenance or update is required, ignore tap
    final remoteStatus = ref.read(remoteStatusProvider);
    final isOffline = ref.read(isOfflineProvider);
    if (!isOffline) {
      if (remoteStatus.maintenance) {
        debugPrint('[Kiosk] RFID scan ignored: System is under maintenance.');
        return;
      }
      if (UpdateAndMaintenanceService.isUpdateAvailable(EnvConfig.appVersion, remoteStatus.latestVersion)) {
        debugPrint('[Kiosk] RFID scan ignored: App update is required.');
        return;
      }
    }

    final cleanCode = rfidCode.trim();
    if (cleanCode.isEmpty) return;

    final now = DateTime.now();

    // 1. Hardware debounce: filter out rapid raw key-repeat while card touches scanner (< 800ms)
    if (_lastScannedCode == cleanCode &&
        _lastScannedTime != null &&
        now.difference(_lastScannedTime!).inMilliseconds < 800) {
      return;
    }

    _lastScannedCode = cleanCode;
    _lastScannedTime = now;

    final activeGate = ref.read(activeGateProvider);
    final cardId = '${now.microsecondsSinceEpoch}_$cleanCode';
    final effectiveBaseUrl = activeGate.branchCode.isNotEmpty
        ? EnvConfig.getBranchBaseUrl(activeGate.branchCode)
        : ApiConstants.defaultBaseUrl;

    // 2. Tap Cooldown Check: prevent accidental duplicate scans of the same card within 15s
    final lastSuccessTap = _cardLastSuccessTapTimes[cleanCode];
    if (lastSuccessTap != null) {
      final elapsedSeconds = now.difference(lastSuccessTap).inSeconds;
      const cooldownDurationSeconds = 15;
      if (elapsedSeconds < cooldownDurationSeconds) {
        final remaining = cooldownDurationSeconds - elapsedSeconds;
        final cooldownCard = ActiveKioskCard(
          id: cardId,
          rfidCode: cleanCode,
          type: KioskCardType.cooldown,
          scannedAt: now,
          cooldownSecondsRemaining: remaining > 0 ? remaining : 1,
        );
        _addCard(cooldownCard);
        _scheduleCardDismiss(cardId, const Duration(seconds: 4));
        return;
      }
    }

    // 3. Look up the RFID code in the Local DB first
    final cachedProfile = _localDb.getStudentByRfid(cleanCode);

    // =========================================================================
    // SCENARIO 2: Student IS found in the Local DB -> Show credentials immediately!
    // =========================================================================
    if (cachedProfile != null) {
      _cardLastSuccessTapTimes[cleanCode] = now;
      final localDisplay = _localDb.prepareLocalTapDisplay(
        cachedProfile,
        now,
        allowExit: activeGate.allowExit,
      );

      // Immediately display the Student Card from Local DB without waiting for online response
      final instantCard = ActiveKioskCard(
        id: cardId,
        rfidCode: cleanCode,
        type: KioskCardType.success,
        studentInfo: localDisplay.info,
        scannedAt: now,
      );
      _addCard(instantCard);
      _scheduleCardDismiss(cardId, const Duration(seconds: 4));

      final scan = ScanRecordModel(
        rfidCode: cleanCode,
        scannedAt: now,
        branchCode: activeGate.branchCode,
        placeId: activeGate.id,
        placeName: activeGate.placeName,
        studentIdDesc: cachedProfile.personId,
        studentName: cachedProfile.name,
        studentType: cachedProfile.studentType,
        isCommuter: cachedProfile.isCommuter,
        isExit: localDisplay.isExit,
        type: cachedProfile.type,
        gradeLevel: cachedProfile.gradeLevel,
        section: cachedProfile.section,
        studentInfo: localDisplay.info,
      );

      if (isOffline) {
        // Offline: store the tap in local stud_entry_tbl queue to send later
        _localDb.saveTapEntry(scan.copyWith(isSynced: false, errorMessage: 'OFFLINE_SAVED'));
        ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);
        return;
      }

      // Online: send scan to ERP in the background and silently update Local DB if anything changed
      unawaited(
        _syncCachedStudentTapInBackground(
          scan: scan,
          cleanCode: cleanCode,
          branchCode: activeGate.branchCode,
          effectiveBaseUrl: effectiveBaseUrl,
          tapTime: now,
        ),
      );
      return;
    }

    // =========================================================================
    // SCENARIO 1: Student is NOT in the Local DB yet
    // =========================================================================

    // Scenario 1B: No connection -> Do NOT show loading; save tap and say "Please continue"
    if (isOffline) {
      _cardLastSuccessTapTimes[cleanCode] = now;
      final offlineScan = ScanRecordModel(
        rfidCode: cleanCode,
        scannedAt: now,
        branchCode: activeGate.branchCode,
        placeId: activeGate.id,
        placeName: activeGate.placeName,
        isSynced: false,
        errorMessage: 'OFFLINE_SAVED',
      );
      _localDb.saveTapEntry(offlineScan);
      ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);

      final card = ActiveKioskCard(
        id: cardId,
        rfidCode: cleanCode,
        type: KioskCardType.offlineSaved,
        scannedAt: now,
        queuedCount: _localDb.unsyncedCount,
      );
      _addCard(card);
      _scheduleCardDismiss(cardId, const Duration(seconds: 4));
      return;
    }

    // Scenario 1A: Online -> Immediately show "Your card has been scanned" while loading
    final loadingCard = ActiveKioskCard(
      id: cardId,
      rfidCode: cleanCode,
      type: KioskCardType.processing,
      scannedAt: now,
    );
    _addCard(loadingCard);

    final scan = ScanRecordModel(
      rfidCode: cleanCode,
      scannedAt: now,
      branchCode: activeGate.branchCode,
      placeId: activeGate.id,
      placeName: activeGate.placeName,
    );

    try {
      final response = await _apiService.sendRfidScan(scan);

      // If server dropped or timed out (>8s) during request -> queue locally & show "Please continue"
      if (!response.isSuccess &&
          (response.message?.contains('Unable to connect') == true ||
              response.message?.contains('Offline') == true ||
              response.message?.contains('timed out') == true)) {
        ref.read(isOfflineProvider.notifier).setOffline(true);
        _cardLastSuccessTapTimes[cleanCode] = DateTime.now();
        _localDb.saveTapEntry(scan.copyWith(isSynced: false, errorMessage: 'OFFLINE_SAVED'));
        ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);

        _updateCard(
          cardId,
          type: KioskCardType.offlineSaved,
          queuedCount: _localDb.unsyncedCount,
        );
        _scheduleCardDismiss(cardId, const Duration(seconds: 4));
        return;
      }

      if (response.isSuccess && response.studentInfo != null) {
        final onlineInfo = response.studentInfo!;
        final onlineIsExit = (onlineInfo.ent?.toLowerCase() == 'exit') ? 1 : 0;
        _cardLastSuccessTapTimes[cleanCode] = DateTime.now();

        // Save synced entry in local stud_entry_tbl
        _localDb.saveTapEntry(
          scan.copyWith(
            isSynced: true,
            studentIdDesc: onlineInfo.personId,
            studentName: onlineInfo.name,
            isCommuter: onlineInfo.isCommuter,
            isExit: onlineIsExit,
            type: onlineInfo.type ?? 'Student',
            gradeLevel: onlineInfo.gradeLevel ?? 'N/A',
            section: onlineInfo.section ?? 'N/A',
            studentInfo: onlineInfo,
          ),
        );

        // Update card UI immediately with the returned online student info
        _updateCard(
          cardId,
          type: KioskCardType.success,
          studentInfo: onlineInfo,
        );
        _scheduleCardDismiss(cardId, const Duration(seconds: 4));

        // Cache student profile in Local DB & download their profile image for offline/future taps
        unawaited(
          _localDb.upsertStudentAndDownloadImage(
            rfidCode: cleanCode,
            branchCode: activeGate.branchCode,
            onlineInfo: onlineInfo,
            baseUrl: effectiveBaseUrl,
            tapTime: now,
            onImageDownloaded: (localPath) {
              // If the card is still visible on screen, attach the local image path
              if (state.activeCards.any((c) => c.id == cardId)) {
                _updateCard(
                  cardId,
                  type: KioskCardType.success,
                  studentInfo: onlineInfo.copyWith(localImagePath: localPath),
                );
              }
            },
          ),
        );
      } else {
        _updateCard(
          cardId,
          type: KioskCardType.error,
          errorMessage: response.message ?? 'Unable to Process Transaction Code Not Found',
        );
        _scheduleCardDismiss(cardId, const Duration(seconds: 4));
      }
    } catch (e) {
      _updateCard(
        cardId,
        type: KioskCardType.error,
        errorMessage: 'Connection Error: $e',
      );
      _scheduleCardDismiss(cardId, const Duration(seconds: 4));
    }
  }

  /// Sends the tap for an already-cached student in the background:
  /// - If online response differs from Local DB, silently updates Local DB & downloads new image.
  /// - If request fails/times out, queues the tap in `stud_entry_tbl.json` to sync later.
  Future<void> _syncCachedStudentTapInBackground({
    required ScanRecordModel scan,
    required String cleanCode,
    required String branchCode,
    required String effectiveBaseUrl,
    required DateTime tapTime,
  }) async {
    try {
      final response = await _apiService.sendRfidScan(scan);

      if (!response.isSuccess &&
          (response.message?.contains('Unable to connect') == true ||
              response.message?.contains('Offline') == true ||
              response.message?.contains('timed out') == true)) {
        ref.read(isOfflineProvider.notifier).setOffline(true);
        _localDb.saveTapEntry(scan.copyWith(isSynced: false, errorMessage: 'OFFLINE_SAVED'));
        ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);
        return;
      }

      if (response.isSuccess && response.studentInfo != null) {
        final onlineInfo = response.studentInfo!;
        final onlineIsExit = (onlineInfo.ent?.toLowerCase() == 'exit') ? 1 : 0;

        _localDb.saveTapEntry(
          scan.copyWith(
            isSynced: true,
            studentIdDesc: onlineInfo.personId,
            studentName: onlineInfo.name,
            isCommuter: onlineInfo.isCommuter,
            isExit: onlineIsExit,
            type: onlineInfo.type ?? 'Student',
            gradeLevel: onlineInfo.gradeLevel ?? 'N/A',
            section: onlineInfo.section ?? 'N/A',
            studentInfo: onlineInfo,
          ),
        );

        // Silently update Local DB if any student info changed (and download image if needed)
        await _localDb.upsertStudentAndDownloadImage(
          rfidCode: cleanCode,
          branchCode: branchCode,
          onlineInfo: onlineInfo,
          baseUrl: effectiveBaseUrl,
          tapTime: tapTime,
        );
      }
    } catch (_) {
      _localDb.saveTapEntry(scan.copyWith(isSynced: false, errorMessage: 'OFFLINE_SAVED'));
      ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);
    }
  }

  /// Uploads all unsynced `stud_entry_tbl` records to the server when connection is restored
  Future<void> syncOfflineQueue() async {
    final pending = _localDb.unsyncedRecords;
    if (pending.isEmpty) return;

    for (final scan in pending) {
      final res = await _apiService.sendRfidScan(scan);
      if (res.isSuccess) {
        _localDb.markRecordSynced(scan.uuid, studentInfo: res.studentInfo);

        // Also cache the student's profile & download photo if returned during offline sync!
        if (res.studentInfo != null) {
          final effectiveBaseUrl = scan.branchCode.isNotEmpty
              ? EnvConfig.getBranchBaseUrl(scan.branchCode)
              : ApiConstants.defaultBaseUrl;
          unawaited(
            _localDb.upsertStudentAndDownloadImage(
              rfidCode: scan.rfidCode,
              branchCode: scan.branchCode,
              onlineInfo: res.studentInfo!,
              baseUrl: effectiveBaseUrl,
              tapTime: scan.scannedAt,
            ),
          );
        }
      }
    }
    ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);
  }
}

/// Global Provider for the Kiosk Notifier and State
final kioskScanProvider = NotifierProvider<KioskNotifier, KioskState>(KioskNotifier.new);
final kioskProvider = kioskScanProvider;
