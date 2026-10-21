import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/config/env_config.dart';
import '../core/constants/api_constants.dart';
import '../models/branch_model.dart';
import '../models/gate_model.dart';
import '../models/scan_record_model.dart';
import '../models/scan_response_model.dart';
import 'local_db_service.dart';

/// Service responsible for all HTTP communication with the existing ERP APIs.
/// Reuses the existing backend web endpoints:
/// 1. GET /schImg (AdminController@getSchImg) -> fetches school logo URL & initializes session + XSRF-TOKEN cookies
/// 2. POST /branches (StudentTrackingController@getBranches)
/// 3. POST /places (StudentTrackingController@places)
/// 4. POST /student_entry (StudentTrackingController@student_entry)
class ApiService {
  String _baseUrl;

  // Shared session state across ApiService instances for the current base URL
  static String? _sessionBaseUrl;
  static final Map<String, String> _cookies = {};
  static String? _xsrfToken;
  static String? _cachedSchoolLogoUrl;

  ApiService({
    String? baseUrl,
  }) : _baseUrl = _normalizeBaseUrl(baseUrl ?? ApiConstants.defaultBaseUrl);

  static String _normalizeBaseUrl(String url) {
    var trimmed = url.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  String get baseUrl => _baseUrl;
  String? get schoolLogoUrl => _cachedSchoolLogoUrl;

  void setBaseUrl(String newUrl) {
    final normalized = _normalizeBaseUrl(newUrl);
    if (_baseUrl != normalized) {
      _baseUrl = normalized;
      if (_sessionBaseUrl != _baseUrl) {
        _cookies.clear();
        _xsrfToken = null;
        _cachedSchoolLogoUrl = null;
      }
    }
  }

  /// Extracts cookies (e.g., `XSRF-TOKEN` and `<school>_session`) from response headers
  void _updateCookiesFromResponse(http.Response response, String activeOriginUrl) {
    final rawSetCookie = response.headers['set-cookie'];
    if (rawSetCookie == null || rawSetCookie.isEmpty) return;

    _sessionBaseUrl = activeOriginUrl;

    // Dart's http package concatenates multiple Set-Cookie headers with ','.
    // Split only on commas that precede a new cookie key=value pair (avoiding commas in expires=Mon, 16-Oct...).
    final cookieParts = rawSetCookie.split(RegExp(r',(?=\s*[A-Za-z0-9_\-]+=)'));
    for (final part in cookieParts) {
      final firstSegment = part.split(';').first.trim();
      final eqIndex = firstSegment.indexOf('=');
      if (eqIndex > 0) {
        final name = firstSegment.substring(0, eqIndex).trim();
        final value = firstSegment.substring(eqIndex + 1).trim();
        _cookies[name] = value;
        if (name.toUpperCase() == 'XSRF-TOKEN') {
          try {
            _xsrfToken = Uri.decodeComponent(value);
          } catch (_) {
            _xsrfToken = value;
          }
        }
      }
    }
  }

  /// Builds request headers, attaching Laravel session cookies & X-XSRF-TOKEN when available
  Map<String, String> _buildHeaders() {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'X-Requested-With': 'XMLHttpRequest',
    };

    if (_cookies.isNotEmpty) {
      headers['Cookie'] = _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    }
    if (_xsrfToken != null && _xsrfToken!.isNotEmpty) {
      headers['X-XSRF-TOKEN'] = _xsrfToken!;
    }
    return headers;
  }

