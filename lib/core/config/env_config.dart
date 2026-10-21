import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Configuration manager that reads from the `.env` file.
/// Before building a release, simply change `RELEASE_BASE_URL` (or `RELEASE_BRANCH`) in `.env`.
class EnvConfig {
  static final Map<String, String> _env = {};

  static String _packageVersion = '1.0.0+1';

  /// Loads `.env` file from assets and reads app version from package_info_plus (pubspec.yaml)
  static Future<void> init() async {
    try {
      final content = await rootBundle.loadString('.env');
      for (final rawLine in content.split('\n')) {
        final line = rawLine.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        final separatorIndex = line.indexOf('=');
        if (separatorIndex > 0) {
          final key = line.substring(0, separatorIndex).trim();
          final val = line.substring(separatorIndex + 1).trim();
          _env[key] = val;
        }
      }
    } catch (_) {
      // In tests or if .env is missing, defaults will be used
    }

    // Automatically read version & build number from pubspec.yaml
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final v = packageInfo.version;
      final b = packageInfo.buildNumber;
      if (v.isNotEmpty) {
        _packageVersion = b.isNotEmpty ? '$v+$b' : v;
      }
    } catch (_) {
      // Fallback to default
    }
  }

  /// Retrieves a key from .env with fallback
  static String get(String key, {String defaultValue = ''}) {
    return _env[key] ?? defaultValue;
  }

  static String _normalizeUrl(String url) {
    var trimmed = url.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  /// The active Base URL:
  /// - When in Debug mode (`--debug`): Always uses `DEBUG_BASE_URL` from `.env` (defaults to http://localhost/qr).
  /// - When in Release mode (`--release`): Uses `RELEASE_BASE_URL` directly from `.env`.
  static String get baseUrl {
    if (kDebugMode) {
      return _normalizeUrl(get('DEBUG_BASE_URL', defaultValue: 'http://localhost/qr'));
    }

    // In release mode: directly use whatever you configured in RELEASE_BASE_URL in .env
    final releaseUrl = get('RELEASE_BASE_URL');
    if (releaseUrl.isNotEmpty) {
      return _normalizeUrl(releaseUrl);
    }

    // Or if you specified RELEASE_BRANCH (e.g. RELEASE_BRANCH=esps)
    final branch = get('RELEASE_BRANCH');
    if (branch.isNotEmpty) {
      return 'https://${branch.trim().toLowerCase()}erp.orangeapps.ph/qr';
    }

    return 'https://schooltesterp.orangeapps.ph/qr';
  }

  /// Helper to get the branch base URL (in release mode uses the configured RELEASE_BASE_URL)
  static String getBranchBaseUrl(String branchCode) {
    if (kDebugMode) {
      return _normalizeUrl(get('DEBUG_BASE_URL', defaultValue: 'http://localhost/qr'));
    }
    // In release mode, the configured RELEASE_BASE_URL from .env takes priority
    final releaseUrl = get('RELEASE_BASE_URL');
    if (releaseUrl.isNotEmpty) {
      return _normalizeUrl(releaseUrl);
    }
    if (branchCode.isNotEmpty) {
      return 'https://${branchCode.trim().toLowerCase()}erp.orangeapps.ph/qr';
    }
    return baseUrl;
  }

  static String get debugBaseUrl =>
      _normalizeUrl(get('DEBUG_BASE_URL', defaultValue: 'http://localhost/qr'));
  static String get releaseBaseUrl =>
      _normalizeUrl(get('RELEASE_BASE_URL', defaultValue: 'https://schooltesterp.orangeapps.ph/qr'));
  static String get defaultBranch => get('DEFAULT_BRANCH', defaultValue: 'la_salle_greenhills');
  static int get defaultGateId => int.tryParse(get('DEFAULT_GATE_ID', defaultValue: '1')) ?? 1;
  static String get defaultGateName => get('DEFAULT_GATE_NAME', defaultValue: 'scholastica');

  /// App version string from pubspec.yaml (e.g. 1.0.0+1). Can still be manually overridden via APP_VERSION in .env if desired.
  static String get appVersion {
    final manualVersion = get('APP_VERSION');
    if (manualVersion.isNotEmpty) {
      return manualVersion.startsWith('v') ? manualVersion : 'v$manualVersion';
    }
    return _packageVersion.startsWith('v') ? _packageVersion : 'v$_packageVersion';
  }

  /// Extracts the school subdomain key (e.g. 'schooltesterp', 'espserp', 'cdsaerp')
  /// from RELEASE_BASE_URL or RELEASE_BRANCH
  static String get schoolBranch {
    final branch = get('RELEASE_BRANCH');
    if (branch.isNotEmpty) {
      return branch.trim().toLowerCase();
    }

    final releaseUrl = get('RELEASE_BASE_URL');
    if (releaseUrl.isNotEmpty) {
      try {
        final uri = Uri.parse(releaseUrl);
        final host = uri.host; // e.g. schooltesterp.orangeapps.ph or espserp.orangeapps.ph
        final parts = host.split('.');
        if (parts.isNotEmpty) {
          return parts.first.toLowerCase();
        }
      } catch (_) {}
    }

    final defaultB = get('DEFAULT_BRANCH');
    if (defaultB.isNotEmpty) {
      return defaultB.trim().toLowerCase();
    }

    return 'schooltesterp';
  }

  /// Custom background / theme color from .env (e.g. #610303, 610303, #004d40)
  static Color get backgroundColor {
    final hexStr = get('PRIMARY_COLOR', defaultValue: '#610303').replaceAll('#', '').trim();
    if (hexStr.length == 6) {
      final val = int.tryParse('FF$hexStr', radix: 16);
      if (val != null) return Color(val);
    } else if (hexStr.length == 8) {
      final val = int.tryParse(hexStr, radix: 16);
      if (val != null) return Color(val);
    }
    return const Color(0xFF610303);
  }

  /// URL pointing to the GCS version.json configuration file
  static String get versionCheckUrl => get(
        'VERSION_CHECK_URL',
        defaultValue: 'https://storage.googleapis.com/oa-erp-app/rfid/version/version.json',
      );

  /// Configurable RFID tap endpoint from .env (`student_entry` or `save_rfid_entry`)
  static String get tapEndpoint {
    final raw = get('TAP_ENDPOINT', defaultValue: '/student_entry').trim();
    if (raw.isEmpty) return '/student_entry';
    if (raw == 'student_rfid_entry') return '/save_rfid_entry';
    return raw.startsWith('/') ? raw : '/$raw';
  }

  static bool get isRelease => kReleaseMode;
  static bool get isDebug => kDebugMode;
}

