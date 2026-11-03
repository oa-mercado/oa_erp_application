import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;
import 'package:flutter/foundation.dart';
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

  /// Callback invoked whenever a low-latency server response provides an authoritative Date & Time
  static void Function(DateTime serverTime)? onServerTimeReceived;

  // Shared session state across ApiService instances for the current base URL
  static String? _sessionBaseUrl;
  static final Map<String, String> _cookies = {};
  static String? _xsrfToken;
  static String? _cachedSchoolLogoUrl;

  // Transport-level single-flight & idempotency guards to guarantee no tap is ever POSTed twice
  static final Map<String, Future<ScanResponseModel>> _inFlightScansByUuid = {};
  static final Map<String, Future<ScanResponseModel>> _inFlightScansByRfid = {};
  static final Map<String, ScanResponseModel> _completedScansByUuid = {};

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
  String? get schoolLogoUrl {
    if (_cachedSchoolLogoUrl != null && _cachedSchoolLogoUrl!.trim().isNotEmpty) {
      return _cachedSchoolLogoUrl;
    }
    if (EnvConfig.schoolLogoUrl.isNotEmpty) {
      return EnvConfig.schoolLogoUrl;
    }
    return null;
  }

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

  /// Extracts cookies (e.g., `XSRF-TOKEN` and `<school>_session`) and server Date header from response headers
  void _updateCookiesFromResponse(http.Response response, String activeOriginUrl, {int? rttMs}) {
    // 1. Extract server Date header if round-trip latency is low (< 2500ms)
    if (rttMs == null || rttMs < 2500) {
      final rawDate = response.headers['date'];
      if (rawDate != null && rawDate.isNotEmpty) {
        try {
          // Convert HTTP GMT Date header to Asia/Manila wall-clock time (UTC+8)
          final parsedUtc = HttpDate.parse(rawDate).toUtc();
          final manila = parsedUtc.add(const Duration(hours: 8));
          final wallClock = DateTime(
            manila.year,
            manila.month,
            manila.day,
            manila.hour,
            manila.minute,
            manila.second,
          );
          onServerTimeReceived?.call(wallClock);
        } catch (_) {}
      }
    }

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

  /// Fetches the authoritative server Date & Time from `/server-time` (or falls back to HTTP Date header)
  Future<DateTime?> fetchServerTime() async {
    try {
      final sw = Stopwatch()..start();
      final uri = Uri.parse('$_baseUrl${ApiConstants.serverTimeEndpoint}');
      final res = await http.get(uri, headers: {'Accept': 'application/json'}).timeout(const Duration(seconds: 15));
      sw.stop();
      _updateCookiesFromResponse(res, _baseUrl, rttMs: sw.elapsedMilliseconds);

      if (res.statusCode == 200) {
        final dynamic decoded = jsonDecode(res.body);
        if (decoded is Map && decoded['datetime'] != null) {
          final rawDt = decoded['datetime'].toString().trim();
          final parsed = DateTime.tryParse(rawDt.replaceFirst(' ', 'T'));
          if (parsed != null) {
            onServerTimeReceived?.call(parsed);
            return parsed;
          }
        }
      }

      // Fallback to HTTP Date header from response
      final rawDate = res.headers['date'];
      if (rawDate != null && rawDate.isNotEmpty) {
        final manila = HttpDate.parse(rawDate).toUtc().add(const Duration(hours: 8));
        final wallClock = DateTime(manila.year, manila.month, manila.day, manila.hour, manila.minute, manila.second);
        onServerTimeReceived?.call(wallClock);
        return wallClock;
      }
    } catch (_) {}
    return null;
  }

  /// Builds request headers, attaching Laravel session cookies & X-XSRF-TOKEN when available
  Map<String, String> _buildHeaders({String? contentType}) {
    final headers = <String, String>{
      'Content-Type': contentType ?? 'application/json',
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
    if (EnvConfig.schoolLogoUrl.isNotEmpty) {
      _cachedSchoolLogoUrl = EnvConfig.schoolLogoUrl;
    }

    if (!forceRefresh &&
        _sessionBaseUrl == _baseUrl &&
        _cookies.isNotEmpty &&
        _xsrfToken != null) {
      return _cachedSchoolLogoUrl;
    }

    try {
      final sw = Stopwatch()..start();
      final uri = Uri.parse('$_baseUrl${ApiConstants.schoolImageEndpoint}');
      final res = await http
          .get(uri, headers: {'Accept': 'application/json, text/plain, */*'})
          .timeout(const Duration(seconds: 15));
      sw.stop();
      _updateCookiesFromResponse(res, _baseUrl, rttMs: sw.elapsedMilliseconds);

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
          final sw = Stopwatch()..start();
          final fallbackUri =
              Uri.parse('${ApiConstants.localBaseUrl}${ApiConstants.schoolImageEndpoint}');
          final res = await http
              .get(fallbackUri, headers: {'Accept': 'application/json, text/plain, */*'})
              .timeout(const Duration(seconds: 3));
          sw.stop();
          _updateCookiesFromResponse(res, ApiConstants.localBaseUrl, rttMs: sw.elapsedMilliseconds);
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

  /// Scrapes the school's kiosk page (`/rfid/{branch_code}/{gate_id}`) and/or `/reader/background`
  /// to automatically discover:
  /// 1. School background / logo image URL (e.g. `https://storage.googleapis.com/hrpai/background_images/...`)
  /// 2. School primary theme color (e.g. `#083980`)
  /// 3. School display title (e.g. `Dominican College Sta Rosa`)
  Future<Map<String, String>> scrapeKioskAppearance({
    required String branchCode,
    dynamic gateId,
    LocalDbService? localDb,
  }) async {
    final Map<String, String> result = {};
    final cleanBranch = branchCode.trim();
    if (cleanBranch.isEmpty) return result;

    // 1. Try scraping HTML from GET /rfid/{branch_code}/{gate_id}
    try {
      final gateParam = (gateId != null && gateId.toString().trim().isNotEmpty)
          ? gateId.toString().trim()
          : '';
      final gatePath = gateParam.isNotEmpty ? '/$cleanBranch/$gateParam' : '/$cleanBranch';
      final uri = Uri.parse('$_baseUrl/rfid$gatePath');
      final res = await http.get(uri, headers: {
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) OrangeAppsKiosk/1.0',
      }).timeout(const Duration(seconds: 15));

      if (res.statusCode == 200 && res.body.isNotEmpty) {
        final html = res.body;

        // A. Extract bg attribute from <rfid-reader-link ... bg="...">
        final bgMatch = RegExp(r'bg=["'']([^"'']+)["'']', caseSensitive: false).firstMatch(html);
        if (bgMatch != null) {
          final bgVal = bgMatch.group(1)?.trim() ?? '';
          if (bgVal.isNotEmpty && (bgVal.startsWith('http://') || bgVal.startsWith('https://'))) {
            result['logo_url'] = bgVal;
          }
        }

        // B. If bg attribute wasn't found or was empty, scrape <img> tags excluding generic branding
        if (!result.containsKey('logo_url')) {
          final imgMatches = RegExp(r'<img[^>]+src=["'']([^"'']+)["'']', caseSensitive: false).allMatches(html);
          for (final m in imgMatches) {
            final src = m.group(1)?.trim() ?? '';
            if (src.isNotEmpty &&
                !src.contains('oa1.png') &&
                !src.contains('oa.png') &&
                !src.contains('rfid_logo_new.png') &&
                (src.startsWith('http://') || src.startsWith('https://'))) {
              result['logo_url'] = src;
              break;
            }
          }
        }

        // C. Extract theme color from <rfid-reader-link ... sch_color="...">
        final colorMatch = RegExp(r'sch_color=["'']([^"'']+)["'']', caseSensitive: false).firstMatch(html);
        if (colorMatch != null) {
          final cVal = colorMatch.group(1)?.trim() ?? '';
          if (cVal.startsWith('#') && (cVal.length == 7 || cVal.length == 9)) {
            result['primary_color'] = cVal;
          }
        }

        // D. Extract page title from <title>...</title>
        final titleMatch = RegExp(r'<title>([^<]+)</title>', caseSensitive: false).firstMatch(html);
        if (titleMatch != null) {
          final tVal = titleMatch.group(1)?.trim().replaceAll('?', '').trim() ?? '';
          if (tVal.isNotEmpty) {
            result['app_title'] = tVal;
          }
        }
      }
    } catch (e) {
      debugPrint('[ApiService] scrapeKioskAppearance HTML fetch error: $e');
    }

    // 2. If logo_url is still missing, try POST /reader/background with branch_code
    if (!result.containsKey('logo_url') || result['logo_url']!.isEmpty) {
      try {
        final res = await _postWithFallback(
          '/reader/background',
          body: jsonEncode({'branch_code': cleanBranch}),
          timeout: const Duration(seconds: 15),
          requiresCsrf: true,
        );
        if (res != null && res.statusCode == 200) {
          final raw = res.body.trim().replaceAll('"', '').replaceAll(r'\/', '/');
          if (raw.startsWith('http://') || raw.startsWith('https://')) {
            result['logo_url'] = raw;
          }
        }
      } catch (e) {
        debugPrint('[ApiService] scrapeKioskAppearance /reader/background error: $e');
      }
    }

    // 3. Apply discovered values to runtime configuration and persist to SQLite
    final logo = result['logo_url'];
    final colorStr = result['primary_color'];
    final title = result['app_title'];

    Color? parsedColor;
    if (colorStr != null && colorStr.isNotEmpty) {
      final hex = colorStr.replaceAll('#', '').trim();
      final intVal = int.tryParse(hex.length == 6 ? 'FF$hex' : hex, radix: 16);
      if (intVal != null) parsedColor = Color(intVal);
    }

    if (logo != null && logo.isNotEmpty) {
      _cachedSchoolLogoUrl = logo;
      if (localDb != null) {
        unawaited(localDb.downloadAndCacheSchoolLogo(logo));
      }
    }

    EnvConfig.setDynamicAppearance(
      logoUrl: logo,
      color: parsedColor,
      appName: (title != null && title.isNotEmpty) ? '$title RFID' : null,
    );

    if (localDb != null && result.isNotEmpty) {
      localDb.saveKioskAppearance(
        logoUrl: logo,
        primaryColor: colorStr,
        appTitle: (title != null && title.isNotEmpty) ? '$title RFID' : null,
        branchCode: cleanBranch,
      );
    }

    return result;
  }

  /// Checks if the ERP server is reachable
  Future<bool> checkConnectivity() async {
    try {
      final sw = Stopwatch()..start();
      final uri = Uri.parse('$_baseUrl${ApiConstants.schoolImageEndpoint}');
      final res = await http.get(uri).timeout(const Duration(seconds: 15));
      sw.stop();
      _updateCookiesFromResponse(res, _baseUrl, rttMs: sw.elapsedMilliseconds);
      return res.statusCode == 200 || res.statusCode == 404 || res.statusCode == 422;
    } catch (_) {
      if (!EnvConfig.isRelease && _baseUrl != ApiConstants.localBaseUrl) {
        try {
          final sw = Stopwatch()..start();
          final fallbackUri =
              Uri.parse('${ApiConstants.localBaseUrl}${ApiConstants.schoolImageEndpoint}');
          final res = await http.get(fallbackUri).timeout(const Duration(seconds: 3));
          sw.stop();
          _updateCookiesFromResponse(res, ApiConstants.localBaseUrl, rttMs: sw.elapsedMilliseconds);
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
    Duration timeout = const Duration(seconds: 15),
    bool requiresCsrf = false,
    String? contentType,
  }) async {
    if (requiresCsrf && (_cookies.isEmpty || _xsrfToken == null || _sessionBaseUrl != _baseUrl)) {
      await ensureSessionAndFetchLogo(forceRefresh: true);
    }

    final headers = _buildHeaders(contentType: contentType);

    // 1. Try configured baseUrl first
    try {
      final sw = Stopwatch()..start();
      final uri = Uri.parse('$_baseUrl$endpoint');
      var res = await http.post(uri, headers: headers, body: body).timeout(timeout);
      sw.stop();
      _updateCookiesFromResponse(res, _baseUrl, rttMs: sw.elapsedMilliseconds);

      // If Laravel returned 419 CSRF token mismatch, refresh session cookies once and retry
      if (res.statusCode == 419 && requiresCsrf) {
        await ensureSessionAndFetchLogo(forceRefresh: true);
        final retryHeaders = _buildHeaders(contentType: contentType);
        final retrySw = Stopwatch()..start();
        res = await http.post(uri, headers: retryHeaders, body: body).timeout(timeout);
        retrySw.stop();
        _updateCookiesFromResponse(res, _baseUrl, rttMs: retrySw.elapsedMilliseconds);
      }

      return res;
    } catch (_) {
      // 2. In debug mode only, fall back to local if configured URL fails
      if (!EnvConfig.isRelease && _baseUrl != ApiConstants.localBaseUrl) {
        try {
          final sw = Stopwatch()..start();
          final fallbackUri = Uri.parse('${ApiConstants.localBaseUrl}$endpoint');
          final res = await http
              .post(fallbackUri, headers: headers, body: body)
              .timeout(const Duration(seconds: 3));
          sw.stop();
          _updateCookiesFromResponse(res, ApiConstants.localBaseUrl, rttMs: sw.elapsedMilliseconds);
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
      timeout: const Duration(seconds: 15),
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
      timeout: const Duration(seconds: 15),
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

  /// Sends an RFID card tap to the ERP for attendance logging & parent SMS.
  /// Enforces transport-level single-flight deduplication and idempotency so the same
  /// tap UUID or concurrent live RFID scan can never trigger duplicate HTTP POST requests.
  Future<ScanResponseModel> sendRfidScan(ScanRecordModel scan) async {
    final uuid = scan.uuid.trim();
    final cleanRfid = scan.rfidCode.trim();

    // 1. Idempotency check: if this exact tap UUID already succeeded, never POST it again
    if (uuid.isNotEmpty && _completedScansByUuid.containsKey(uuid)) {
      // ignore: avoid_print
      print('[ApiService RFID Tap] Skipping duplicate POST for already-completed UUID=$uuid');
      return _completedScansByUuid[uuid]!;
    }

    // 2. Single-flight check by UUID: if this exact tap UUID is currently in-flight, coalesce with it
    if (uuid.isNotEmpty && _inFlightScansByUuid.containsKey(uuid)) {
      // ignore: avoid_print
      print('[ApiService RFID Tap] Coalescing duplicate concurrent call for in-flight UUID=$uuid');
      return _inFlightScansByUuid[uuid]!;
    }

    // 3. Single-flight check by live RFID: if a live scan for this same RFID is already in-flight, coalesce
    final isLiveScan = scan.errorMessage != 'OFFLINE_SAVED';
    if (isLiveScan && cleanRfid.isNotEmpty && _inFlightScansByRfid.containsKey(cleanRfid)) {
      // ignore: avoid_print
      print('[ApiService RFID Tap] Coalescing concurrent live POST for in-flight RFID=$cleanRfid');
      return _inFlightScansByRfid[cleanRfid]!;
    }

    final future = _executeSendRfidScan(scan);
    if (uuid.isNotEmpty) {
      _inFlightScansByUuid[uuid] = future;
    }
    if (isLiveScan && cleanRfid.isNotEmpty) {
      _inFlightScansByRfid[cleanRfid] = future;
    }

    try {
      final result = await future;
      if (result.isSuccess && uuid.isNotEmpty) {
        if (_completedScansByUuid.length >= 1000) {
          _completedScansByUuid.remove(_completedScansByUuid.keys.first);
        }
        _completedScansByUuid[uuid] = result;
      }
      return result;
    } finally {
      if (uuid.isNotEmpty) {
        _inFlightScansByUuid.remove(uuid);
      }
      if (cleanRfid.isNotEmpty && _inFlightScansByRfid[cleanRfid] == future) {
        _inFlightScansByRfid.remove(cleanRfid);
      }
    }
  }

  Future<ScanResponseModel> _executeSendRfidScan(ScanRecordModel scan) async {
    final endpoint = ApiConstants.saveRfidEntryEndpoint;
    final isStudentEntryEndpoint = endpoint.toLowerCase().contains('student_entry');
    final rawPayload = scan.toErpPayload();
    final payloadMap = rawPayload.map((k, v) => MapEntry(k, v.toString()));
    final requestContentType = isStudentEntryEndpoint
        ? 'application/json'
        : 'application/x-www-form-urlencoded';
    final Object requestBody = isStudentEntryEndpoint
        ? jsonEncode(rawPayload)
        : payloadMap;

    // ignore: avoid_print
    print('[ApiService RFID Tap] POST $endpoint');
    // ignore: avoid_print
    print('[ApiService RFID Tap] Full URL: $_baseUrl$endpoint');
    // ignore: avoid_print
    print('[ApiService RFID Tap] Headers: Content-Type: $requestContentType');
    // ignore: avoid_print
    print('[ApiService RFID Tap] Payload: $rawPayload');

    final response = await _postWithFallback(
      endpoint,
      body: requestBody,
      contentType: requestContentType,
      timeout: const Duration(seconds: 20),
      requiresCsrf: isStudentEntryEndpoint,
    );

    if (response != null) {
      // ignore: avoid_print
      print('[ApiService RFID Tap] Response [${response.statusCode}]: ${response.body}');

      if (response.statusCode == 200) {
        try {
          final Map<String, dynamic> data = jsonDecode(response.body);
          final result = ScanResponseModel.fromJson(data, httpStatusCode: 200);
          // ignore: avoid_print
          print('[ApiService RFID Tap] Parsed Result: isSuccess=${result.isSuccess}, isPermanentRejection=${result.isPermanentRejection}, status=${result.status}, message="${result.message}", studentName="${result.studentInfo?.name}", personId="${result.studentInfo?.personId}"');
          return result;
        } catch (e) {
          // ignore: avoid_print
          print('[ApiService RFID Tap] JSON decode error: $e');
          return ScanResponseModel.networkError('Invalid response from server ($e)', httpStatusCode: 200);
        }
      }
    }

    final code = response?.statusCode ?? 0;
    final snippet = response?.body != null
        ? (response!.body.length > 200 ? '${response.body.substring(0, 200)}...' : response.body)
        : 'null response';
    // ignore: avoid_print
    print('[ApiService RFID Tap] sendRfidScan failed ($code): $snippet');
    return ScanResponseModel.networkError('Server returned error $code', httpStatusCode: code);
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
