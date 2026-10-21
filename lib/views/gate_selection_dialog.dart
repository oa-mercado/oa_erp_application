import 'package:flutter/material.dart';
import '../viewmodels/gate_selection_viewmodel.dart';

/// Modal dialog matching Element-UI "Select Place Link" modal in Login.vue:
/// Displays Branch Code and Place table with clickable blue links.
class GateSelectionDialog extends StatefulWidget {
  final String? currentBranchCode;

  const GateSelectionDialog({super.key, this.currentBranchCode});

  @override
  State<GateSelectionDialog> createState() => _GateSelectionDialogState();
}

class _GateSelectionDialogState extends State<GateSelectionDialog> {
  late final GateSelectionViewModel _viewModel;

  @override
  void initState() {
    super.initState();
    _viewModel = GateSelectionViewModel();
    _viewModel.loadInitialData(initialBranchCode: widget.currentBranchCode);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      elevation: 12,
      child: Container(
        width: 640,
        constraints: const BoxConstraints(maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Modal Header: "Select Place Link" with 'x' close button
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Select Place Link',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w400,
                      color: Color(0xFF303133),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18, color: Color(0xFF909399)),
                    splashRadius: 18,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Table Header: "Branch Code" and "Place"
            Container(
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: Color(0xFFEBEEF5), width: 1),
                  bottom: BorderSide(color: Color(0xFFEBEEF5), width: 1),
                ),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              child: const Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: Center(
                      child: Text(
                        'Branch Code',
                        style: TextStyle(
                          color: Color(0xFF606266),
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 6,
                    child: Center(
                      child: Text(
                        'Place',
                        style: TextStyle(
                          color: Color(0xFF606266),
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Table Body: Scrollable list of places
            Flexible(
              child: ListenableBuilder(
                listenable: _viewModel,
                builder: (context, _) {
                  if (_viewModel.isLoading && _viewModel.gates.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(40.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Color(0xFF409EFF),
                              ),
                            ),
                            SizedBox(height: 12),
                            Text(
                              'Loading List...',
                              style: TextStyle(color: Color(0xFF909399), fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  if (_viewModel.errorMessage != null && _viewModel.gates.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.info_outline, size: 36, color: Color(0xFFF56C6C)),
                            const SizedBox(height: 10),
                            Text(
                              _viewModel.errorMessage!,
                              style: const TextStyle(color: Color(0xFFF56C6C), fontSize: 13),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 14),
                            TextButton(
                              onPressed: () => _viewModel.loadInitialData(),
                              child: const Text('Retry', style: TextStyle(color: Color(0xFF409EFF))),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  if (_viewModel.gates.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(40.0),
                        child: Text(
                          'No places found.',
                          style: TextStyle(color: Color(0xFF909399), fontSize: 14),
                        ),
                      ),
                    );
                  }

                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: _viewModel.gates.length,
                    separatorBuilder: (context, index) => const Divider(
                      height: 1,
                      thickness: 1,
                      color: Color(0xFFEBEEF5),
                    ),
                    itemBuilder: (context, index) {
                      final gate = _viewModel.gates[index];
                      return Material(
                        color: Colors.transparent,
                        child: InkWell(
                          hoverColor: const Color(0xFFF5F7FA),
                          onTap: () => Navigator.of(context).pop(gate),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                            child: Row(
                              children: [
                                Expanded(
                                  flex: 4,
                                  child: Center(
                                    child: Text(
                                      gate.branchCode,
                                      style: const TextStyle(
                                        color: Color(0xFF409EFF),
                                        fontSize: 14,
                                        fontWeight: FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  flex: 6,
                                  child: Center(
                                    child: Text(
                                      gate.placeName,
                                      style: const TextStyle(
                                        color: Color(0xFF409EFF),
                                        fontSize: 14,
                                        fontWeight: FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
