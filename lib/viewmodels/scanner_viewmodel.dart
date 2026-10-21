import 'dart:async';
import 'package:flutter/foundation.dart';
import '../core/config/env_config.dart';
import '../core/hardware/rfid_listener.dart';
import '../models/gate_model.dart';
import '../models/scan_record_model.dart';
import '../services/api_service.dart';

/// ViewModel managing the RFID Scanner screen state, offline queue, and card tap processing
class ScannerViewModel extends ChangeNotifier {
  final ApiService _apiService;
  late final RfidScannerListener _listener;
  Timer? _initialCheckTimer;
  Timer? _heartbeatTimer;

  GateModel? _activeGate;
  final List<ScanRecordModel> _scanHistory = [];
  final List<ScanRecordModel> _offlineQueue = [];
  ScanRecordModel? _latestScan;
  bool _isProcessing = false;
  bool _isOffline = false;
  int _lastSyncedCount = 0;

  ScannerViewModel({ApiService? apiService, bool autoHeartbeat = true})
      : _apiService = apiService ?? ApiService() {
    _listener = RfidScannerListener(onScanned: handleRfidTap);
    _listener.start(); // Start listening immediately upon app launch!
    if (autoHeartbeat) {
      _startHeartbeat();
    }
  }

  GateModel? get activeGate => _activeGate;
  RfidScannerListener get listener => _listener;
  List<ScanRecordModel> get scanHistory => List.unmodifiable(_scanHistory);
  List<ScanRecordModel> get offlineQueue => List.unmodifiable(_offlineQueue);
  ScanRecordModel? get latestScan => _latestScan;
  bool get isProcessing => _isProcessing;
  bool get isOffline => _isOffline;
  int get pendingOfflineCount => _offlineQueue.length;
  int get lastSyncedCount => _lastSyncedCount;

  void initialize(GateModel gate) {
    _activeGate = gate;
    if (gate.branchCode.isNotEmpty) {
      _apiService.setBaseUrl(EnvConfig.getBranchBaseUrl(gate.branchCode));
    }
    notifyListeners();
  }

  void _startHeartbeat() {
    // Check connectivity initially after 1 second, then every 10 seconds
    _initialCheckTimer = Timer(const Duration(seconds: 1), _checkConnection);
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) => _checkConnection());
  }

  Future<void> _checkConnection() async {
    final isReachable = await _apiService.checkConnectivity();
    if (_isOffline == isReachable) {
      _isOffline = !isReachable;
      notifyListeners();

      // If just came back online, automatically flush offline queue!
      if (!_isOffline && _offlineQueue.isNotEmpty) {
        await syncOfflineQueue();
      }
    }
  }

  /// Flushes queued offline scans to the ERP backend
  Future<int> syncOfflineQueue() async {
    if (_offlineQueue.isEmpty) return 0;

    int synced = 0;
    final pending = List<ScanRecordModel>.from(_offlineQueue);

    for (final scan in pending) {
      final response = await _apiService.sendRfidScan(scan);
      if (response.isSuccess) {
        _offlineQueue.remove(scan);
        synced++;
      }
    }

    _lastSyncedCount = synced;
    notifyListeners();
    return synced;
  }

  /// Triggered whenever an RFID card is tapped (or keyboard enters a code)
  Future<void> handleRfidTap(String rfidCode) async {
    final cleanCode = rfidCode.trim();
    if (cleanCode.isEmpty) return;

    final initialScan = ScanRecordModel(
      rfidCode: cleanCode,
      scannedAt: DateTime.now(),
      branchCode: _activeGate?.branchCode ?? EnvConfig.defaultBranch,
      placeId: _activeGate?.id ?? EnvConfig.defaultGateId,
      placeName: _activeGate?.placeName ?? EnvConfig.defaultGateName,
    );

    _latestScan = initialScan;
    _isProcessing = true;
    notifyListeners();

    // 1. If currently in offline mode -> Queue locally!
    if (_isOffline) {
      final offlineScan = initialScan.copyWith(
        isSynced: false,
        errorMessage: 'OFFLINE_SAVED',
      );
      _offlineQueue.add(offlineScan);
      _scanHistory.insert(0, offlineScan);
      _latestScan = offlineScan;
      _isProcessing = false;
      notifyListeners();
      return;
    }

    // 2. If online -> Send scan to ERP backend (save_rfid_entry)
    final response = await _apiService.sendRfidScan(initialScan);

    // If server was unreachable during the scan, mark offline and queue it!
    if (!response.isSuccess && (response.message?.contains('Unable to connect') == true || response.message?.contains('Offline') == true)) {
      _isOffline = true;
      final offlineScan = initialScan.copyWith(
        isSynced: false,
        errorMessage: 'OFFLINE_SAVED',
      );
      _offlineQueue.add(offlineScan);
      _scanHistory.insert(0, offlineScan);
      _latestScan = offlineScan;
      _isProcessing = false;
      notifyListeners();
      return;
    }

    final updatedScan = initialScan.copyWith(
      isSynced: response.isSuccess,
      studentInfo: response.studentInfo,
      errorMessage: response.isSuccess ? null : (response.message ?? 'Unable to Process Transaction Code Not Found'),
    );

    _latestScan = updatedScan;
    _scanHistory.insert(0, updatedScan);
    _isProcessing = false;
    notifyListeners();
  }

  void clearHistory() {
    _scanHistory.clear();
    _offlineQueue.clear();
    _latestScan = null;
    notifyListeners();
  }

  void disposeListener() {
    _initialCheckTimer?.cancel();
    _heartbeatTimer?.cancel();
    _listener.stop();
  }
}
