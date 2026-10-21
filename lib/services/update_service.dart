import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../core/config/env_config.dart';

/// Model representing the remote maintenance and version status for a school
class AppRemoteStatus {
  final String latestVersion;
  final String minVersion;
  final bool maintenance;
  final String maintenanceMessage;
  final String downloadUrl;

  const AppRemoteStatus({
    this.latestVersion = '',
    this.minVersion = '',
    this.maintenance = false,
    this.maintenanceMessage = 'System is currently undergoing scheduled maintenance. Please wait or contact administrator.',
    this.downloadUrl = '',
  });

  factory AppRemoteStatus.fromJson(Map<String, dynamic> json) {
    return AppRemoteStatus(
      latestVersion: json['latest_version']?.toString() ?? '',
      minVersion: json['min_version']?.toString() ?? '',
      maintenance: json['maintenance'] == true ||
          json['maintenance']?.toString().toLowerCase() == 'true' ||
          json['maintenance'] == 1,
      maintenanceMessage: json['maintenance_message']?.toString() ??
          'System is currently undergoing scheduled maintenance. Please wait or contact administrator.',
      downloadUrl: json['download_url']?.toString() ?? '',
    );
  }
}

/// Service to check maintenance status and update availability from GCS `version.json`
class UpdateAndMaintenanceService {
  final http.Client _client;

  UpdateAndMaintenanceService({http.Client? client}) : _client = client ?? http.Client();

  /// Compares current version string (e.g. "1.0.0+1" or "v1.0.0+1") with remote version.
  /// Returns true if remote is strictly newer.
  static bool isUpdateAvailable(String currentVersion, String remoteVersion) {
    if (remoteVersion.trim().isEmpty) return false;
    final cur = _cleanVersion(currentVersion);
    final rem = _cleanVersion(remoteVersion);

    return _compareVersions(cur, rem) < 0;
  }

  static String _cleanVersion(String v) {
    var cleaned = v.trim().toLowerCase();
    if (cleaned.startsWith('v')) cleaned = cleaned.substring(1);
    return cleaned;
  }

  /// Returns -1 if v1 < v2, 1 if v1 > v2, 0 if equal
  static int _compareVersions(String v1, String v2) {
    final v1Parts = v1.split('+').first.split('.');
    final v2Parts = v2.split('+').first.split('.');

    final maxLen = v1Parts.length > v2Parts.length ? v1Parts.length : v2Parts.length;
    for (int i = 0; i < maxLen; i++) {
      final p1 = i < v1Parts.length ? (int.tryParse(v1Parts[i]) ?? 0) : 0;
      final p2 = i < v2Parts.length ? (int.tryParse(v2Parts[i]) ?? 0) : 0;
      if (p1 < p2) return -1;
      if (p1 > p2) return 1;
    }

    // Compare build numbers after '+' if present
    final b1 = v1.contains('+') ? (int.tryParse(v1.split('+').last) ?? 0) : 0;
    final b2 = v2.contains('+') ? (int.tryParse(v2.split('+').last) ?? 0) : 0;
    if (b1 < b2) return -1;
    if (b1 > b2) return 1;

    return 0;
  }

  /// Fetches the latest config from Google Cloud Storage with cache-busting timestamp
  Future<AppRemoteStatus?> fetchRemoteStatus({String? schoolKey}) async {
    final url = EnvConfig.versionCheckUrl;
    if (url.isEmpty) return null;

    final targetSchool = (schoolKey ?? EnvConfig.schoolBranch).trim().toLowerCase();

    try {
      // Append cache-buster query parameter
      final uri = Uri.parse(url).replace(queryParameters: {
        't': DateTime.now().millisecondsSinceEpoch.toString(),
      });

      final response = await _client.get(
        uri,
        headers: {
          'Cache-Control': 'no-cache, no-store, must-revalidate',
          'Pragma': 'no-cache',
          'Expires': '0',
        },
      ).timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          // Check if key exists for targetSchool (e.g. "schooltesterp" or without "erp")
          Map<String, dynamic>? schoolData;
          if (decoded.containsKey(targetSchool) && decoded[targetSchool] is Map) {
            schoolData = Map<String, dynamic>.from(decoded[targetSchool]);
          } else {
            // Check fallback without 'erp' suffix if present
            final altKey = targetSchool.endsWith('erp')
                ? targetSchool.substring(0, targetSchool.length - 3)
                : '${targetSchool}erp';
            if (decoded.containsKey(altKey) && decoded[altKey] is Map) {
              schoolData = Map<String, dynamic>.from(decoded[altKey]);
            } else if (decoded.containsKey('default') && decoded['default'] is Map) {
              schoolData = Map<String, dynamic>.from(decoded['default']);
            }
          }

          if (schoolData != null) {
            return AppRemoteStatus.fromJson(schoolData);
          }
        }
      }
    } catch (e) {
      debugPrint('[UpdateService] Check status error: $e');
    }
    return null;
  }

  /// Downloads the installer .exe into temp directory, with progress callback (0.0 to 1.0)
  Future<File?> downloadInstaller({
    required String downloadUrl,
    required void Function(double progress) onProgress,
  }) async {
    try {
      final request = http.Request('GET', Uri.parse(downloadUrl));
      final response = await _client.send(request);

      if (response.statusCode != 200) return null;

      final contentLength = response.contentLength ?? 0;
      final tempDir = Directory.systemTemp;
      final tempFile = File('${tempDir.path}\\oa_erp_update_${DateTime.now().millisecondsSinceEpoch}.exe');

      final sink = tempFile.openWrite();
      int received = 0;

      await response.stream.listen((chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (contentLength > 0) {
          onProgress(received / contentLength);
        }
      }).asFuture();

      await sink.flush();
      await sink.close();

      return tempFile;
    } catch (e) {
      debugPrint('[UpdateService] Download failed: $e');
      return null;
    }
  }

  /// Launches the downloaded Windows installer executable detached
  Future<void> launchInstaller(File installerFile) async {
    try {
      await Process.start(
        installerFile.path,
        ['/SILENT'],
        mode: ProcessStartMode.detached,
      );
    } catch (e) {
      debugPrint('[UpdateService] Error launching silent installer: $e');
      try {
        await Process.start(
          installerFile.path,
          [],
          mode: ProcessStartMode.detached,
        );
      } catch (_) {}
    }
  }

  /// Launches the downloaded Windows installer executable and gracefully closes the current kiosk
  Future<void> launchInstallerAndExit(File installerFile) async {
    try {
      // Launch installer detached from this process
      await Process.start(
        installerFile.path,
        ['/SILENT'], // Supports Inno Setup / NSIS silent/standard install flags
        mode: ProcessStartMode.detached,
      );

      // Gracefully exit the app
      await Future.delayed(const Duration(milliseconds: 500));
      exit(0);
    } catch (e) {
      debugPrint('[UpdateService] Error launching installer: $e');
      // Fallback: start normally without silent flag
      try {
        await Process.start(
          installerFile.path,
          [],
          mode: ProcessStartMode.detached,
        );
        exit(0);
      } catch (_) {}
    }
  }
}
