import 'package:flutter/foundation.dart';
import '../models/branch_model.dart';
import '../models/gate_model.dart';
import '../services/api_service.dart';

/// ViewModel managing the business logic for selecting a Branch and Gate
class GateSelectionViewModel extends ChangeNotifier {
  final ApiService _apiService;

  List<BranchModel> _branches = [];
  List<GateModel> _gates = [];
  bool _isLoading = false;
  String? _errorMessage;

  String? _selectedBranchCode;
  GateModel? _selectedGate;

  GateSelectionViewModel({ApiService? apiService})
      : _apiService = apiService ?? ApiService();

  List<BranchModel> get branches => _branches;
  List<GateModel> get gates => _gates;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  String? get selectedBranchCode => _selectedBranchCode;
  GateModel? get selectedGate => _selectedGate;

  /// Loads all places matching Login.vue getPlace()
  Future<void> loadInitialData({String? initialBranchCode}) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      // Ensure session cookies & school logo are initialized first
      await _apiService.ensureSessionAndFetchLogo();

      // Fetch all places (matching Login.vue getPlace() which sends no branch filter)
      _gates = await _apiService.fetchGates();
      _branches = await _apiService.fetchBranches();
    } catch (e) {
      _errorMessage = 'Failed to load places: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Filters gates by the selected branch
  Future<void> loadGatesForBranch(String? branchCode) async {
    _selectedBranchCode = branchCode;
    _isLoading = true;
    notifyListeners();

    try {
      _gates = await _apiService.fetchGates(branchCode: branchCode);
    } catch (e) {
      _errorMessage = 'Failed to load gates for branch: $branchCode';
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
