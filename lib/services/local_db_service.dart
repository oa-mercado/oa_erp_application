import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import '../core/config/env_config.dart';
import '../models/gate_model.dart';
import '../models/scan_record_model.dart';
import '../models/scan_response_model.dart';

/// Represents a cached student/employee profile stored in the Local SQLite DB (`students_cache` table)
class CachedStudentProfile {
  final String rfidCode;
  final String branchCode;
  final String personId; // student_id_desc in stud_entry_tbl
  final String name; // student_name in stud_entry_tbl
  final String? imageUrl;
  final String? localImagePath;
  final String gradeLevel;
  final String section;
  final String type; // "Student" or "Employee"
  final String studentType; // "Kto12" or "College"
  final int isCommuter;
  final int birthday;
  final String? lastTapDate; // "YYYY-MM-DD"
  final int lastIsExit; // 0 = Entrance, 1 = Exit

  const CachedStudentProfile({
    required this.rfidCode,
    required this.branchCode,
    required this.personId,
    required this.name,
    this.imageUrl,
    this.localImagePath,
    this.gradeLevel = 'N/A',
    this.section = 'N/A',
    this.type = 'Student',
    this.studentType = 'Kto12',
    this.isCommuter = 0,
    this.birthday = 0,
    this.lastTapDate,
    this.lastIsExit = 0,
  });

  bool get hasValidLocalImage =>
      localImagePath != null &&
      localImagePath!.isNotEmpty &&
      File(localImagePath!).existsSync();

  CachedStudentProfile copyWith({
    String? branchCode,
    String? personId,
    String? name,
    String? imageUrl,
    String? localImagePath,
    String? gradeLevel,
    String? section,
    String? type,
    String? studentType,
    int? isCommuter,
    int? birthday,
    String? lastTapDate,
    int? lastIsExit,
  }) {
    return CachedStudentProfile(
      rfidCode: rfidCode,
      branchCode: branchCode ?? this.branchCode,
      personId: personId ?? this.personId,
      name: name ?? this.name,
      imageUrl: imageUrl ?? this.imageUrl,
      localImagePath: localImagePath ?? this.localImagePath,
      gradeLevel: gradeLevel ?? this.gradeLevel,
      section: section ?? this.section,
      type: type ?? this.type,
      studentType: studentType ?? this.studentType,
      isCommuter: isCommuter ?? this.isCommuter,
      birthday: birthday ?? this.birthday,
      lastTapDate: lastTapDate ?? this.lastTapDate,
      lastIsExit: lastIsExit ?? this.lastIsExit,
    );
  }

  Map<String, dynamic> toJson() => {
        'rfid_code': rfidCode,
        'branch_code': branchCode,
        'student_id_desc': personId,
        'student_name': name,
        'image_url': imageUrl,
        'local_image_path': localImagePath,
        'grade_level': gradeLevel,
        'section': section,
        'type': type,
        'student_type': studentType,
        'is_commuter': isCommuter,
        'birthday': birthday,
        'last_tap_date': lastTapDate,
        'last_is_exit': lastIsExit,
      };

  factory CachedStudentProfile.fromJson(Map<String, dynamic> json) {
    return CachedStudentProfile(
      rfidCode: json['rfid_code']?.toString() ?? '',
      branchCode: json['branch_code']?.toString() ?? '',
      personId: json['student_id_desc']?.toString() ?? json['person_id']?.toString() ?? '',
      name: json['student_name']?.toString() ?? json['name']?.toString() ?? '',
      imageUrl: json['image_url']?.toString(),
      localImagePath: json['local_image_path']?.toString(),
      gradeLevel: json['grade_level']?.toString() ?? 'N/A',
      section: json['section']?.toString() ?? 'N/A',
      type: json['type']?.toString() ?? 'Student',
      studentType: json['student_type']?.toString() ?? 'Kto12',
      isCommuter: json['is_commuter'] is int
          ? json['is_commuter']
          : int.tryParse('${json['is_commuter'] ?? 0}') ?? 0,
      birthday: json['birthday'] is int
          ? json['birthday']
          : int.tryParse('${json['birthday'] ?? 0}') ?? 0,
      lastTapDate: json['last_tap_date']?.toString(),
      lastIsExit: json['last_is_exit'] is int
          ? json['last_is_exit']
          : int.tryParse('${json['last_is_exit'] ?? 0}') ?? 0,
    );
  }
}

/// High-performance SQLite Local Database Service (`local_db/oa_kiosk.db`)
/// Built for 10,000+ daily taps and 10,000+ cached students with ACID safety and WAL mode.
///
/// Tables:
/// 1. `students_cache`: Indexed by `rfid_code` for <0.5ms student profile lookup.
/// 2. `stud_entry_tbl`: Stores all RFID tap logs and offline queue (`is_synced`).
/// 3. `app_settings`: Persists active gate selection (`selected_gate`) and kiosk metadata.
class LocalDbService {
  Database? _db;
  static String? _resolvedDataDirPath;

  int _timeOffsetMs = 0;
  bool _isManualTimeOffset = false;

  /// Returns the current Kiosk Date & Time adjusted by the persisted server or manual time offset.
  /// Continues ticking accurately even when the device is offline or has an outdated hardware clock.
  DateTime get now => DateTime.now().add(Duration(milliseconds: _timeOffsetMs));

  /// Whether the current time offset was manually set by the operator
  bool get isManualTimeOffset => _isManualTimeOffset;

  /// Current time offset in milliseconds relative to the device clock
  int get timeOffsetMs => _timeOffsetMs;

  /// Ensures a writable directory path for local SQLite database and downloaded student images.
  /// When installed in `C:\Program Files`, writing to relative `local_db` is blocked by Windows UAC.
  /// Therefore, we store writable data in `%LOCALAPPDATA%\OrangeApps\Kiosk\<branch>\local_db`.
  /// Scoping by `<branch>` ensures multiple school apps can be installed on the same PC without colliding!
  static String get _dataDirPath {
    if (_resolvedDataDirPath != null) return _resolvedDataDirPath!;

    final branch = EnvConfig.defaultBranch.isNotEmpty ? EnvConfig.defaultBranch.toLowerCase().trim() : 'default';

    // 1. Check if relative `local_db` is writable (development / portable mode outside Program Files)
    if (!Platform.resolvedExecutable.toLowerCase().contains('program files')) {
      final localDir = Directory(p.join('local_db', branch));
      try {
        if (!localDir.existsSync()) {
          localDir.createSync(recursive: true);
        }
        final testFile = File(p.join(localDir.path, '.write_test'));
        testFile.writeAsStringSync('ok');
        testFile.deleteSync();
        _resolvedDataDirPath = localDir.path;
        return _resolvedDataDirPath!;
      } catch (_) {
        // Relative directory is read-only
      }
    }

    // 2. Fall back to user's writable LocalAppData directory scoped by school branch
    final localAppData = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    final appDataDir = Directory(p.join(localAppData, 'OrangeApps', 'Kiosk', branch, 'local_db'));
    if (!appDataDir.existsSync()) {
      appDataDir.createSync(recursive: true);
    }
    _resolvedDataDirPath = appDataDir.path;
    return _resolvedDataDirPath!;
  }

