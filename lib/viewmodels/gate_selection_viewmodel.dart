import 'package:flutter/foundation.dart';
import '../models/branch_model.dart';
import '../models/gate_model.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';

/// ViewModel managing the business logic for selecting a Branch and Gate
class GateSelectionViewModel extends ChangeNotifier {
  final ApiService _apiService;
  final LocalDbService _localDb;

  List<BranchModel> _branches = [];
  List<GateModel> _gates = [];
  bool _isLoading = false;
  String? _errorMessage;

  String? _selectedBranchCode;
  GateModel? _selectedGate;

  GateSelectionViewModel({ApiService? apiService, LocalDbService? localDb})
      : _apiService = apiService ?? ApiService(),
        _localDb = localDb ?? (LocalDbService()..init());

  List<BranchModel> get branches => _branches;
  List<GateModel> get gates => _gates;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  String? get selectedBranchCode => _selectedBranchCode;
  GateModel? get selectedGate => _selectedGate;

  /// Loads all places matching Login.vue getPlace().
  /// Immediately populates from SQLite `gates_cache` so offline gate selection works seamlessly,
  /// then refreshes from the server when online and persists the updated list.
  Future<void> loadInitialData({String? initialBranchCode}) async {
    _errorMessage = null;

    // 1. Load cached gates from SQLite immediately so list is available offline (<1ms)
    final cachedGates = _localDb.getCachedGates();
    if (cachedGates.isNotEmpty) {
      _gates = cachedGates;
      _isLoading = false;
      notifyListeners();
    } else {
      _isLoading = true;
      notifyListeners();
    }

    try {
      // 2. Ensure session cookies & school logo are initialized first
      await _apiService.ensureSessionAndFetchLogo();

      // 3. Fetch all places from server (matching Login.vue getPlace() which sends no branch filter)
      final onlineGates = await _apiService.fetchGates();
      if (onlineGates.isNotEmpty) {
        _gates = onlineGates;
        _localDb.saveGatesList(onlineGates);
      }
      _branches = await _apiService.fetchBranches();
    } catch (e) {
      if (_gates.isEmpty) {
        _errorMessage = 'Failed to load places: $e';
      }
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Filters gates by the selected branch (falls back to SQLite `gates_cache` if offline)
  Future<void> loadGatesForBranch(String? branchCode) async {
    _selectedBranchCode = branchCode;
    final cached = _localDb.getCachedGates(branchCode: branchCode);
    if (cached.isNotEmpty) {
      _gates = cached;
      _isLoading = false;
      notifyListeners();
    } else {
      _isLoading = true;
      notifyListeners();
    }

    try {
      final onlineGates = await _apiService.fetchGates(branchCode: branchCode);
      if (onlineGates.isNotEmpty) {
        _gates = onlineGates;
      }
    } catch (e) {
      if (_gates.isEmpty) {
        _errorMessage = 'Failed to load gates for branch: $branchCode';
      }
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void selectGate(GateModel gate) {
    _selectedGate = gate;
    notifyListeners();
  }
}