  /// Initializes the Laravel session & CSRF cookies via GET /schImg and caches the school logo URL.
  Future<String?> ensureSessionAndFetchLogo({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _sessionBaseUrl == _baseUrl &&
        _cookies.isNotEmpty &&
        _xsrfToken != null) {
      return _cachedSchoolLogoUrl;
    }

    try {
      final uri = Uri.parse('$_baseUrl${ApiConstants.schoolImageEndpoint}');
      final res = await http
          .get(uri, headers: {'Accept': 'application/json, text/plain, */*'})
          .timeout(const Duration(seconds: 8));
      _updateCookiesFromResponse(res, _baseUrl);

      if (res.statusCode == 200) {
        final body = res.body.trim().replaceAll('"', '');
        if (body.startsWith('http://') || body.startsWith('https://')) {
          _cachedSchoolLogoUrl = body;
        }
      }
      return _cachedSchoolLogoUrl;
    } catch (_) {
      // In debug mode only, fall back to local if configured URL fails
      if (!EnvConfig.isRelease && _baseUrl != ApiConstants.localBaseUrl) {
        try {
          final fallbackUri =
              Uri.parse('${ApiConstants.localBaseUrl}${ApiConstants.schoolImageEndpoint}');
          final res = await http
              .get(fallbackUri, headers: {'Accept': 'application/json, text/plain, */*'})
              .timeout(const Duration(seconds: 3));
          _updateCookiesFromResponse(res, ApiConstants.localBaseUrl);
          if (res.statusCode == 200) {
            final body = res.body.trim().replaceAll('"', '');
            if (body.startsWith('http://') || body.startsWith('https://')) {
              _cachedSchoolLogoUrl = body;
            }
          }
        } catch (_) {}
      }
      return _cachedSchoolLogoUrl;
    }
  }

  /// Checks if the ERP server is reachable
  Future<bool> checkConnectivity() async {
    try {
      final uri = Uri.parse('$_baseUrl${ApiConstants.schoolImageEndpoint}');
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      _updateCookiesFromResponse(res, _baseUrl);
      return res.statusCode == 200 || res.statusCode == 404 || res.statusCode == 422;
    } catch (_) {
      if (!EnvConfig.isRelease && _baseUrl != ApiConstants.localBaseUrl) {
        try {
          final fallbackUri =
              Uri.parse('${ApiConstants.localBaseUrl}${ApiConstants.schoolImageEndpoint}');
          final res = await http.get(fallbackUri).timeout(const Duration(seconds: 3));
          _updateCookiesFromResponse(res, ApiConstants.localBaseUrl);
          return res.statusCode == 200 || res.statusCode == 404 || res.statusCode == 422;
        } catch (_) {}
      }
      return false;
    }
  }

  /// Helper to send a POST request with automatic CSRF session handling and local fallback in debug mode
  Future<http.Response?> _postWithFallback(
    String endpoint, {
    Object? body,
    Duration timeout = const Duration(seconds: 8),
    bool requiresCsrf = false,
  }) async {
    if (requiresCsrf && (_cookies.isEmpty || _xsrfToken == null || _sessionBaseUrl != _baseUrl)) {
      await ensureSessionAndFetchLogo(forceRefresh: true);
    }

    // 1. Try configured baseUrl first
    try {
      final uri = Uri.parse('$_baseUrl$endpoint');
      var res = await http.post(uri, headers: _buildHeaders(), body: body).timeout(timeout);
      _updateCookiesFromResponse(res, _baseUrl);

      // If Laravel returned 419 CSRF token mismatch, refresh session cookies once and retry
      if (res.statusCode == 419 && requiresCsrf) {
        await ensureSessionAndFetchLogo(forceRefresh: true);
        res = await http.post(uri, headers: _buildHeaders(), body: body).timeout(timeout);
        _updateCookiesFromResponse(res, _baseUrl);
      }

      return res;
    } catch (_) {
      // 2. In debug mode only, fall back to local if configured URL fails
      if (!EnvConfig.isRelease && _baseUrl != ApiConstants.localBaseUrl) {
        try {
          final fallbackUri = Uri.parse('${ApiConstants.localBaseUrl}$endpoint');
          final res = await http
              .post(fallbackUri, headers: _buildHeaders(), body: body)
              .timeout(const Duration(seconds: 3));
          _updateCookiesFromResponse(res, ApiConstants.localBaseUrl);
          return res;
        } catch (_) {}
      }
    }
    return null;
  }

