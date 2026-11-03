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

/// Tracks whether the user has dismissed the soft-lock dialog to operate in offline mode
class SoftLockDismissedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void dismiss() => state = true;
  void reset() => state = false;
}

final softLockDismissedProvider =
    NotifierProvider<SoftLockDismissedNotifier, bool>(SoftLockDismissedNotifier.new);

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

/// Notifier for full roster sync in progress
class IsSyncingRosterNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void setSyncing(bool syncing) => state = syncing;
}

final isSyncingRosterProvider =
    NotifierProvider<IsSyncingRosterNotifier, bool>(IsSyncingRosterNotifier.new);

/// Notifier for offline queue count
class OfflineQueueCountNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void setCount(int count) => state = count;
}

final offlineQueueCountProvider =
    NotifierProvider<OfflineQueueCountNotifier, int>(OfflineQueueCountNotifier.new);

/// Represents background profile picture downloading progress
class AssetSyncProgress {
  final bool isDownloading;
  final int total;
  final int completed;
  final int failed;
  final bool isFinished;

  const AssetSyncProgress({
    this.isDownloading = false,
    this.total = 0,
    this.completed = 0,
    this.failed = 0,
    this.isFinished = false,
  });

  int get processed => completed + failed;
  int get remaining => (total - processed).clamp(0, total);
  double get progressRatio => total > 0 ? (processed / total).clamp(0.0, 1.0) : 0.0;
  int get progressPercent => (progressRatio * 100).toInt();
}

/// Notifier for asset pre-download progress
class AssetSyncProgressNotifier extends Notifier<AssetSyncProgress> {
  @override
  AssetSyncProgress build() => const AssetSyncProgress();

  void updateProgress({
    required bool isDownloading,
    required int total,
    required int completed,
    required int failed,
    bool isFinished = false,
  }) {
    state = AssetSyncProgress(
      isDownloading: isDownloading,
      total: total,
      completed: completed,
      failed: failed,
      isFinished: isFinished,
    );
  }

  void reset() {
    state = const AssetSyncProgress();
  }
}

final assetSyncProgressProvider =
    NotifierProvider<AssetSyncProgressNotifier, AssetSyncProgress>(
  AssetSyncProgressNotifier.new,
);

/// Main Kiosk Notifier managing local DB instant lookup, card stacking, push-left transitions, and per-card 4s timers
class KioskNotifier extends Notifier<KioskState> {
  late ApiService _apiService;
  late LocalDbService _localDb;
  RfidScannerListener? _listener;

  Timer? _heartbeatTimer;
  Timer? _assetFinishedTimer;
  final Map<String, Timer> _cardDismissTimers = {};

  String? _lastScannedCode;
  DateTime? _lastScannedTime;
  final Map<String, DateTime> _cardLastSuccessTapTimes = {};
  /// Tracks the timestamp of the last recorded attendance tap per RFID (for gate tap_interval check)
  final Map<String, DateTime> _lastRecordedTapTimes = {};

  bool _isSyncingRoster = false;
  bool _isSyncingAssets = false;
  bool _isCheckingConnectivity = false;
  String? _lastSyncedBranch;

  /// Tracks UUIDs of taps currently undergoing network sync to prevent duplicate POST requests
  final Set<String> _inFlightSyncUuids = <String>{};
  /// Tracks RFID codes currently undergoing live online lookup (Scenario 1A) to prevent parallel taps
  final Set<String> _inFlightRfidCodes = <String>{};
  bool _isSyncingOfflineQueue = false;

  late UpdateAndMaintenanceService _updateService;

  @override
  KioskState build() {
    _apiService = ref.watch(apiServiceProvider);
    _localDb = ref.watch(localDbServiceProvider);
    _updateService = ref.watch(updateServiceProvider);
    ApiService.onServerTimeReceived = (serverTime) => _localDb.setServerTime(serverTime);
    _listener?.stop();
    _listener = RfidScannerListener(onScanned: handleRfidTap);
    _listener!.start();

    // Initialize pending offline queue count, check remote status, and sync full roster on startup
    Future.microtask(() async {
      // Clear out any old invalid / permanently rejected taps from local DB
      _localDb.clearFailedOrInvalidTaps();
      ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);
      // Verify connectivity immediately on launch
      await _checkConnectivity();
      // Sync authoritative server clock
      unawaited(_apiService.fetchServerTime());
      // Cache all gates from server into SQLite so gate selection works offline
      unawaited(syncGatesFromServer());
      // Run initial maintenance & version check immediately
      await _checkRemoteStatus();
      // Sync all K-12, College, and Employee profiles into SQLite Local DB on startup
      await syncRosterFromServer();
      // Eagerly pre-download photos in background
      unawaited(syncAllPendingAssets());
    });