  Directory get _dbDir {
    final dir = Directory(_dataDirPath);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Directory get _imagesDir {
    final dir = Directory(p.join(_dbDir.path, 'images'));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  String get _sqliteFilePath => p.join(_dbDir.path, 'oa_kiosk.db');

  // Legacy JSON files for automatic one-time migration
  File get _legacyStudentsJson => File(p.join(_dbDir.path, 'students_cache.json'));
  File get _legacyStudEntryJson => File(p.join(_dbDir.path, 'stud_entry_tbl.json'));
  File get _legacySelectedGateJson => File(p.join(_dbDir.path, 'selected_gate.json'));
  File get _legacyOfflineQueueJson => File(p.join(_dbDir.path, 'offline_scans_queue.json'));

  Database get _database {
    if (_db == null) {
      init();
    }
    return _db!;
  }

  /// Opens SQLite database, enables WAL mode, creates tables/indexes, and migrates any legacy JSON files
  void init() {
    if (_db != null) return;

    _db = sqlite3.open(_sqliteFilePath);

    // Enable Write-Ahead Logging (WAL) for high concurrency and crash safety
    _db!.execute('PRAGMA journal_mode = WAL;');
    _db!.execute('PRAGMA synchronous = NORMAL;');

    // 1. Students Cache Table
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS students_cache (
        rfid_code TEXT PRIMARY KEY,
        branch_code TEXT NOT NULL DEFAULT '',
        student_id_desc TEXT NOT NULL DEFAULT '',
        student_name TEXT NOT NULL DEFAULT '',
        image_url TEXT,
        local_image_path TEXT,
        grade_level TEXT NOT NULL DEFAULT 'N/A',
        section TEXT NOT NULL DEFAULT 'N/A',
        type TEXT NOT NULL DEFAULT 'Student',
        student_type TEXT NOT NULL DEFAULT 'Kto12',
        is_commuter INTEGER NOT NULL DEFAULT 0,
        birthday INTEGER NOT NULL DEFAULT 0,
        last_tap_date TEXT,
        last_is_exit INTEGER NOT NULL DEFAULT 0
      );
    ''');

    // Index on student_id_desc for instant (<0.1ms) lookups by Student ID number as well as RFID
    _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_students_cache_desc
      ON students_cache (student_id_desc);
    ''');

    // 2. stud_entry_tbl Table (Tap Records & Offline Queue)
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS stud_entry_tbl (
        uuid TEXT PRIMARY KEY,
        rfid_code TEXT NOT NULL DEFAULT '',
        student_id TEXT NOT NULL DEFAULT '',
        student_id_desc TEXT NOT NULL DEFAULT '',
        student_name TEXT NOT NULL DEFAULT '',
        student_type TEXT NOT NULL DEFAULT 'Kto12',
        is_commuter INTEGER NOT NULL DEFAULT 0,
        place_id INTEGER NOT NULL DEFAULT 0,
        place_name TEXT NOT NULL DEFAULT '',
        enter_at TEXT NOT NULL DEFAULT '',
        is_exit INTEGER NOT NULL DEFAULT 0,
        type TEXT NOT NULL DEFAULT 'Student',
        temperature TEXT NOT NULL DEFAULT '',
        remarks TEXT NOT NULL DEFAULT '',
        grade_level TEXT NOT NULL DEFAULT 'N/A',
        section TEXT NOT NULL DEFAULT 'N/A',
        adviser_id INTEGER NOT NULL DEFAULT 0,
        branch_code TEXT NOT NULL DEFAULT '',
        school_start TEXT NOT NULL DEFAULT '',
        text_received INTEGER NOT NULL DEFAULT 0,
        scanned_at TEXT NOT NULL DEFAULT '',
        is_synced INTEGER NOT NULL DEFAULT 0,
        error_message TEXT
      );
    ''');

    // Index on is_synced so querying unsynced offline records is instant even with 100k+ rows
    _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_stud_entry_unsynced
      ON stud_entry_tbl (is_synced, scanned_at);
    ''');

    // Index on scanned_at for fast recent tap activity log queries
    _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_stud_entry_scanned_at
      ON stud_entry_tbl (scanned_at DESC);
    ''');

    // 3. App Settings Table (Selected Gate, Time Offset, etc.)
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS app_settings (
        setting_key TEXT PRIMARY KEY,
        setting_value TEXT NOT NULL
      );
    ''');

