import 'package:flutter/material.dart';
import '../models/gate_model.dart';
import '../viewmodels/gate_selection_viewmodel.dart';
import 'scanner_view.dart';

/// View for selecting the Campus Branch and Gate station
class GateSelectionView extends StatefulWidget {
  const GateSelectionView({super.key});

  @override
  State<GateSelectionView> createState() => _GateSelectionViewState();
}

class _GateSelectionViewState extends State<GateSelectionView> {
  late final GateSelectionViewModel _viewModel;

  @override
  void initState() {
    super.initState();
    _viewModel = GateSelectionViewModel();
    _viewModel.loadInitialData();
  }

  void _onGateSelected(GateModel gate) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ScannerView(initialGate: gate),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Select Campus Gate', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        elevation: 0,
      ),
      body: ListenableBuilder(
        listenable: _viewModel,
        builder: (context, _) {
          if (_viewModel.isLoading && _viewModel.branches.isEmpty) {
            return const Center(child: CircularProgressIndicator(color: Colors.blueAccent));
          }

          if (_viewModel.errorMessage != null && _viewModel.gates.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off, size: 48, color: Colors.redAccent),
                  const SizedBox(height: 12),
                  Text(_viewModel.errorMessage!, style: const TextStyle(color: Colors.white70)),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => _viewModel.loadInitialData(),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }

          return Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Branch Selector
                if (_viewModel.branches.isNotEmpty) ...[
                  Row(
                    children: [
                      const Text('Campus / Branch:', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                      const SizedBox(width: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF334155)),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            dropdownColor: const Color(0xFF1E293B),
                            value: _viewModel.selectedBranchCode,
                            items: _viewModel.branches.map((b) => DropdownMenuItem(
                              value: b.id,
                              child: Text(b.name, style: const TextStyle(color: Colors.white)),
                            )).toList(),
                            onChanged: (val) => _viewModel.loadGatesForBranch(val),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                ],

                const Text('Available Gates:', style: TextStyle(color: Colors.white70, fontSize: 14)),
                const SizedBox(height: 10),

                // Gate List
                Expanded(
                  child: _viewModel.gates.isEmpty
                      ? const Center(child: Text('No gates found for this branch.', style: TextStyle(color: Colors.white54)))
                      : ListView.separated(
                          itemCount: _viewModel.gates.length,
                          separatorBuilder: (context, index) => const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final gate = _viewModel.gates[index];
                            return Material(
                              color: const Color(0xFF1E293B),
                              borderRadius: BorderRadius.circular(12),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => _onGateSelected(gate),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.meeting_room, color: Color(0xFF60A5FA), size: 24),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(gate.placeName, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                                            const SizedBox(height: 4),
                                            Text('Branch: ${gate.branchCode.toUpperCase()}  |  Interval: ${gate.tapInterval}m', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                                          ],
                                        ),
                                      ),
                                      const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.white38),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