    _startHeartbeat();

    ref.onDispose(() {
      for (final timer in _cardDismissTimers.values) {
        timer.cancel();
      }
      _cardDismissTimers.clear();
      _heartbeatTimer?.cancel();
      _assetFinishedTimer?.cancel();
      _listener?.stop();
    });

    return const KioskState();
  }

  RfidScannerListener get listener => _listener!;

  /// Returns the current Kiosk Date & Time (adjusted by server sync or manual override)
  DateTime get currentKioskTime => _localDb.now;

  /// Whether the Kiosk Date & Time was manually overridden by the operator
  bool get isManualTime => _localDb.isManualTimeOffset;

  /// Manually sets and persists the Kiosk Date & Time in SQLite (works offline)
  void setManualKioskTime(DateTime targetDateTime) {
    _localDb.setManualTime(targetDateTime);
    _lastRecordedTapTimes.clear();
    _cardLastSuccessTapTimes.clear();
  }

  /// Syncs the Kiosk Date & Time with the ERP server and switches back to Automatic mode
  Future<bool> syncTimeWithServer() async {
    final serverTime = await _apiService.fetchServerTime();
    if (serverTime != null) {
      _localDb.setServerTime(serverTime, forceOverrideManual: true);
      _lastRecordedTapTimes.clear();
      _cardLastSuccessTapTimes.clear();
      return true;
    }
    return false;
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) => _checkConnectivity());
  }

  Future<void> _checkRemoteStatus() async {
    try {
      final status = await _updateService.fetchRemoteStatus(schoolKey: EnvConfig.schoolBranch);
      if (status != null) {
        ref.read(remoteStatusProvider.notifier).updateStatus(status);
        // If hard-lock is active or if soft-lock was turned off, reset dismissal
        if (status.isHardLock || !status.isSoftLock) {
          ref.read(softLockDismissedProvider.notifier).reset();
        }
      }
    } catch (_) {}
  }

  Future<bool> checkConnectivity({bool forceSync = false}) async {
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

      // Refresh version & maintenance status whenever online
      if (!currentlyOffline) {
        await _checkRemoteStatus();
      }

      // Check maintenance status: DO NOT flush offline queue to server if maintenance mode is active!
      final remoteStatus = ref.read(remoteStatusProvider);
      if (remoteStatus.maintenance) {
        debugPrint('[Kiosk] Maintenance active. Postponing offline sync.');
        return !currentlyOffline;
      }

      // Automatically flush offline queue whenever online and pending records exist
      if (!currentlyOffline && _localDb.unsyncedCount > 0) {
        unawaited(syncOfflineQueue(force: forceSync));
      }

      // If we just reconnected OR if local caches (gates / roster) are still empty while online, sync them now
      final needsGates = _localDb.getCachedGates().isEmpty;
      final needsRoster = _localDb.cachedRosterCount == 0;
      if (!currentlyOffline && (wasOffline || forceSync || needsGates || needsRoster)) {
        if (wasOffline || forceSync || needsGates) {
          unawaited(syncGatesFromServer());
        }
        if (wasOffline || forceSync || needsRoster) {
          unawaited(syncRosterFromServer());
        }
        unawaited(syncAllPendingAssets());
      }
      return !currentlyOffline;
    } finally {
      _isCheckingConnectivity = false;
    }
  }

  Future<void> _checkConnectivity() => checkConnectivity();

  /// Fetches all gates from the server and caches them in SQLite `gates_cache`
  /// so the operator can still select/change gates while offline.
  Future<void> syncGatesFromServer() async {
    try {
      await _apiService.ensureSessionAndFetchLogo();
      final gates = await _apiService.fetchGates();
      if (gates.isNotEmpty) {
        ref.read(isOfflineProvider.notifier).setOffline(false);
        _localDb.saveGatesList(gates);
        final currentGate = ref.read(activeGateProvider);
        GateModel? matching;
        for (final g in gates) {
          if (g.id == currentGate.id) {
            matching = g;
            break;
          }
        }
        if (matching != null) {
          ref.read(activeGateProvider.notifier).setGate(matching);
        }
        debugPrint('[Kiosk] Cached ${gates.length} gates into SQLite gates_cache.');
      }

      // Automatically scrape & discover school kiosk appearance (logo, theme color, app title)
      final active = ref.read(activeGateProvider);
      unawaited(_apiService.scrapeKioskAppearance(
        branchCode: active.branchCode,
        gateId: active.id,
        localDb: _localDb,
      ));
    } catch (e) {
      debugPrint('[Kiosk] Failed to sync gates from server: $e');
    }
  }

  /// Requests all K-12 students, K-12 employees, College students, and College employees
  /// from `/kiosk_sync_roster` and saves them into the local SQLite database (`students_cache`).
  /// Returns the number of profiles updated, or null if sync could not proceed.
  Future<int?> syncRosterFromServer({String? branchOverride}) async {
    if (_isSyncingRoster) return null;
    final remoteStatus = ref.read(remoteStatusProvider);
    if (remoteStatus.maintenance) return null;

    final activeGate = ref.read(activeGateProvider);
    final branchCode = (branchOverride ?? activeGate.branchCode).trim();

    _isSyncingRoster = true;
    ref.read(isSyncingRosterProvider.notifier).setSyncing(true);
    int savedCount = 0;
    try {
      unawaited(syncGatesFromServer());
      debugPrint('[Kiosk] Requesting full student & employee roster for branch "$branchCode"...');
      final profiles = await _apiService.fetchKioskRoster(branchCode: branchCode);
      if (profiles.isNotEmpty) {
        ref.read(isOfflineProvider.notifier).setOffline(false);
        savedCount = _localDb.bulkUpsertRoster(profiles, branchCode: branchCode);
        _lastSyncedBranch = branchCode;
        // Clear any stale RFID-based in-memory debounce maps so reassigned RFIDs work immediately
        _lastRecordedTapTimes.removeWhere((key, _) => key.contains('_rfid:'));
        _cardLastSuccessTapTimes.removeWhere((key, _) => key.startsWith('rfid:'));
        debugPrint(
          '[Kiosk] Roster sync complete! Upserted $savedCount profiles into SQLite (total cached: ${_localDb.cachedRosterCount}).',
        );
      } else {
        debugPrint(
          '[Kiosk] Roster sync finished: Server returned 0 profiles. Existing cached profiles intact: ${_localDb.cachedRosterCount}.',
        );
      }
      // Eagerly pre-download photos in the background for any pending profiles
      unawaited(syncAllPendingAssets());
      return savedCount;
    } catch (e) {
      debugPrint('[Kiosk] Roster sync error: $e');
      rethrow;
    } finally {
      _isSyncingRoster = false;
      ref.read(isSyncingRosterProvider.notifier).setSyncing(false);
    }
  }

  /// Background worker that eagerly downloads all pending student/employee photos to `local_db/images/`.
  /// Updates `assetSyncProgressProvider` with real-time processed, remaining, and total counts.
  Future<void> syncAllPendingAssets() async {
    if (_isSyncingAssets) return;
    final isOffline = ref.read(isOfflineProvider);
    if (isOffline) return;

    final activeGate = ref.read(activeGateProvider);
    final baseUrl = activeGate.branchCode.isNotEmpty
        ? EnvConfig.getBranchBaseUrl(activeGate.branchCode)
        : ApiConstants.defaultBaseUrl;

    final candidates = _localDb.getProfilesPendingImageDownload();
    if (candidates.isEmpty) return;

    _isSyncingAssets = true;
    _assetFinishedTimer?.cancel();

    final total = candidates.length;
    int completed = 0;
    int failed = 0;

    ref.read(assetSyncProgressProvider.notifier).updateProgress(
          isDownloading: true,
          total: total,
          completed: 0,
          failed: 0,
        );

    DateTime lastNotify = DateTime.now();

    void notifyProgress(bool force) {
      final now = DateTime.now();
      if (force || now.difference(lastNotify).inMilliseconds >= 120) {
        lastNotify = now;
        ref.read(assetSyncProgressProvider.notifier).updateProgress(
              isDownloading: true,
              total: total,
              completed: completed,
              failed: failed,
            );
      }
    }

    String? resolveUrl(String? rawUrl) {
      if (rawUrl == null || rawUrl.isEmpty) return null;
      if (rawUrl.startsWith('http://') || rawUrl.startsWith('https://')) {
        return rawUrl;
      }
      final cleanBase =
          baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
      final cleanPath = rawUrl.startsWith('/') ? rawUrl : '/$rawUrl';
      return '$cleanBase$cleanPath';
    }

    const concurrency = 6;
    int currentIndex = 0;

    Future<void> worker() async {
      while (currentIndex < candidates.length) {
        if (!_isSyncingAssets) break;
        final index = currentIndex++;
        final profile = candidates[index];
        final fullUrl = resolveUrl(profile.imageUrl);
        if (fullUrl == null || fullUrl.isEmpty) {
          failed++;
          notifyProgress(false);
          continue;
        }

        final path = await _localDb.downloadProfileImage(
          rfidCode: profile.rfidCode,
          personId: profile.personId,
          fullImageUrl: fullUrl,
        );

        if (path != null) {
          completed++;
        } else {
          failed++;
        }
        notifyProgress(false);
      }
    }

    try {
      debugPrint('[Kiosk] Starting background pre-download for $total student images...');
      await Future.wait(List.generate(concurrency, (_) => worker()));
      debugPrint('[Kiosk] Asset pre-download finished: $completed downloaded, $failed failed.');
    } catch (e) {
      debugPrint('[Kiosk] Asset pre-download error: $e');
    } finally {
      _isSyncingAssets = false;
      ref.read(assetSyncProgressProvider.notifier).updateProgress(
            isDownloading: false,
            total: total,
            completed: completed,
            failed: failed,
            isFinished: true,
          );

      _assetFinishedTimer = Timer(const Duration(seconds: 5), () {
        ref.read(assetSyncProgressProvider.notifier).reset();
      });
    }
  }

  void setGate(GateModel gate) {
    final prevBranch = ref.read(activeGateProvider).branchCode;
    _lastRecordedTapTimes.clear();
    ref.read(activeGateProvider.notifier).setGate(gate);
    // If there are pending unsynced taps waiting in the offline queue,
    // reassign them to the newly selected gate so they are sent under the chosen gate when online.
    final reassigned = _localDb.reassignUnsyncedTapsToGate(gate);
    if (reassigned > 0) {
      debugPrint('[Kiosk] Reassigned $reassigned pending unsynced offline tap(s) to gate "${gate.placeName}" (ID=${gate.id}).');
    }
    if (gate.branchCode.isNotEmpty) {
      _apiService.setBaseUrl(EnvConfig.getBranchBaseUrl(gate.branchCode));
      if (gate.branchCode != prevBranch || _lastSyncedBranch != gate.branchCode) {
        unawaited(syncRosterFromServer(branchOverride: gate.branchCode));
      }
      unawaited(_apiService.scrapeKioskAppearance(
        branchCode: gate.branchCode,
        gateId: gate.id,
        localDb: _localDb,
      ));
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
    // 0. Hard-Lock & Soft-Lock Checks
    final remoteStatus = ref.read(remoteStatusProvider);
    final softLockDismissed = ref.read(softLockDismissedProvider);

    // Hard-lock: NEVER let the user tap under any circumstance
    if (remoteStatus.isHardLock) {
      debugPrint('[Kiosk] RFID scan completely blocked: System is under HARD-LOCK.');
      return;
    }

    // Soft-lock: blocked until user dismisses dialog to operate in offline mode
    if (remoteStatus.isSoftLock && !softLockDismissed) {
      debugPrint('[Kiosk] RFID scan ignored: System is under SOFT-LOCK. Dismiss dialog to operate in offline mode.');
      return;
    }

    // Operating mode: if soft-lock was dismissed, force OFFLINE mode
    final isBaseOffline = ref.read(isOfflineProvider);
    final isOffline = isBaseOffline || (remoteStatus.isSoftLock && softLockDismissed);

    // Force-Update Check: if online and update is required, ignore tap
    if (!isBaseOffline && !remoteStatus.isLocked) {
      if (UpdateAndMaintenanceService.isUpdateAvailable(EnvConfig.appVersion, remoteStatus.latestVersion)) {
        debugPrint('[Kiosk] RFID scan ignored: App update is required.');
        return;
      }
    }

    final cleanCode = rfidCode.trim();
    if (cleanCode.isEmpty) return;

    final now = _localDb.now;

    // 1. Hardware debounce: filter out rapid raw key-repeat while card touches scanner (< 800ms)
    if (_lastScannedCode == cleanCode &&
        _lastScannedTime != null &&
        now.difference(_lastScannedTime!).inMilliseconds < 800) {
      return;
    }

    // 1b. In-flight RFID guard: if this card is currently undergoing a live online lookup, ignore duplicate scan
    if (_inFlightRfidCodes.contains(cleanCode)) {
      return;
    }

    _lastScannedCode = cleanCode;
    _lastScannedTime = now;

    final activeGate = ref.read(activeGateProvider);
    final cardId = '${now.microsecondsSinceEpoch}_$cleanCode';
    final effectiveBaseUrl = activeGate.branchCode.isNotEmpty
        ? EnvConfig.getBranchBaseUrl(activeGate.branchCode)
        : ApiConstants.defaultBaseUrl;

    // Lookup student profile in SQLite Local DB first (`rfid_code` -> `student_id_desc`)
    final cachedProfile = _localDb.getStudentByRfid(cleanCode);
    final resolvedStudentId = cachedProfile?.personId.trim() ?? '';
    // Key both rapid debounce and gate tap interval by `student_id_desc` when known,
    // so if an RFID card is reassigned from Student A to Student B, Student B is NEVER blocked by Student A's tap!
    final identityKey = resolvedStudentId.isNotEmpty ? 'student:$resolvedStudentId' : 'rfid:$cleanCode';

    // 2. Hardware rapid-scan debounce (5 seconds)
    // Prevents accidental multiple card reads when student leaves card on reader
    final lastSuccessTap = _cardLastSuccessTapTimes[identityKey];
    if (lastSuccessTap != null) {
      final elapsedSeconds = now.difference(lastSuccessTap).inSeconds;
      const rapidDebounceSeconds = 5;
      if (elapsedSeconds < rapidDebounceSeconds) {
        final remaining = rapidDebounceSeconds - elapsedSeconds;
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
    _cardLastSuccessTapTimes[identityKey] = now;

    // 3. Gate Tap Interval Check (e.g. 15 minutes from places_tbl)
    // Tracked per student (`student_id_desc`) + gate (`place_id`), NOT per `rfid_code`.
    // If student taps again at the same gate within tap_interval:
    // - Display student profile & photo on screen
    // - Skip saving to SQLite local DB (stud_entry_tbl)
    // - Skip remote HTTP POST request to server
    final gateIntervalMinutes = activeGate.tapInterval;
    final gateTapKey = '${activeGate.id}_$identityKey';
    final lastRecordedTap = _lastRecordedTapTimes[gateTapKey] ??
        _localDb.getLastTapEntry(
          cleanCode,
          studentIdDesc: resolvedStudentId,
          placeId: activeGate.id,
        )?.scannedAt;

    final isSameDay = lastRecordedTap != null &&
        lastRecordedTap.year == now.year &&
        lastRecordedTap.month == now.month &&
        lastRecordedTap.day == now.day;

    final isWithinGateInterval = gateIntervalMinutes > 0 &&
        lastRecordedTap != null &&
        isSameDay &&
        now.difference(lastRecordedTap).inSeconds < (gateIntervalMinutes * 60);

    // =========================================================================
    // SCENARIO 2: Student IS found in the Local DB -> Show credentials immediately!
    // =========================================================================
    if (cachedProfile != null) {
      if (isWithinGateInterval) {
        // Tapped within gate tap_interval: display current profile, but skip local DB saving & remote sync
        final localDisplay = _localDb.prepareLocalTapDisplay(
          cachedProfile,
          now,
          allowExit: activeGate.allowExit,
          skipToggle: true,
        );

        final instantCard = ActiveKioskCard(
          id: cardId,
          rfidCode: cleanCode,
          type: KioskCardType.success,
          studentInfo: localDisplay.info,
          scannedAt: now,
        );
        _addCard(instantCard);
        _scheduleCardDismiss(cardId, const Duration(seconds: 4));

        // ignore: avoid_print
        print('[Kiosk Tap Interval] StudentID=$resolvedStudentId (${cachedProfile.name}, RFID=$cleanCode) tapped at Gate=${activeGate.placeName} within ${gateIntervalMinutes}m interval (${now.difference(lastRecordedTap).inSeconds}s ago). Displayed on screen; skipped local DB saving and remote POST.');
        return;
      }

      // Beyond interval: record new attendance entry for this student
      _lastRecordedTapTimes[gateTapKey] = now;

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

      // Resolve student's branch: prefer cached profile's branch if present, otherwise active gate's branch
      final studentBranch = cachedProfile.branchCode.isNotEmpty
          ? cachedProfile.branchCode
          : activeGate.branchCode;

      final scan = ScanRecordModel(
        rfidCode: cleanCode,
        scannedAt: now,
        branchCode: studentBranch,
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

      // Register UUID as in-flight BEFORE saving to SQLite so no background queue can ever pick it up prematurely
      if (!isOffline) {
        _inFlightSyncUuids.add(scan.uuid);
      }

      // ALWAYS immediately record the tap in SQLite stud_entry_tbl so it is NEVER lost!
      _localDb.saveTapEntry(scan.copyWith(
        isSynced: false,
        errorMessage: isOffline ? 'OFFLINE_SAVED' : 'PENDING_SYNC',
      ));
      ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);

      // ignore: avoid_print
      print('[Kiosk Local DB] Tap immediately saved to stud_entry_tbl: UUID=${scan.uuid}, RFID=$cleanCode, Name=${cachedProfile.name}, StudentID=${cachedProfile.personId}, Branch=$studentBranch, isExit=${localDisplay.isExit}');

      if (isOffline) {
        return;
      }

      // Online: send scan to ERP in the background and silently update Local DB if anything changed
      unawaited(
        _syncCachedStudentTapInBackground(
          scan: scan,
          cleanCode: cleanCode,
          branchCode: studentBranch,
          effectiveBaseUrl: effectiveBaseUrl,
          tapTime: now,
        ),
      );
      return;
    }

    // =========================================================================
    // SCENARIO 1: Student is NOT in the Local DB yet
    // =========================================================================
    if (isWithinGateInterval) {
      final lastEntry = _localDb.getLastTapEntry(cleanCode, placeId: activeGate.id);
      if (lastEntry?.studentInfo != null) {
        final instantCard = ActiveKioskCard(
          id: cardId,
          rfidCode: cleanCode,
          type: KioskCardType.success,
          studentInfo: lastEntry!.studentInfo,
          scannedAt: now,
        );
        _addCard(instantCard);
        _scheduleCardDismiss(cardId, const Duration(seconds: 4));

        // ignore: avoid_print
        print('[Kiosk Tap Interval] Uncached RFID=$cleanCode tapped at Gate=${activeGate.placeName} within ${gateIntervalMinutes}m interval. Displayed on screen; skipped local DB saving and remote POST.');
        return;
      }
    }

    // Scenario 1B: No connection -> Do NOT show loading; save tap and say "Please continue"
    if (isOffline) {
      _lastRecordedTapTimes[gateTapKey] = now;
      _cardLastSuccessTapTimes[identityKey] = now;
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

    _inFlightRfidCodes.add(cleanCode);
    _inFlightSyncUuids.add(scan.uuid);
    try {
      final response = await _apiService.sendRfidScan(scan);

      // If server dropped or timed out during request -> queue locally & show "Please continue"
      if (!response.isSuccess &&
          (response.message?.contains('Unable to connect') == true ||
              response.message?.contains('Offline') == true ||
              response.message?.contains('timed out') == true)) {
        ref.read(isOfflineProvider.notifier).setOffline(true);
        _lastRecordedTapTimes[gateTapKey] = now;
        _cardLastSuccessTapTimes[identityKey] = _localDb.now;
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
        final onlineStudentId = onlineInfo.personId.trim();
        final resolvedKey = onlineStudentId.isNotEmpty ? 'student:$onlineStudentId' : identityKey;
        _cardLastSuccessTapTimes.remove('rfid:$cleanCode');
        _cardLastSuccessTapTimes[resolvedKey] = _localDb.now;
        _lastRecordedTapTimes['${activeGate.id}_$resolvedKey'] = now;

        if (response.isTapOnInterval) {
          // ignore: avoid_print
          print('[Kiosk RFID Tap] Server reported tap_on_interval=1 for RFID=$cleanCode (${onlineInfo.name}). Displayed on screen; skipped saving to local DB history.');
        } else {
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
        }

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
        final errMsg = response.message ?? 'Unable to Process Transaction Code Not Found';

        if (response.isPermanentRejection) {
          // Clear out non-existent ID from SQLite so it is discarded
          // ignore: avoid_print
          print('[Kiosk RFID Tap] Remote rejected RFID=$cleanCode ($errMsg). Clearing from local DB & cache...');
          _localDb.deleteTapEntry(scan.uuid);
          _localDb.deleteStudentFromCache(cleanCode);
          ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);

          _updateCard(
            cardId,
            type: KioskCardType.error,
            errorMessage: errMsg,
          );
          _scheduleCardDismiss(cardId, const Duration(seconds: 4));
        } else {
          // Transient network or server error (404, 419, 500, timeout, or unreachable):
          // DO NOT DELETE! Keep safely in local DB for offline queue retry!
          _localDb.saveTapEntry(
            scan.copyWith(
              isSynced: false,
              errorMessage: errMsg,
            ),
          );
          ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);
          if (response.isConnectionFailure) {
            ref.read(isOfflineProvider.notifier).setOffline(true);
          }

          _updateCard(
            cardId,
            type: KioskCardType.error,
            errorMessage: 'Saved offline (pending sync)',
          );
          _scheduleCardDismiss(cardId, const Duration(seconds: 4));
        }
      }
    } catch (e) {
      _updateCard(
        cardId,
        type: KioskCardType.error,
        errorMessage: 'Connection Error: $e',
      );
      _scheduleCardDismiss(cardId, const Duration(seconds: 4));
    } finally {
      _inFlightRfidCodes.remove(cleanCode);
      _inFlightSyncUuids.remove(scan.uuid);
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
    _inFlightSyncUuids.add(scan.uuid);
    try {
      if (_localDb.isRecordSynced(scan.uuid)) {
        return;
      }
      // ignore: avoid_print
      print('[Kiosk Sync Background] Syncing tap with ERP for RFID=$cleanCode (${scan.studentName})...');
      final response = await _apiService.sendRfidScan(scan);

      if (!response.isSuccess &&
          (response.message?.contains('Unable to connect') == true ||
              response.message?.contains('Offline') == true ||
              response.message?.contains('timed out') == true)) {
        ref.read(isOfflineProvider.notifier).setOffline(true);
        _localDb.saveTapEntry(scan.copyWith(isSynced: false, errorMessage: 'OFFLINE_SAVED'));
        ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);
        // ignore: avoid_print
        print('[Kiosk Sync Background] Offline mode triggered for RFID=$cleanCode: ${response.message}');
        return;
      }

      if (response.isSuccess && response.studentInfo != null) {
        final onlineInfo = response.studentInfo!;
        final onlineIsExit = (onlineInfo.ent?.toLowerCase() == 'exit') ? 1 : 0;

        if (response.isTapOnInterval) {
          // Server did NOT record this tap because student tapped within interval (e.g. at another kiosk).
          // Discard the optimistically recorded tap so it does not remain in local history / sync queue!
          // ignore: avoid_print
          print('[Kiosk Sync Background] Server reported tap_on_interval=1 for RFID=$cleanCode (${onlineInfo.name}). Removing from local DB history/queue.');
          _localDb.deleteTapEntry(scan.uuid);
          ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);
        } else {
          _localDb.saveTapEntry(
            scan.copyWith(
              isSynced: true,
              errorMessage: '',
              studentIdDesc: onlineInfo.personId.isNotEmpty ? onlineInfo.personId : scan.studentIdDesc,
              studentName: onlineInfo.name.isNotEmpty ? onlineInfo.name : scan.studentName,
              isCommuter: onlineInfo.isCommuter,
              isExit: onlineIsExit,
              type: onlineInfo.type ?? scan.type,
              gradeLevel: onlineInfo.gradeLevel ?? scan.gradeLevel,
              section: onlineInfo.section ?? scan.section,
              studentInfo: onlineInfo,
            ),
          );
          ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);
          // ignore: avoid_print
          print('[Kiosk Sync Background] Tap successfully SYNCED: RFID=$cleanCode, Name=${onlineInfo.name}, isExit=$onlineIsExit');
        }

        // Silently update Local DB if any student info changed (and download image if needed)
        await _localDb.upsertStudentAndDownloadImage(
          rfidCode: cleanCode,
          branchCode: branchCode,
          onlineInfo: onlineInfo,
          baseUrl: effectiveBaseUrl,
          tapTime: tapTime,
        );
      } else {
        // Server returned an explicit error (e.g. ID not found or validation failure)
        final errMsg = response.message ?? 'Server sync failed';

        if (response.isPermanentRejection) {
          // ignore: avoid_print
          print('[Kiosk Sync Background] Remote rejected RFID=$cleanCode ($errMsg). Clearing out from local DB & cache...');
          _localDb.deleteTapEntry(scan.uuid);
          _localDb.deleteStudentFromCache(cleanCode);
          ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);

          // Update active card on screen if currently displayed to show "ID Not Found!" error
          for (final c in state.activeCards) {
            if (c.rfidCode == cleanCode) {
              _updateCard(
                c.id,
                type: KioskCardType.error,
                errorMessage: errMsg,
              );
              _scheduleCardDismiss(c.id, const Duration(seconds: 4));
            }
          }
        } else {
          // Transient network or server error (404, 419, 500, timeout, or unreachable):
          // DO NOT DELETE! Keep safely in local DB for offline queue retry!
          _localDb.saveTapEntry(scan.copyWith(isSynced: false, errorMessage: errMsg));
          ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);
          if (response.isConnectionFailure) {
            ref.read(isOfflineProvider.notifier).setOffline(true);
          }
        }
        // ignore: avoid_print
        print('[Kiosk Sync Background] Server sync error for RFID=$cleanCode: $errMsg');
      }
    } catch (e) {
      _localDb.saveTapEntry(scan.copyWith(isSynced: false, errorMessage: e.toString()));
      ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);
      // ignore: avoid_print
      print('[Kiosk Sync Background] Exception syncing RFID=$cleanCode: $e');
    } finally {
      _inFlightSyncUuids.remove(scan.uuid);
    }
  }

  DateTime? _lastFailedOfflineSyncTime;

  /// Uploads all unsynced `stud_entry_tbl` records to the server when connection is restored.
  /// If an error occurred previously, enforces at least a 1-minute backoff interval unless [force] is true.
  Future<void> syncOfflineQueue({bool force = false}) async {
    if (_isSyncingOfflineQueue) return;
    if (!force && _lastFailedOfflineSyncTime != null) {
      final elapsed = DateTime.now().difference(_lastFailedOfflineSyncTime!);
      if (elapsed < const Duration(minutes: 1)) {
        return; // Respect 1-minute cooldown before auto-retrying
      }
    }
    _isSyncingOfflineQueue = true;
    try {
      final pending = _localDb.unsyncedRecords
          .where((s) => !_inFlightSyncUuids.contains(s.uuid))
          .toList();
      if (pending.isEmpty) {
        _lastFailedOfflineSyncTime = null;
        return;
      }

      for (final scan in pending) {
        if (_inFlightSyncUuids.contains(scan.uuid)) continue;
        if (_localDb.isRecordSynced(scan.uuid)) continue;
        _inFlightSyncUuids.add(scan.uuid);
        try {
          final res = await _apiService.sendRfidScan(scan);
          if (res.isSuccess) {
            if (res.isTapOnInterval) {
              // Server did NOT record this queued tap because it was within the tap interval.
              // Remove it from the local DB so it doesn't linger in pending or local history:
              // ignore: avoid_print
              print('[Kiosk Offline Sync] Server reported tap_on_interval=1 for queued RFID ${scan.rfidCode}. Removing from local DB queue/history...');
              _localDb.deleteTapEntry(scan.uuid);
            } else {
              _localDb.markRecordSynced(scan.uuid, studentInfo: res.studentInfo);
            }

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
          } else {
            if (res.isPermanentRejection) {
              // True business rejection from ERP (e.g. "Unable to Process Transaction Code Not Found")
              // ignore: avoid_print
              print('[Kiosk Offline Sync] Remote rejected queued RFID ${scan.rfidCode} (${res.message}). Clearing out from local DB...');
              _localDb.deleteTapEntry(scan.uuid);
              _localDb.deleteStudentFromCache(scan.rfidCode);
            } else {
              // Transient network or server error (HTTP 404, 419, 500, timeout, or unreachable):
              // DO NOT DELETE! Keep the tap safely in SQLite stud_entry_tbl with is_synced = 0!
              _localDb.saveTapEntry(scan.copyWith(
                isSynced: false,
                errorMessage: res.message ?? 'Pending sync',
              ));
              // Mark last failed sync attempt so we back off for 1 minute
              _lastFailedOfflineSyncTime = DateTime.now();
              // Only mark network icon offline if there was an actual physical connection loss
              if (res.isConnectionFailure) {
                ref.read(isOfflineProvider.notifier).setOffline(true);
              }
              break;
            }
          }
        } finally {
          _inFlightSyncUuids.remove(scan.uuid);
        }
      }
      if (_localDb.unsyncedCount == 0) {
        _lastFailedOfflineSyncTime = null;
      }
      ref.read(offlineQueueCountProvider.notifier).setCount(_localDb.unsyncedCount);
    } finally {
      _isSyncingOfflineQueue = false;
    }
  }
}

/// Global Provider for the Kiosk Notifier and State
final kioskScanProvider = NotifierProvider<KioskNotifier, KioskState>(KioskNotifier.new);
final kioskProvider = kioskScanProvider;
