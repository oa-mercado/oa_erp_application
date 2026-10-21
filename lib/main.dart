import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'core/config/env_config.dart';
import 'views/scanner_view.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EnvConfig.init();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(
      size: Size(1280, 768),
      minimumSize: Size(960, 600),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      title: 'OrangeApps RFID Kiosk',
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const ProviderScope(child: OrangeAppsRfidApp()));
}

class OrangeAppsRfidApp extends StatelessWidget {
  const OrangeAppsRfidApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OrangeApps RFID Scanner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          primary: const Color(0xFF2563EB),
        ),
        fontFamily: 'Segoe UI',
      ),
      home: const ScannerView(),
    );
  }
}
