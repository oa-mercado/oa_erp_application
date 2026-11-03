import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'core/config/env_config.dart';
import 'views/scanner_view.dart';

/// Custom HttpOverrides to handle OrangeApps ERP servers (e.g. dominicanstarosaerp.orangeapps.ph)
/// whose Apache SSL config omits the GoDaddy G2 intermediate certificate from the TLS handshake.
class OrangeAppsHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (X509Certificate cert, String host, int port) {
      final cleanHost = host.toLowerCase().trim();
      return cleanHost == 'orangeapps.ph' ||
          cleanHost.endsWith('.orangeapps.ph') ||
          cleanHost == 'localhost' ||
          cleanHost == '127.0.0.1';
    };
    return client;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = OrangeAppsHttpOverrides();
  await EnvConfig.init();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();

    final windowOptions = WindowOptions(
      size: const Size(1280, 768),
      minimumSize: const Size(960, 600),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      title: EnvConfig.appName,
      titleBarStyle: TitleBarStyle.hidden,
      fullScreen: true,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
      await windowManager.setFullScreen(true);
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
      title: EnvConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: EnvConfig.backgroundColor,
          primary: EnvConfig.backgroundColor,
        ),
        fontFamily: 'Segoe UI',
      ),
      home: const ScannerView(),
    );
  }
}