  /// Fetches the list of branches configured in creds.json
  Future<List<BranchModel>> fetchBranches() async {
    final response = await _postWithFallback(
      ApiConstants.branchesEndpoint,
      timeout: const Duration(seconds: 10),
      requiresCsrf: true,
    );
    if (response != null && response.statusCode == 200) {
      try {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((json) => BranchModel.fromJson(json)).toList();
      } catch (_) {}
    }
    return [];
  }

  /// Fetches the gates from places_tbl (optionally filtered by branch_code)
  Future<List<GateModel>> fetchGates({String? branchCode}) async {
    final body = jsonEncode({
      if (branchCode != null && branchCode.isNotEmpty && branchCode != 'all')
        'branch_code': branchCode,
    });

    final response = await _postWithFallback(
      ApiConstants.placesEndpoint,
      body: body,
      timeout: const Duration(seconds: 10),
      requiresCsrf: true,
    );
    if (response != null && response.statusCode == 200) {
      try {
        final Map<String, dynamic> data = jsonDecode(response.body);
        if (data['datas'] is List) {
          final List<dynamic> list = data['datas'];
          return list.map((json) => GateModel.fromJson(json)).toList();
        }
      } catch (_) {}
    }
    return [];
  }

  /// Sends an RFID card tap to the ERP for attendance logging & parent SMS
  Future<ScanResponseModel> sendRfidScan(ScanRecordModel scan) async {
    final response = await _postWithFallback(
      ApiConstants.saveRfidEntryEndpoint,
      body: jsonEncode(scan.toErpPayload()),
      timeout: const Duration(seconds: 8),
      requiresCsrf: false,
    );
    if (response != null && response.statusCode == 200) {
      try {
        final Map<String, dynamic> data = jsonDecode(response.body);
        return ScanResponseModel.fromJson(data);
      } catch (_) {
        return ScanResponseModel.networkError('Invalid response from server');
      }
    }
    final code = response?.statusCode ?? 0;
    final snippet = response?.body != null
        ? (response!.body.length > 200 ? '${response.body.substring(0, 200)}...' : response.body)
        : 'null response';
    // ignore: avoid_print
    print('[ApiService] sendRfidScan failed ($code): $snippet');
    return ScanResponseModel.networkError('Unable to connect or server timed out (>8s)');
  }

  /// Fetches the full K-12, College, and Employee roster from `/kiosk_sync_roster` (session-free)
  Future<List<CachedStudentProfile>> fetchKioskRoster({
    required String branchCode,
    int rfidOnly = 0,
  }) async {
    final response = await _postWithFallback(
      ApiConstants.syncRosterEndpoint,
      body: jsonEncode({
        if (branchCode.isNotEmpty && branchCode != 'all') 'branch_code': branchCode,
        'rfid_only': rfidOnly,
      }),
      timeout: const Duration(seconds: 60),
      requiresCsrf: false,
    );
    if (response != null && response.statusCode == 200) {
      try {
        final Map<String, dynamic> data = jsonDecode(response.body);
        if (data['datas'] is List) {
          final List<dynamic> list = data['datas'];
          return list
              .whereType<Map>()
              .map((item) => CachedStudentProfile.fromJson(Map<String, dynamic>.from(item)))
              .toList();
        }
      } catch (e) {
        // ignore: avoid_print
        print('[ApiService] JSON decode error in fetchKioskRoster: $e');
      }
    } else {
      final code = response?.statusCode ?? 0;
      final preview = response?.body != null
          ? (response!.body.length > 200 ? '${response.body.substring(0, 200)}...' : response.body)
          : 'null response';
      // ignore: avoid_print
      print('[ApiService] fetchKioskRoster failed ($code): $preview');
    }
    return [];
  }
}
