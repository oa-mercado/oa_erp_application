import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/hris_attendance_provider.dart';
import '../providers/kiosk_provider.dart';

/// Faithful desktop counterpart of HRIS `AttendancePasscode.vue` (`/hris/attendance/passcode`).
/// Displayed automatically when a school's `GET /hris/online_attendance` redirects to `/hris/attendance/passcode`.
class HrisPasscodeView extends ConsumerStatefulWidget {
  const HrisPasscodeView({super.key});

  @override
  ConsumerState<HrisPasscodeView> createState() => _HrisPasscodeViewState();
}

class _HrisPasscodeViewState extends ConsumerState<HrisPasscodeView> {
  final TextEditingController _passcodeController = TextEditingController();
  final FocusNode _passcodeFocusNode = FocusNode();
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _passcodeFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _passcodeController.dispose();
    _passcodeFocusNode.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
    final hrisState = ref.read(hrisAttendanceProvider);
    if (hrisState.isVerifyingPasscode) return;

    final ok = await ref
        .read(hrisAttendanceProvider.notifier)
        .submitPasscode(_passcodeController.text);
    if (!ok && mounted) {
      _passcodeFocusNode.requestFocus();
    }
  }

  Widget _buildSchoolLogo(HrisAttendanceState state) {
    final localPath = state.cachedSchoolLogoPath;
    if (localPath != null && localPath.isNotEmpty && File(localPath).existsSync()) {
      return Image.file(
        File(localPath),
        height: 165,
        fit: BoxFit.contain,
      );
    }

    final networkUrl = (state.passcodeLogoUrl ?? state.config.schoolImage).trim();
    if (networkUrl.isNotEmpty &&
        (networkUrl.startsWith('http://') || networkUrl.startsWith('https://'))) {
      return Image.network(
        networkUrl,
        height: 165,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _fallbackLogo(),
      );
    }

    return _fallbackLogo();
  }

  Widget _fallbackLogo() {
    return Image.asset(
      'assets/images/logo.png',
      height: 140,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => const Icon(
        Icons.school_rounded,
        size: 96,
        color: Color(0xFF409EFF),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(hrisAttendanceProvider);
    final isOffline = ref.watch(isOfflineProvider);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 400, maxWidth: 500),
          child: Container(
            padding: const EdgeInsets.fromLTRB(32, 28, 32, 28),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFFEBEEF5)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x18000000),
                  blurRadius: 14,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Centered School Logo (`<img style="margin: 2rem;" :src="schoolImg" height="175px">`)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: _buildSchoolLogo(state),
                  ),
                ),
                const SizedBox(height: 8),

                // Label: "Passcode"
                const Text(
                  'Passcode',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF606266),
                  ),
                ),
                const SizedBox(height: 10),

                // Password Input (`<el-input v-model="passcode" show-password>`)
                TextField(
                  controller: _passcodeController,
                  focusNode: _passcodeFocusNode,
                  obscureText: _obscurePassword,
                  enabled: !state.isVerifyingPasscode,
                  onSubmitted: (_) => _onSubmit(),
                  style: const TextStyle(
                    fontSize: 15,
                    color: Color(0xFF303133),
                  ),
                  decoration: InputDecoration(
                    hintText: 'Enter attendance passcode',
                    hintStyle: const TextStyle(
                      fontSize: 14,
                      color: Color(0xFFC0C4CC),
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                    filled: true,
                    fillColor: Colors.white,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        size: 19,
                        color: const Color(0xFF909399),
                      ),
                      tooltip: _obscurePassword ? 'Show passcode' : 'Hide passcode',
                      onPressed: () {
                        setState(() => _obscurePassword = !_obscurePassword);
                      },
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: const BorderSide(color: Color(0xFFDCDFE6)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: const BorderSide(color: Color(0xFFDCDFE6)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: const BorderSide(color: Color(0xFF409EFF), width: 1.5),
                    ),
                  ),
                ),

                if (state.passcodeError != null && state.passcodeError!.trim().isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF0F0),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0xFFFDE2E2)),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline_rounded,
                          size: 18,
                          color: Color(0xFFF56C6C),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            state.passcodeError!,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFFF56C6C),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 20),

                // Right-aligned Submit Button (`<el-button class="pull-right" :loading="isLoading" type="primary">Submit</el-button>`)
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (isOffline) ...[
                      OutlinedButton.icon(
                        onPressed: state.isInitializing
                            ? null
                            : () => ref
                                .read(hrisAttendanceProvider.notifier)
                                .initializePortal(),
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Retry Connection'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF606266),
                          side: const BorderSide(color: Color(0xFFDCDFE6)),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    FilledButton(
                      onPressed: state.isVerifyingPasscode ? null : _onSubmit,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF409EFF),
                        disabledBackgroundColor: const Color(0xFFA0CFFF),
                        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (state.isVerifyingPasscode) ...[
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          const Text(
                            'Submit',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