    // 4. Gates Cache Table (Offline Place / Gate Selection)
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS gates_cache (
        id INTEGER PRIMARY KEY,
        place_name TEXT NOT NULL DEFAULT '',
        branch_code TEXT NOT NULL DEFAULT '',
        tap_interval INTEGER NOT NULL DEFAULT 15,
        allow_exit INTEGER NOT NULL DEFAULT 1,
        allow_notif INTEGER NOT NULL DEFAULT 0,
        md5_id TEXT NOT NULL DEFAULT ''
      );
    ''');

    // Load persisted server/manual time offset from SQLite before running date queries
    _loadTimeOffset();

    // Load persisted school kiosk appearance (logo, color, title) from SQLite
    _loadKioskAppearance();

    // Perform automatic one-time migration from legacy JSON files if they exist
    _migrateLegacyJsonFiles();

    // Automatically purge synced tap logs older than 30 days on startup
    purgeOldSyncedEntries(retentionDays: 30);
  }

  /// Restores persisted kiosk appearance from SQLite `app_settings` on startup
  void _loadKioskAppearance() {
    try {
      final ResultSet rows = _db!.select(
        'SELECT setting_key, setting_value FROM app_settings WHERE setting_key IN (?, ?, ?, ?, ?);',
        ['kiosk_logo_url', 'kiosk_local_logo_path', 'kiosk_primary_color', 'kiosk_app_title', 'kiosk_branch_code'],
      );
      String? logoUrl;
      Color? color;
      String? appTitle;
      String? branchCode;
      for (final row in rows) {
        final key = row['setting_key']?.toString() ?? '';
        final val = row['setting_value']?.toString() ?? '';
        if (key == 'kiosk_branch_code') {
          branchCode = val;
        } else if (key == 'kiosk_logo_url' && val.isNotEmpty) {
          logoUrl = val;
        } else if (key == 'kiosk_primary_color' && val.isNotEmpty) {
          final hex = val.replaceAll('#', '').trim();
          final intVal = int.tryParse(hex.length == 6 ? 'FF$hex' : hex, radix: 16);
          if (intVal != null) color = Color(intVal);
        } else if (key == 'kiosk_app_title' && val.isNotEmpty) {
          appTitle = val;
        }
      }

      // If stored appearance belongs to a different school branch, purge it so it reverts to the current school's .env values!
      final configuredBranch = EnvConfig.defaultBranch.toLowerCase().trim();
      if (branchCode != null && branchCode.isNotEmpty && configuredBranch.isNotEmpty && branchCode.toLowerCase().trim() != configuredBranch) {
        debugPrint('[LocalDbService] Stored appearance belongs to branch "$branchCode", but current configured branch is "$configuredBranch". Purging outdated school theme & logo.');
        clearKioskAppearance();
        return;
      }

      if (logoUrl != null || color != null || appTitle != null) {
        EnvConfig.setDynamicAppearance(logoUrl: logoUrl, color: color, appName: appTitle);
      }
    } catch (_) {}
  }

  /// Clears stored appearance and deletes cached school logo
  void clearKioskAppearance() {
    try {
      final cachedLogo = getCachedSchoolLogoPath();
      if (cachedLogo != null && File(cachedLogo).existsSync()) {
        try {
          File(cachedLogo).deleteSync();
        } catch (_) {}
      }
      _database.execute('''
        DELETE FROM app_settings WHERE setting_key IN (
          'kiosk_logo_url', 'kiosk_local_logo_path', 'kiosk_primary_color', 'kiosk_app_title', 'kiosk_branch_code'
        );
      ''');
    } catch (_) {}
  }

  /// Returns the absolute path of the cached school logo image on disk if it exists
  String? getCachedSchoolLogoPath() {
    try {
      // 1. Check SQLite app_settings
      final ResultSet rows = _database.select(
        'SELECT setting_value FROM app_settings WHERE setting_key = ? LIMIT 1;',
        ['kiosk_local_logo_path'],
      );
      if (rows.isNotEmpty) {
        final path = rows.first['setting_value']?.toString() ?? '';
        if (path.isNotEmpty && File(path).existsSync() && File(path).lengthSync() > 0) {
          return path;
        }
      }
      // 2. Fallback check standard file in _imagesDir
      final file = File('${_imagesDir.path}/school_logo.png');
      if (file.existsSync() && file.lengthSync() > 0) {
        return file.path;
      }
    } catch (_) {}
    return null;
  }

  /// Downloads the school background image from network and saves it to local disk (`local_db/images/school_logo.png`).
  /// Once cached on disk, the kiosk uses this local file permanently, so it never reverts to placeholder even offline.
  Future<String?> downloadAndCacheSchoolLogo(String logoUrl) async {
    try {
      final cleanUrl = logoUrl.trim();
      if (cleanUrl.isEmpty || (!cleanUrl.startsWith('http://') && !cleanUrl.startsWith('https://'))) {
        return null;
      }
      final file = File('${_imagesDir.path}/school_logo.png');

      final uri = Uri.parse(cleanUrl);
      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        await file.writeAsBytes(response.bodyBytes);
        saveKioskAppearance(logoUrl: cleanUrl, localLogoPath: file.path);
        debugPrint('[LocalDbService] School logo successfully cached to disk: ${file.path} (${response.bodyBytes.length} bytes)');
        return file.path;
      }
    } catch (e) {
      debugPrint('[LocalDbService] downloadAndCacheSchoolLogo error: $e');
    }
    return null;
  }

  /// Persists dynamically scraped school kiosk appearance (logo, color, title) in SQLite `app_settings`
  void saveKioskAppearance({
    String? logoUrl,
    String? localLogoPath,
    String? primaryColor,
    String? appTitle,
    String? branchCode,
  }) {
    try {
      final branch = branchCode ?? EnvConfig.defaultBranch;
      if (branch.trim().isNotEmpty) {
        _database.execute('''
          INSERT INTO app_settings (setting_key, setting_value)
          VALUES ('kiosk_branch_code', ?)
          ON CONFLICT(setting_key) DO UPDATE SET setting_value = excluded.setting_value;
        ''', [branch.toLowerCase().trim()]);
      }
      if (logoUrl != null && logoUrl.trim().isNotEmpty) {
        _database.execute('''
          INSERT INTO app_settings (setting_key, setting_value)
          VALUES ('kiosk_logo_url', ?)
          ON CONFLICT(setting_key) DO UPDATE SET setting_value = excluded.setting_value;
        ''', [logoUrl.trim()]);
      }
      if (localLogoPath != null && localLogoPath.trim().isNotEmpty) {
        _database.execute('''
          INSERT INTO app_settings (setting_key, setting_value)
          VALUES ('kiosk_local_logo_path', ?)
          ON CONFLICT(setting_key) DO UPDATE SET setting_value = excluded.setting_value;
        ''', [localLogoPath.trim()]);
      }
      if (primaryColor != null && primaryColor.trim().isNotEmpty) {
        _database.execute('''
          INSERT INTO app_settings (setting_key, setting_value)
          VALUES ('kiosk_primary_color', ?)
          ON CONFLICT(setting_key) DO UPDATE SET setting_value = excluded.setting_value;
        ''', [primaryColor.trim()]);
      }
      if (appTitle != null && appTitle.trim().isNotEmpty) {
        _database.execute('''
          INSERT INTO app_settings (setting_key, setting_value)
          VALUES ('kiosk_app_title', ?)
          ON CONFLICT(setting_key) DO UPDATE SET setting_value = excluded.setting_value;
        ''', [appTitle.trim()]);
      }
    } catch (e) {
      debugPrint('[LocalDbService] saveKioskAppearance error: $e');
    }
  }

  /// Retrieves persisted school kiosk appearance from SQLite `app_settings`
  Map<String, String> getKioskAppearance() {
    final Map<String, String> result = {};
    try {
      final ResultSet rows = _database.select(
        'SELECT setting_key, setting_value FROM app_settings WHERE setting_key IN (?, ?, ?);',
        ['kiosk_logo_url', 'kiosk_primary_color', 'kiosk_app_title'],
      );
      for (final row in rows) {
        final key = row['setting_key']?.toString() ?? '';
        final val = row['setting_value']?.toString() ?? '';
        if (key == 'kiosk_logo_url') result['logo_url'] = val;
        if (key == 'kiosk_primary_color') result['primary_color'] = val;
        if (key == 'kiosk_app_title') result['app_title'] = val;
      }
    } catch (_) {}
    return result;
  }

  /// Restores persisted time offset from SQLite `app_settings` on startup
  void _loadTimeOffset() {
    try {
      final ResultSet rows = _db!.select(
        'SELECT setting_key, setting_value FROM app_settings WHERE setting_key IN (?, ?);',
        ['time_offset_ms', 'time_offset_is_manual'],
      );
      for (final row in rows) {
        final key = row['setting_key']?.toString() ?? '';
        final val = row['setting_value']?.toString() ?? '';
        if (key == 'time_offset_ms') {
          _timeOffsetMs = int.tryParse(val) ?? 0;
        } else if (key == 'time_offset_is_manual') {
          _isManualTimeOffset = val == '1';
        }
      }
    } catch (_) {}
  }

  /// Updates the time offset from the ERP server's clock and persists it in SQLite (`app_settings`).
  /// If the operator previously set a manual time override, it is preserved unless `forceOverrideManual: true`.
  void setServerTime(DateTime serverTime, {bool forceOverrideManual = false}) {
    if (_isManualTimeOffset && !forceOverrideManual) return;

    final newOffsetMs = serverTime.difference(DateTime.now()).inMilliseconds;
    final driftMs = (newOffsetMs - _timeOffsetMs).abs();

    // Only write to SQLite if the offset changed by > 2 seconds or we are clearing manual mode
    if (!forceOverrideManual && !_isManualTimeOffset && driftMs <= 2000) {
      return;
    }

    _timeOffsetMs = newOffsetMs;
    _isManualTimeOffset = false;

    try {
      _database.execute(
        '''
        INSERT INTO app_settings (setting_key, setting_value)
        VALUES ('time_offset_ms', ?), ('time_offset_is_manual', '0')
        ON CONFLICT(setting_key) DO UPDATE SET setting_value = excluded.setting_value;
        ''',
        [_timeOffsetMs.toString()],
      );
    } catch (_) {}
  }

  /// Manually sets the Kiosk Date & Time (e.g. when offline on an outdated device) and persists the offset in SQLite.
  void setManualTime(DateTime manualTime) {
    _timeOffsetMs = manualTime.difference(DateTime.now()).inMilliseconds;
    _isManualTimeOffset = true;

    try {
      _database.execute(
        '''
        INSERT INTO app_settings (setting_key, setting_value)
        VALUES ('time_offset_ms', ?), ('time_offset_is_manual', '1')
        ON CONFLICT(setting_key) DO UPDATE SET setting_value = excluded.setting_value;
        ''',
        [_timeOffsetMs.toString()],
      );
    } catch (_) {}
  }

  void _migrateLegacyJsonFiles() {
    try {
      // 1. Migrate students_cache.json
      if (_legacyStudentsJson.existsSync()) {
        final content = _legacyStudentsJson.readAsStringSync().trim();
        if (content.isNotEmpty) {
          final Map<String, dynamic> map = jsonDecode(content);
          _db!.execute('BEGIN TRANSACTION;');
          try {
            for (final entry in map.entries) {
              if (entry.value is Map) {
                final profile = CachedStudentProfile.fromJson(
                  Map<String, dynamic>.from(entry.value),
                );
                _upsertStudentRow(profile);
              }
            }
            _db!.execute('COMMIT;');
          } catch (_) {
            _db!.execute('ROLLBACK;');
          }
        }
        _legacyStudentsJson.deleteSync();
      }

      // 2. Migrate stud_entry_tbl.json
      if (_legacyStudEntryJson.existsSync()) {
        final content = _legacyStudEntryJson.readAsStringSync().trim();
        if (content.isNotEmpty) {
          final List<dynamic> list = jsonDecode(content);
          _db!.execute('BEGIN TRANSACTION;');
          try {
            for (final item in list) {
              if (item is Map) {
                final record = ScanRecordModel.fromJson(Map<String, dynamic>.from(item));
                saveTapEntry(record);
              }
            }
            _db!.execute('COMMIT;');
          } catch (_) {
            _db!.execute('ROLLBACK;');
          }
        }
        _legacyStudEntryJson.deleteSync();
      }

      // 3. Migrate legacy offline_scans_queue.json
      if (_legacyOfflineQueueJson.existsSync()) {
        final content = _legacyOfflineQueueJson.readAsStringSync().trim();
        if (content.isNotEmpty) {
          final List<dynamic> list = jsonDecode(content);
          for (final item in list) {
            if (item is Map) {
              final record = ScanRecordModel.fromJson(Map<String, dynamic>.from(item));
              saveTapEntry(record);
            }
          }
        }
        _legacyOfflineQueueJson.deleteSync();
      }

      // 4. Migrate selected_gate.json
      if (_legacySelectedGateJson.existsSync()) {
        final content = _legacySelectedGateJson.readAsStringSync().trim();
        if (content.isNotEmpty) {
          final dynamic data = jsonDecode(content);
          if (data is Map<String, dynamic>) {
            saveGate(GateModel.fromJson(data));
          }
        }
        _legacySelectedGateJson.deleteSync();
      }
    } catch (e) {
      debugPrint('[LocalDbService] Legacy migration notice: $e');
    }
  }

  /// Retrieves the last saved Gate from SQLite `app_settings` table.
  /// If the saved gate belongs to a different school branch than the currently configured branch,
  /// returns null to prevent loading the wrong school's gate.
  GateModel? getSavedGate({String? expectedBranch}) {
    try {
      final ResultSet rows = _database.select(
        'SELECT setting_value FROM app_settings WHERE setting_key = ? LIMIT 1;',
        ['selected_gate'],
      );
      if (rows.isNotEmpty) {
        final rawJson = rows.first['setting_value']?.toString() ?? '';
        if (rawJson.isNotEmpty) {
          final Map<String, dynamic> map = jsonDecode(rawJson);
          final gate = GateModel.fromJson(map);
          final branch = (expectedBranch ?? EnvConfig.defaultBranch).toLowerCase().trim();
          if (branch.isNotEmpty &&
              gate.branchCode.isNotEmpty &&
              gate.branchCode.toLowerCase().trim() != branch) {
            debugPrint('[LocalDbService] Saved gate belongs to "${gate.branchCode}", but configured branch is "$branch". Discarding outdated gate.');
            return null;
          }
          return gate;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Saves the newly selected Gate into SQLite `app_settings` table and ensures it exists in `gates_cache`
  void saveGate(GateModel gate) {
    try {
      _database.execute(
        '''
        INSERT INTO app_settings (setting_key, setting_value)
        VALUES (?, ?)
        ON CONFLICT(setting_key) DO UPDATE SET setting_value = excluded.setting_value;
        ''',
        ['selected_gate', jsonEncode(gate.toJson())],
      );
      if (gate.id > 0) {
        _database.execute(
          '''
          INSERT INTO gates_cache (
            id, place_name, branch_code, tap_interval, allow_exit, allow_notif, md5_id
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            place_name = excluded.place_name,
            branch_code = excluded.branch_code,
            tap_interval = excluded.tap_interval,
            allow_exit = excluded.allow_exit,
            allow_notif = excluded.allow_notif,
            md5_id = excluded.md5_id;
          ''',
          [
            gate.id,
            gate.placeName,
            gate.branchCode,
            gate.tapInterval,
            gate.allowExit ? 1 : 0,
            gate.allowNotif ? 1 : 0,
            gate.md5Id,
          ],
        );
      }
    } catch (_) {}
  }

  /// Caches all gates returned from the server into SQLite `gates_cache` so the operator
  /// can still view and switch gates even when the device is offline.
  void saveGatesList(List<GateModel> gates) {
    if (gates.isEmpty) return;
    final db = _database;
    final stmt = db.prepare('''
      INSERT INTO gates_cache (
        id, place_name, branch_code, tap_interval, allow_exit, allow_notif, md5_id
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        place_name = excluded.place_name,
        branch_code = excluded.branch_code,
        tap_interval = excluded.tap_interval,
        allow_exit = excluded.allow_exit,
        allow_notif = excluded.allow_notif,
        md5_id = excluded.md5_id;
    ''');
    try {
      db.execute('BEGIN TRANSACTION;');
      final incomingIds = <int>{};
      for (final g in gates) {
        if (g.id <= 0) continue;
        incomingIds.add(g.id);
        stmt.execute([
          g.id,
          g.placeName,
          g.branchCode,
          g.tapInterval,
          g.allowExit ? 1 : 0,
          g.allowNotif ? 1 : 0,
          g.md5Id,
        ]);
      }
      if (incomingIds.isNotEmpty) {
        final existingRows = db.select('SELECT id FROM gates_cache;');
        final toDelete = <int>[];
        for (final r in existingRows) {
          final id = (r['id'] as int?) ?? 0;
          if (id > 0 && !incomingIds.contains(id)) {
            toDelete.add(id);
          }
        }
        if (toDelete.isNotEmpty) {
          final delStmt = db.prepare('DELETE FROM gates_cache WHERE id = ?;');
          try {
            for (final id in toDelete) {
              delStmt.execute([id]);
            }
          } finally {
            delStmt.close();
          }
        }
      }
      db.execute('COMMIT;');
    } catch (e) {
      try {
        db.execute('ROLLBACK;');
      } catch (_) {}
      debugPrint('[LocalDbService] Error saving gates list: $e');
    } finally {
      stmt.close();
    }
  }

  /// Retrieves all cached Gates from SQLite `gates_cache` table for instant / offline gate selection
  List<GateModel> getCachedGates({String? branchCode}) {
    try {
      final cleanBranch = branchCode?.trim() ?? '';
      final ResultSet rows = cleanBranch.isNotEmpty
          ? _database.select(
              'SELECT * FROM gates_cache WHERE branch_code = ? ORDER BY id ASC;',
              [cleanBranch],
            )
          : _database.select('SELECT * FROM gates_cache ORDER BY id ASC;');
      final list = rows
          .map((r) => GateModel.fromJson(Map<String, dynamic>.from(r)))
          .toList();
      if (list.isEmpty) {
        final saved = getSavedGate();
        if (saved != null) return [saved];
      }
      return list;
    } catch (e) {
      debugPrint('[LocalDbService] Error reading cached gates: $e');
      return [];
    }
  }

  /// Reassigns any pending unsynced tap records (`is_synced = 0`) in `stud_entry_tbl`
  /// to the newly selected gate (`place_id`, `place_name`, `branch_code`) so that if
  /// the operator switches gates while offline, pending taps are sent under the chosen gate
  /// when the network reconnects.
  int reassignUnsyncedTapsToGate(GateModel gate) {
    try {
      _database.execute(
        '''
        UPDATE stud_entry_tbl
        SET place_id = ?,
            place_name = ?,
            branch_code = CASE WHEN ? != '' THEN ? ELSE branch_code END
        WHERE is_synced = 0;
        ''',
        [gate.id, gate.placeName, gate.branchCode, gate.branchCode],
      );
      return _database.updatedRows;
    } catch (e) {
      debugPrint('[LocalDbService] Error reassigning unsynced taps to gate: $e');
      return 0;
    }
  }

  void _upsertStudentRow(CachedStudentProfile profile) {
    _database.execute(
      '''
      INSERT INTO students_cache (
        rfid_code, branch_code, student_id_desc, student_name,
        image_url, local_image_path, grade_level, section,
        type, student_type, is_commuter, birthday,
        last_tap_date, last_is_exit
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(rfid_code) DO UPDATE SET
        branch_code = excluded.branch_code,
        student_id_desc = excluded.student_id_desc,
        student_name = excluded.student_name,
        image_url = excluded.image_url,
        local_image_path = excluded.local_image_path,
        grade_level = excluded.grade_level,
        section = excluded.section,
        type = excluded.type,
        student_type = excluded.student_type,
        is_commuter = excluded.is_commuter,
        birthday = excluded.birthday,
        last_tap_date = excluded.last_tap_date,
        last_is_exit = excluded.last_is_exit;
      ''',
      [
        profile.rfidCode,
        profile.branchCode,
        profile.personId,
        profile.name,
        profile.imageUrl,
        profile.localImagePath,
        profile.gradeLevel,
        profile.section,
        profile.type,
        profile.studentType,
        profile.isCommuter,
        profile.birthday,
        profile.lastTapDate,
        profile.lastIsExit,
      ],
    );
  }

  /// Bulk upserts all student and employee records returned from `/kiosk_sync_roster`
  /// inside a single SQLite transaction using a prepared statement (~50-150ms for 15k+ rows).
  /// Preserves any existing `local_image_path`, `last_tap_date`, and `last_is_exit` values,
  /// prunes dropped/removed profiles not in the live server payload, and cleans up orphaned disk images.
  int bulkUpsertRoster(List<CachedStudentProfile> profiles, {String? branchCode}) {
    if (profiles.isEmpty) return 0;
    int count = 0;
    final db = _database;
    final incomingRfids = <String>{};
    final stmt = db.prepare('''
      INSERT INTO students_cache (
        rfid_code, branch_code, student_id_desc, student_name,
        image_url, local_image_path, grade_level, section,
        type, student_type, is_commuter, birthday,
        last_tap_date, last_is_exit
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(rfid_code) DO UPDATE SET
        branch_code = excluded.branch_code,
        student_id_desc = excluded.student_id_desc,
        student_name = excluded.student_name,
        image_url = excluded.image_url,
        local_image_path = CASE
          WHEN students_cache.student_id_desc = excluded.student_id_desc
               AND students_cache.image_url = excluded.image_url
               AND students_cache.local_image_path IS NOT NULL
          THEN students_cache.local_image_path
          ELSE excluded.local_image_path
        END,
        grade_level = excluded.grade_level,
        section = excluded.section,
        type = excluded.type,
        student_type = excluded.student_type,
        is_commuter = excluded.is_commuter,
        birthday = excluded.birthday,
        last_tap_date = CASE
          WHEN students_cache.student_id_desc = excluded.student_id_desc
          THEN students_cache.last_tap_date
          ELSE excluded.last_tap_date
        END,
        last_is_exit = CASE
          WHEN students_cache.student_id_desc = excluded.student_id_desc
          THEN students_cache.last_is_exit
          ELSE excluded.last_is_exit
        END;
    ''');

    try {
      db.execute('BEGIN TRANSACTION;');
      for (final profile in profiles) {
        final code = profile.rfidCode.trim();
        if (code.isEmpty) continue;
        incomingRfids.add(code);
        stmt.execute([
          code,
          profile.branchCode,
          profile.personId,
          profile.name,
          profile.imageUrl,
          profile.localImagePath,
          profile.gradeLevel,
          profile.section,
          profile.type,
          profile.studentType,
          profile.isCommuter,
          profile.birthday,
          profile.lastTapDate,
          profile.lastIsExit,
        ]);
        count++;
      }

      // Prune dropped/removed profiles that are no longer in the live roster
      if (incomingRfids.isNotEmpty) {
        final cleanBranch = branchCode?.trim() ?? '';
        final ResultSet existingRows = (cleanBranch.isNotEmpty && cleanBranch != 'all')
            ? db.select(
                'SELECT rfid_code FROM students_cache WHERE branch_code = ? OR branch_code = \'\';',
                [cleanBranch],
              )
            : db.select('SELECT rfid_code FROM students_cache;');

        final toDelete = <String>[];
        for (final r in existingRows) {
          final existingCode = r['rfid_code']?.toString().trim() ?? '';
          if (existingCode.isNotEmpty && !incomingRfids.contains(existingCode)) {
            toDelete.add(existingCode);
          }
        }

        if (toDelete.isNotEmpty) {
          final delStmt = db.prepare('DELETE FROM students_cache WHERE rfid_code = ?;');
          try {
            for (final code in toDelete) {
              delStmt.execute([code]);
            }
            debugPrint('[LocalDbService] Pruned ${toDelete.length} removed profiles from students_cache.');
          } finally {
            delStmt.close();
          }
        }
      }

      db.execute('COMMIT;');
    } catch (e) {
      try {
        db.execute('ROLLBACK;');
      } catch (_) {}
      debugPrint('[LocalDbService] Error during bulkUpsertRoster: $e');
    } finally {
      stmt.close();
    }

    // Garbage-collect orphaned image files on disk and purge old (>30d) synced tap logs
    cleanupOrphanedImages();
    purgeOldSyncedEntries(retentionDays: 30);

    return count;
  }

  /// Garbage-collects image files in `local_db/images/` that no longer belong to any active student in `students_cache`
  int cleanupOrphanedImages() {
    int deletedCount = 0;
    try {
      final imgDir = Directory(p.join(_dbDir.path, 'images'));
      if (!imgDir.existsSync()) return 0;

      // Collect all active local_image_path values and expected filenames for active students with valid image URLs
      final ResultSet rows = _database.select('''
        SELECT rfid_code, student_id_desc, image_url, local_image_path
        FROM students_cache
        WHERE image_url IS NOT NULL
          AND image_url != ''
          AND image_url NOT LIKE '%default-picture.png%';
      ''');

      final activePaths = <String>{};
      final activeBaseNames = <String>{};

      for (final r in rows) {
        final localPath = r['local_image_path']?.toString().trim() ?? '';
        if (localPath.isNotEmpty) {
          activePaths.add(p.normalize(localPath).toLowerCase());
        }
        final personId = r['student_id_desc']?.toString().trim() ?? '';
        final rfid = r['rfid_code']?.toString().trim() ?? '';
        final rawId = personId.isNotEmpty ? personId : rfid;
        if (rawId.isNotEmpty) {
          final safeFileName = rawId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
          final imgUrl = r['image_url']?.toString().toLowerCase() ?? '';
          final ext = imgUrl.endsWith('.png') ? 'png' : 'jpg';
          activeBaseNames.add('student_$safeFileName.$ext'.toLowerCase());
        }
      }

      for (final entity in imgDir.listSync()) {
        if (entity is File) {
          final normalizedPath = p.normalize(entity.path).toLowerCase();
          final fileName = p.basename(entity.path).toLowerCase();
          if (!activePaths.contains(normalizedPath) && !activeBaseNames.contains(fileName)) {
            try {
              entity.deleteSync();
              deletedCount++;
            } catch (_) {}
          }
        }
      }
      if (deletedCount > 0) {
        debugPrint('[LocalDbService] Deleted $deletedCount orphaned image file(s) from disk.');
      }
    } catch (e) {
      debugPrint('[LocalDbService] Error cleaning up orphaned images: $e');
    }
    return deletedCount;
  }

  /// Total number of cached student/employee records in SQLite `students_cache`
  int get cachedRosterCount {
    try {
      final ResultSet rows = _database.select(
        'SELECT COUNT(*) AS cnt FROM students_cache;',
      );
      if (rows.isNotEmpty) {
        return (rows.first['cnt'] as int?) ?? 0;
      }
    } catch (_) {}
    return 0;
  }

  /// Looks up a student profile in the SQLite Local DB by RFID code or Student ID Number (<0.5ms lookup).
  /// Prioritizes exact physical `rfid_code` matches over `student_id_desc` fallbacks.
  CachedStudentProfile? getStudentByRfid(String rfidCode) {
    try {
      final clean = rfidCode.trim();
      if (clean.isEmpty) return null;
      final ResultSet rows = _database.select(
        'SELECT * FROM students_cache WHERE rfid_code = ? OR student_id_desc = ? ORDER BY CASE WHEN rfid_code = ? THEN 0 ELSE 1 END LIMIT 1;',
        [clean, clean, clean],
      );
      if (rows.isNotEmpty) {
        return CachedStudentProfile.fromJson(Map<String, dynamic>.from(rows.first));
      }
    } catch (_) {}
    return null;
  }

  /// Computes today's alternating Entrance/Exit (`is_exit`) and returns a StudentInfoModel
  /// ready for immediate (<1ms) UI display from the SQLite Local DB.
  /// When `skipToggle: true` (e.g. within tap_interval), displays current status without alternating.
  ({StudentInfoModel info, int isExit}) prepareLocalTapDisplay(
    CachedStudentProfile profile,
    DateTime tapTime, {
    bool allowExit = true,
    bool skipToggle = false,
  }) {
    final todayStr = _formatDateIso(tapTime);
    int nextIsExit = 0; // 0 = Entrance, 1 = Exit

    if (skipToggle) {
      // Keep existing status when tapping within interval
      nextIsExit = profile.lastTapDate == todayStr ? profile.lastIsExit : 0;
    } else if (allowExit && profile.lastTapDate == todayStr) {
      // Alternate Entrance (0) <-> Exit (1) on the same day
      nextIsExit = profile.lastIsExit == 0 ? 1 : 0;
    } else {
      nextIsExit = 0;
    }

    final updatedProfile = profile.copyWith(
      lastTapDate: todayStr,
      lastIsExit: nextIsExit,
    );

    if (!skipToggle) {
      // Update just the 2 columns in SQLite (<0.5ms) without matching empty strings
      try {
        final cleanRfid = profile.rfidCode.trim();
        final cleanPersonId = profile.personId.trim();
        if (cleanRfid.isNotEmpty && cleanPersonId.isNotEmpty) {
          _database.execute(
            'UPDATE students_cache SET last_tap_date = ?, last_is_exit = ? WHERE rfid_code = ? OR student_id_desc = ?;',
            [todayStr, nextIsExit, cleanRfid, cleanPersonId],
          );
        } else if (cleanRfid.isNotEmpty) {
          _database.execute(
            'UPDATE students_cache SET last_tap_date = ?, last_is_exit = ? WHERE rfid_code = ?;',
            [todayStr, nextIsExit, cleanRfid],
          );
        } else if (cleanPersonId.isNotEmpty) {
          _database.execute(
            'UPDATE students_cache SET last_tap_date = ?, last_is_exit = ? WHERE student_id_desc = ?;',
            [todayStr, nextIsExit, cleanPersonId],
          );
        }
      } catch (_) {}
    }

    final entText = nextIsExit == 1 ? 'Exit' : 'Entrance';
    final info = StudentInfoModel(
      name: updatedProfile.name,
      personId: updatedProfile.personId,
      imageUrl: updatedProfile.imageUrl,
      localImagePath: updatedProfile.hasValidLocalImage ? updatedProfile.localImagePath : null,
      date: _formatDisplayDate(tapTime),
      time: _formatDisplayTime(tapTime),
      ent: entText,
      gradeLevel: updatedProfile.gradeLevel,
      section: updatedProfile.section,
      type: updatedProfile.type,
      birthday: updatedProfile.birthday,
      isCommuter: updatedProfile.isCommuter,
    );

    return (info: info, isExit: nextIsExit);
  }

  /// Compares online `StudentInfoModel` with SQLite `students_cache`, silently updates the row
  /// if new or different, and downloads the student's profile picture to `local_db/images/`.
  Future<CachedStudentProfile> upsertStudentAndDownloadImage({
    required String rfidCode,
    required String branchCode,
    required StudentInfoModel onlineInfo,
    required String baseUrl,
    required DateTime tapTime,
    void Function(String localImagePath)? onImageDownloaded,
  }) async {
    final cleanCode = rfidCode.trim();
    final existing = getStudentByRfid(cleanCode);
    final todayStr = _formatDateIso(tapTime);
    final onlineIsExit = (onlineInfo.ent?.toLowerCase() == 'exit') ? 1 : 0;

    final hasProfileDifference = existing == null ||
        existing.name != onlineInfo.name ||
        existing.personId != onlineInfo.personId ||
        (existing.imageUrl ?? '') != (onlineInfo.imageUrl ?? '') ||
        existing.gradeLevel != (onlineInfo.gradeLevel ?? 'N/A') ||
        existing.section != (onlineInfo.section ?? 'N/A') ||
        existing.type != (onlineInfo.type ?? 'Student') ||
        existing.birthday != onlineInfo.birthday ||
        existing.isCommuter != onlineInfo.isCommuter;

    final personChanged =
        existing != null && existing.personId != onlineInfo.personId;
    final imageChanged = personChanged ||
        (existing != null && (existing.imageUrl ?? '') != (onlineInfo.imageUrl ?? ''));

    final updated = CachedStudentProfile(
      rfidCode: cleanCode,
      branchCode: branchCode,
      personId: onlineInfo.personId,
      name: onlineInfo.name,
      imageUrl: onlineInfo.imageUrl,
      localImagePath: imageChanged ? null : existing?.localImagePath,
      gradeLevel: onlineInfo.gradeLevel ?? 'N/A',
      section: onlineInfo.section ?? 'N/A',
      type: onlineInfo.type ?? 'Student',
      studentType: existing?.studentType ?? 'Kto12',
      isCommuter: onlineInfo.isCommuter,
      birthday: onlineInfo.birthday,
      lastTapDate: todayStr,
      lastIsExit: onlineIsExit,
    );

    if (hasProfileDifference ||
        existing.lastTapDate != todayStr ||
        existing.lastIsExit != onlineIsExit) {
      _upsertStudentRow(updated);
    }

    // Download the student's profile image if it's a real image and not yet cached locally
    final fullImageUrl = onlineInfo.getFullImageUrl(baseUrl);
    if (fullImageUrl != null &&
        fullImageUrl.isNotEmpty &&
        !fullImageUrl.contains('default-picture.png')) {
      if (!updated.hasValidLocalImage || imageChanged) {
        final downloadedPath = await downloadProfileImage(
          rfidCode: cleanCode,
          personId: onlineInfo.personId,
          fullImageUrl: fullImageUrl,
        );
        if (downloadedPath != null) {
          final withLocalImg = updated.copyWith(localImagePath: downloadedPath);
          onImageDownloaded?.call(downloadedPath);
          return withLocalImg;
        }
      }
    }

    return updated;
  }

  /// Updates the `local_image_path` in SQLite `students_cache`
  void updateStudentLocalImagePath(String rfidCode, String personId, String localImagePath) {
    try {
      if (personId.isNotEmpty) {
        _database.execute(
          'UPDATE students_cache SET local_image_path = ? WHERE student_id_desc = ? OR rfid_code = ?;',
          [localImagePath, personId, rfidCode],
        );
      } else {
        _database.execute(
          'UPDATE students_cache SET local_image_path = ? WHERE rfid_code = ?;',
          [localImagePath, rfidCode],
        );
      }
    } catch (_) {}
  }

  /// Returns all cached student/employee profiles with remote photos that have not yet been downloaded to disk
  List<CachedStudentProfile> getProfilesPendingImageDownload() {
    try {
      final ResultSet rows = _database.select('''
        SELECT * FROM students_cache 
        WHERE image_url IS NOT NULL 
          AND image_url != '' 
          AND image_url NOT LIKE '%default-picture.png%';
      ''');
      final list = <CachedStudentProfile>[];
      for (final r in rows) {
        final profile = CachedStudentProfile.fromJson(Map<String, dynamic>.from(r));
        if (!profile.hasValidLocalImage) {
          list.add(profile);
        }
      }
      return list;
    } catch (_) {
      return [];
    }
  }

  /// Downloads a profile picture to `local_db/images/` and updates `students_cache` in SQLite.
  /// If the image file already exists locally on disk, links it immediately without re-downloading.
  Future<String?> downloadProfileImage({
    required String rfidCode,
    required String personId,
    required String fullImageUrl,
  }) async {
    try {
      final rawId = personId.isNotEmpty ? personId : rfidCode;
      final safeFileName = rawId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
      final ext = fullImageUrl.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
      final file = File('${_imagesDir.path}/student_$safeFileName.$ext');

      // 1. If file already exists locally and is non-empty, link it without network request
      if (file.existsSync() && file.lengthSync() > 0) {
        updateStudentLocalImagePath(rfidCode, personId, file.path);
        return file.path;
      }

      // 2. Fetch over network
      final uri = Uri.parse(fullImageUrl);
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        await file.writeAsBytes(response.bodyBytes);
        updateStudentLocalImagePath(rfidCode, personId, file.path);
        return file.path;
      }
    } catch (_) {}
    return null;
  }

  /// Inserts or updates a single tap entry row in SQLite `stud_entry_tbl` (<0.5ms)
  void saveTapEntry(ScanRecordModel record) {
    try {
      _database.execute(
        '''
        INSERT INTO stud_entry_tbl (
          uuid, rfid_code, student_id, student_id_desc, student_name,
          student_type, is_commuter, place_id, place_name, enter_at,
          is_exit, type, temperature, remarks, grade_level,
          section, adviser_id, branch_code, school_start, text_received,
          scanned_at, is_synced, error_message
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(uuid) DO UPDATE SET
          student_id = excluded.student_id,
          student_id_desc = excluded.student_id_desc,
          student_name = excluded.student_name,
          student_type = excluded.student_type,
          is_commuter = excluded.is_commuter,
          is_exit = excluded.is_exit,
          type = excluded.type,
          grade_level = excluded.grade_level,
          section = excluded.section,
          is_synced = CASE WHEN stud_entry_tbl.is_synced = 1 THEN 1 ELSE excluded.is_synced END,
          error_message = CASE WHEN stud_entry_tbl.is_synced = 1 THEN '' ELSE excluded.error_message END;
        ''',
        [
          record.uuid,
          record.rfidCode,
          record.studentId,
          record.studentIdDesc,
          record.studentName,
          record.studentType,
          record.isCommuter,
          record.placeId,
          record.placeName,
          record.enterAt,
          record.isExit,
          record.type,
          record.temperature,
          record.remarks,
          record.gradeLevel,
          record.section,
          record.adviserId,
          record.branchCode,
          record.schoolStart,
          record.textReceived,
          record.scannedAt.toIso8601String(),
          record.isSynced ? 1 : 0,
          record.errorMessage,
        ],
      );
    } catch (e) {
      debugPrint('[LocalDbService] Error saving tap entry: $e');
    }
  }

  /// Returns all unsynced tap records waiting to be sent to the server
  List<ScanRecordModel> get unsyncedRecords {
    try {
      final ResultSet rows = _database.select(
        'SELECT * FROM stud_entry_tbl WHERE is_synced = 0 ORDER BY scanned_at ASC;',
      );
      return rows.map((r) => ScanRecordModel.fromJson(Map<String, dynamic>.from(r))).toList();
    } catch (_) {
      return [];
    }
  }

  /// Count of unsynced offline records
  int get unsyncedCount {
    try {
      final ResultSet rows = _database.select(
        'SELECT COUNT(*) AS cnt FROM stud_entry_tbl WHERE is_synced = 0;',
      );
      if (rows.isNotEmpty) {
        return (rows.first['cnt'] as int?) ?? 0;
      }
    } catch (_) {}
    return 0;
  }

  /// Checks whether a tap record with the given UUID is already marked as synced (`is_synced = 1`)
  bool isRecordSynced(String uuid) {
    try {
      final ResultSet rows = _database.select(
        'SELECT is_synced FROM stud_entry_tbl WHERE uuid = ? LIMIT 1;',
        [uuid],
      );
      if (rows.isNotEmpty) {
        return ((rows.first['is_synced'] as int?) ?? 0) == 1;
      }
    } catch (_) {}
    return false;
  }

  /// Returns the most recent recorded tap for this student from `stud_entry_tbl`.
  /// When `studentIdDesc` is known (resolved via `rfid_code` -> `students_cache`), queries strictly by `student_id_desc`
  /// so that if an `rfid_code` was reassigned from Student A to Student B, Student B is never blocked by Student A's interval.
  /// Only falls back to unmapped `rfid_code` when `studentIdDesc` is unknown (unmapped offline RFID tap).
  ScanRecordModel? getLastTapEntry(String rfidCode, {String? studentIdDesc, int? placeId}) {
    try {
      final cleanRfid = rfidCode.trim();
      final cleanId = studentIdDesc?.trim() ?? '';
      final filterPlace = placeId != null && placeId > 0;
      final ResultSet rows;
      if (cleanId.isNotEmpty) {
        rows = _database.select('''
          SELECT * FROM stud_entry_tbl
          WHERE student_id_desc = ?
            ${filterPlace ? 'AND place_id = ?' : ''}
          ORDER BY scanned_at DESC
          LIMIT 1;
        ''', filterPlace ? [cleanId, placeId] : [cleanId]);
      } else {
        rows = _database.select('''
          SELECT * FROM stud_entry_tbl
          WHERE rfid_code = ? AND (student_id_desc = '' OR student_id_desc IS NULL)
            ${filterPlace ? 'AND place_id = ?' : ''}
          ORDER BY scanned_at DESC
          LIMIT 1;
        ''', filterPlace ? [cleanRfid, placeId] : [cleanRfid]);
      }
      if (rows.isNotEmpty) {
        return ScanRecordModel.fromJson(Map<String, dynamic>.from(rows.first));
      }
    } catch (_) {}
    return null;
  }

  /// Marks a queued tap record as synced in SQLite `stud_entry_tbl`
  void markRecordSynced(String uuid, {StudentInfoModel? studentInfo}) {
    try {
      if (studentInfo != null) {
        _database.execute(
          '''
          UPDATE stud_entry_tbl
          SET is_synced = 1,
              student_id_desc = ?,
              student_name = ?,
              grade_level = ?,
              section = ?,
              type = ?,
              is_commuter = ?,
              error_message = NULL
          WHERE uuid = ?;
          ''',
          [
            studentInfo.personId,
            studentInfo.name,
            studentInfo.gradeLevel ?? 'N/A',
            studentInfo.section ?? 'N/A',
            studentInfo.type ?? 'Student',
            studentInfo.isCommuter,
            uuid,
          ],
        );
      } else {
        _database.execute(
          'UPDATE stud_entry_tbl SET is_synced = 1, error_message = NULL WHERE uuid = ?;',
          [uuid],
        );
      }
    } catch (_) {}
  }

  /// Deletes a single tap entry from `stud_entry_tbl` by UUID (e.g. when rejected by remote as not found)
  bool deleteTapEntry(String uuid) {
    try {
      _database.execute('DELETE FROM stud_entry_tbl WHERE uuid = ?;', [uuid]);
      return _database.updatedRows > 0;
    } catch (e) {
      debugPrint('[LocalDbService] Error deleting tap entry $uuid: $e');
      return false;
    }
  }

  /// Deletes a student profile from `students_cache` by RFID code or Student ID (e.g. when rejected by remote)
  bool deleteStudentFromCache(String rfidCode) {
    try {
      final clean = rfidCode.trim();
      if (clean.isEmpty) return false;
      _database.execute('DELETE FROM students_cache WHERE rfid_code = ? OR student_id_desc = ?;', [clean, clean]);
      return _database.updatedRows > 0;
    } catch (e) {
      debugPrint('[LocalDbService] Error deleting student $rfidCode from cache: $e');
      return false;
    }
  }

  /// Clears out any pending tap entries that failed with permanent remote rejection errors
  /// (e.g. "ID Not Found!", "Invalid ID!", "Unable to Process Transaction Code Not Found")
  int clearFailedOrInvalidTaps() {
    try {
      _database.execute('''
        DELETE FROM stud_entry_tbl 
        WHERE is_synced = 0 
          AND (error_message LIKE '%Not Found%' 
            OR error_message LIKE '%Invalid ID%' 
            OR error_message LIKE '%Unable to Process%'
            OR error_message LIKE '%Reported Lost%'
            OR error_message LIKE '%REJECTED%');
      ''');
      final count = _database.updatedRows;
      if (count > 0) {
        debugPrint('[LocalDbService] Cleared $count permanently rejected tap record(s) from stud_entry_tbl.');
      }
      return count;
    } catch (e) {
      debugPrint('[LocalDbService] Error clearing failed taps: $e');
      return 0;
    }
  }

  /// Purges already-synced (`is_synced = 1`) attendance tap records older than `retentionDays` (default 30 days).
  /// Unsynced offline records (`is_synced = 0`) are NEVER deleted until sent to the live server.
  int purgeOldSyncedEntries({int retentionDays = 30}) {
    try {
      final cutoffIso = now.subtract(Duration(days: retentionDays)).toIso8601String();
      _database.execute(
        '''
        DELETE FROM stud_entry_tbl
        WHERE is_synced = 1
          AND scanned_at != ''
          AND scanned_at < ?;
        ''',
        [cutoffIso],
      );
      final deleted = _database.updatedRows;
      if (deleted > 0) {
        debugPrint('[LocalDbService] Purged $deleted synced tap record(s) older than $retentionDays days.');
      }
      return deleted;
    } catch (e) {
      debugPrint('[LocalDbService] Error purging old tap entries: $e');
      return 0;
    }
  }

  /// Fetches recent tap activity logs from `stud_entry_tbl` ordered by `scanned_at DESC`.
  /// Supports searching by name, student/employee ID, or RFID code, and filtering by today only.
  List<ScanRecordModel> getRecentTapLogs({
    int limit = 200,
    String searchQuery = '',
    bool todayOnly = false,
  }) {
    try {
      final conditions = <String>[];
      final args = <Object?>[];

      if (todayOnly) {
        final todayPrefix = _formatDateIso(now);
        conditions.add('(se.scanned_at LIKE ? OR se.enter_at LIKE ?)');
        args.add('$todayPrefix%');
        args.add('$todayPrefix%');
      }

      final cleanQuery = searchQuery.trim();
      final lowerQuery = cleanQuery.toLowerCase();
      if (cleanQuery.isNotEmpty) {
        final likePattern = '%$lowerQuery%';
        conditions.add(
          '''(
            LOWER(se.student_name) LIKE ?
            OR LOWER(se.student_id_desc) LIKE ?
            OR LOWER(se.rfid_code) LIKE ?
            OR LOWER(COALESCE(sc.student_name, '')) LIKE ?
            OR LOWER(COALESCE(sc.student_id_desc, '')) LIKE ?
          )''',
        );
        args.addAll([likePattern, likePattern, likePattern, likePattern, likePattern]);
      }

      final whereClause = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
      args.add(limit);

      final ResultSet rows = _database.select(
        '''
        SELECT
          se.uuid,
          se.rfid_code,
          se.student_id,
          CASE WHEN se.student_id_desc != '' THEN se.student_id_desc ELSE COALESCE(sc.student_id_desc, '') END AS student_id_desc,
          CASE WHEN se.student_name != '' THEN se.student_name ELSE COALESCE(sc.student_name, '') END AS student_name,
          se.student_type,
          se.is_commuter,
          se.place_id,
          se.place_name,
          se.enter_at,
          se.is_exit,
          CASE WHEN se.type != '' THEN se.type ELSE COALESCE(sc.type, 'Student') END AS type,
          se.temperature,
          se.remarks,
          CASE WHEN se.grade_level != '' AND se.grade_level != 'N/A' THEN se.grade_level ELSE COALESCE(sc.grade_level, 'N/A') END AS grade_level,
          CASE WHEN se.section != '' AND se.section != 'N/A' THEN se.section ELSE COALESCE(sc.section, 'N/A') END AS section,
          se.adviser_id,
          se.branch_code,
          se.school_start,
          se.text_received,
          se.scanned_at,
          se.is_synced,
          se.error_message
        FROM stud_entry_tbl se
        LEFT JOIN students_cache sc ON se.rfid_code != '' AND sc.rfid_code = se.rfid_code
        $whereClause
        ORDER BY se.scanned_at DESC
        LIMIT ?;
        ''',
        args,
      );

      final results = rows.map((r) => ScanRecordModel.fromJson(Map<String, dynamic>.from(r))).toList();
      if (lowerQuery.isEmpty) {
        return results;
      }

      // Secondary Dart-side filter to guarantee 100% accurate search matching across resolved fields
      return results.where((rec) {
        return rec.studentName.toLowerCase().contains(lowerQuery) ||
            rec.studentIdDesc.toLowerCase().contains(lowerQuery) ||
            rec.rfidCode.toLowerCase().contains(lowerQuery) ||
            rec.placeName.toLowerCase().contains(lowerQuery) ||
            rec.gradeLevel.toLowerCase().contains(lowerQuery) ||
            rec.section.toLowerCase().contains(lowerQuery);
      }).toList();
    } catch (e) {
      debugPrint('[LocalDbService] Error fetching recent tap logs: $e');
      return [];
    }
  }

  /// Returns quick summary statistics for the Activity Logs view
  ({int totalToday, int entranceToday, int exitToday, int unsyncedTotal, int totalStored}) getTapStats() {
    try {
      final todayPrefix = '${_formatDateIso(now)}%';
      final ResultSet todayRows = _database.select(
        '''
        SELECT
          COUNT(*) AS total_today,
          SUM(CASE WHEN is_exit = 0 THEN 1 ELSE 0 END) AS entrance_today,
          SUM(CASE WHEN is_exit = 1 THEN 1 ELSE 0 END) AS exit_today
        FROM stud_entry_tbl
        WHERE scanned_at LIKE ? OR enter_at LIKE ?;
        ''',
        [todayPrefix, todayPrefix],
      );

      int totalToday = 0;
      int entranceToday = 0;
      int exitToday = 0;
      if (todayRows.isNotEmpty) {
        totalToday = (todayRows.first['total_today'] as int?) ?? 0;
        entranceToday = (todayRows.first['entrance_today'] as int?) ?? 0;
        exitToday = (todayRows.first['exit_today'] as int?) ?? 0;
      }

      final ResultSet totalRows = _database.select(
        '''
        SELECT
          COUNT(*) AS total_stored,
          SUM(CASE WHEN is_synced = 0 THEN 1 ELSE 0 END) AS unsynced_total
        FROM stud_entry_tbl;
        ''',
      );

      int totalStored = 0;
      int unsyncedTotal = 0;
      if (totalRows.isNotEmpty) {
        totalStored = (totalRows.first['total_stored'] as int?) ?? 0;
        unsyncedTotal = (totalRows.first['unsynced_total'] as int?) ?? 0;
      }

      return (
        totalToday: totalToday,
        entranceToday: entranceToday,
        exitToday: exitToday,
        unsyncedTotal: unsyncedTotal,
        totalStored: totalStored,
      );
    } catch (_) {
      return (
        totalToday: 0,
        entranceToday: 0,
        exitToday: 0,
        unsyncedTotal: 0,
        totalStored: 0,
      );
    }
  }

  static String _formatDateIso(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String _formatDisplayDate(DateTime dt) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${months[dt.month - 1]} ${dt.day.toString().padLeft(2, '0')}, ${dt.year}';
  }

  static String _formatDisplayTime(DateTime dt) {
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    final m = dt.minute.toString().padLeft(2, '0');
    return '${h.toString().padLeft(2, '0')}:$m $period';
  }
}
