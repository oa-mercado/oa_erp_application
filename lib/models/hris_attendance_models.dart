import 'dart:math';
import 'dart:ui' show Color;
import '../core/config/env_config.dart';
import 'scan_response_model.dart';

/// Portal configuration scraped from `GET /hris/online_attendance` (`<online-attendance ... />`)
/// and persisted in SQLite for instant startup & offline fallback.
class HrisPortalConfig {
  final String schoolImage;
  final String colorHex;
  final String textColorHex;
  final String schoolName;
  final String schoolBranch;
  final int schoolId;
  final int isRestricted;
  final String bgImgUrl;
  final String branchCode;
  final int idType; // 0 = QR only, 1 = RFID only, 2 = Both QR & RFID

  const HrisPortalConfig({
    this.schoolImage = '',
    this.colorHex = '#083980',
    this.textColorHex = '#ffffff',
    this.schoolName = '',
    this.schoolBranch = '',
    this.schoolId = 0,
    this.isRestricted = 1,
    this.bgImgUrl = '',
    this.branchCode = '',
    this.idType = 1,
  });

  Color get primaryColor => _parseHexColor(colorHex, EnvConfig.backgroundColor);
  Color get textColor => _parseHexColor(textColorHex, const Color(0xFFFFFFFF));

  String get portalHeaderTitle {
    if (schoolId == 76) return "PERSONNEL'S ATTENDANCE PORTAL";
    if (schoolId == 156) return 'ONLINE PERSONNEL ATTENDANCE PORTAL';
    return 'ONLINE ATTENDANCE PORTAL';
  }

  /// Default `time_in_type` matching `OnlineAttendance.vue` (`chkSettings()`)
  int get defaultTimeInType {
    if (schoolId == 76) return 2;
    return idType > 0 ? 2 : 1;
  }

  HrisPortalConfig copyWith({
    String? schoolImage,
    String? colorHex,
    String? textColorHex,
    String? schoolName,
    String? schoolBranch,
    int? schoolId,
    int? isRestricted,
    String? bgImgUrl,
    String? branchCode,
    int? idType,
  }) {
    return HrisPortalConfig(
      schoolImage: schoolImage ?? this.schoolImage,
      colorHex: colorHex ?? this.colorHex,
      textColorHex: textColorHex ?? this.textColorHex,
      schoolName: schoolName ?? this.schoolName,
      schoolBranch: schoolBranch ?? this.schoolBranch,
      schoolId: schoolId ?? this.schoolId,
      isRestricted: isRestricted ?? this.isRestricted,
      bgImgUrl: bgImgUrl ?? this.bgImgUrl,
      branchCode: branchCode ?? this.branchCode,
      idType: idType ?? this.idType,
    );
  }

  Map<String, dynamic> toJson() => {
        'school_image': schoolImage,
        'color': colorHex,
        'text_color': textColorHex,
        'school_name': schoolName,
        'school_branch': schoolBranch,
        'school_id': schoolId,
        'is_restricted': isRestricted,
        'bg_img_url': bgImgUrl,
        'branch_code': branchCode,
        'id_type': idType,
      };

  factory HrisPortalConfig.fromJson(Map<String, dynamic> json) {
    return HrisPortalConfig(
      schoolImage: json['school_image']?.toString() ?? '',
      colorHex: json['color']?.toString() ?? '#083980',
      textColorHex: json['text_color']?.toString() ?? '#ffffff',
      schoolName: json['school_name']?.toString() ?? '',
      schoolBranch: json['school_branch']?.toString() ?? '',
      schoolId: int.tryParse(json['school_id']?.toString() ?? '0') ?? 0,
      isRestricted: int.tryParse(json['is_restricted']?.toString() ?? '1') ?? 1,
      bgImgUrl: json['bg_img_url']?.toString() ?? '',
      branchCode: json['branch_code']?.toString() ?? '',
      idType: int.tryParse(json['id_type']?.toString() ?? '1') ?? 1,
    );
  }

  /// Parses `<online-attendance ... />` component attributes from HTML
  factory HrisPortalConfig.fromOnlineAttendanceHtml(String html, {int idType = 1}) {
    final tagMatch = RegExp(
      r'<online-attendance\b([^>]*?)\/?>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);

    final attrs = tagMatch?.group(1) ?? html;

    String extractAttr(String name, {String fallback = ''}) {
      final m = RegExp(
        '$name\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\')',
        caseSensitive: false,
      ).firstMatch(attrs);
      final raw = m?.group(1) ?? m?.group(2) ?? fallback;
      return decodeHtmlEntities(raw.trim());
    }

    final color = extractAttr('color', fallback: '#083980');
    final textColor = extractAttr('text_color', fallback: '#ffffff');

    return HrisPortalConfig(
      schoolImage: extractAttr('school_image'),
      colorHex: color.isEmpty ? '#083980' : color,
      textColorHex: textColor.isEmpty ? '#ffffff' : textColor,
      schoolName: extractAttr('school_name', fallback: EnvConfig.appName),
      schoolBranch: extractAttr('school_branch'),
      schoolId: int.tryParse(extractAttr('school_id', fallback: '0')) ?? 0,
      isRestricted: int.tryParse(extractAttr('is_restricted', fallback: '1')) ?? 1,
      bgImgUrl: extractAttr('bg_img_url'),
      branchCode: extractAttr('branch_code', fallback: EnvConfig.defaultBranch),
      idType: idType,
    );
  }

  static String decodeHtmlEntities(String input) {
    if (input.isEmpty || !input.contains('&')) return input;
    return input
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ');
  }

  static Color _parseHexColor(String hexStr, Color fallback) {
    final clean = hexStr.replaceAll('#', '').trim();
    if (clean.length == 6) {
      final v = int.tryParse('FF$clean', radix: 16);
      if (v != null) return Color(v);
    } else if (clean.length == 8) {
      final v = int.tryParse(clean, radix: 16);
      if (v != null) return Color(v);
    }
    return fallback;
  }
}

enum HrisAccessStatus {
  unlocked,
  requiresPasscode,
  offlineError,
}

class HrisPortalAccessResult {
  final HrisAccessStatus status;
  final HrisPortalConfig? config;
  final String? passcodeSchoolLogoUrl;
  final String? activeHrisBaseUrl;
  final String? errorMessage;

  const HrisPortalAccessResult({
    required this.status,
    this.config,
    this.passcodeSchoolLogoUrl,
    this.activeHrisBaseUrl,
    this.errorMessage,
  });
}

class HrisPasscodeVerifyResult {
  final bool isSuccess;
  final String message;
  final bool isNetworkError;

  const HrisPasscodeVerifyResult({
    required this.isSuccess,
    required this.message,
    this.isNetworkError = false,
  });
}

class HrisEmployeeInfo {
  final String keyId;
  final String employeeId;
  final String firstname;
  final String middlename;
  final String lastname;
  final String fullName;
  final String? picture;
  final String? localImagePath;
  final int isBirthday;

  const HrisEmployeeInfo({
    this.keyId = '',
    required this.employeeId,
    this.firstname = '',
    this.middlename = '',
    this.lastname = '',
    required this.fullName,
    this.picture,
    this.localImagePath,
    this.isBirthday = 0,
  });

  bool get isDefaultPlaceholderPicture {
    if (picture == null || picture!.trim().isEmpty) return true;
    return picture!.toLowerCase().contains('default-picture.png');
  }

  /// Resolves full network image URL against the HRIS base URL / server origin
  String? resolveNetworkPictureUrl(String hrisBaseUrl) {
    if (isDefaultPlaceholderPicture) return null;
    final raw = picture!.trim();
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return raw;
    }
    try {
      final uri = Uri.parse(hrisBaseUrl);
      final origin = '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
      final cleanPath = raw.startsWith('/') ? raw : '/$raw';
      return '$origin$cleanPath';
    } catch (_) {
      return null;
    }
  }

  HrisEmployeeInfo copyWith({
    String? localImagePath,
    String? picture,
  }) {
    return HrisEmployeeInfo(
      keyId: keyId,
      employeeId: employeeId,
      firstname: firstname,
      middlename: middlename,
      lastname: lastname,
      fullName: fullName,
      picture: picture ?? this.picture,
      localImagePath: localImagePath ?? this.localImagePath,
      isBirthday: isBirthday,
    );
  }

  StudentInfoModel toStudentInfoModel({
    required String hrisBaseUrl,
    String? attendanceType,
    String? date,
    String? time,
  }) {
    final isOut = attendanceType?.toLowerCase().contains('out') == true;
    return StudentInfoModel(
      name: fullName,
      personId: employeeId,
      imageUrl: resolveNetworkPictureUrl(hrisBaseUrl),
      localImagePath: localImagePath,
      date: date,
      time: time,
      ent: isOut ? 'Exit' : 'Entrance',
      gradeLevel: 'Employee',
      section: 'HRIS',
      type: 'Employee',
      birthday: isBirthday,
      isCommuter: 0,
    );
  }

  factory HrisEmployeeInfo.fromJson(Map<String, dynamic> json) {
    final fname = (json['firstname'] ?? json['fname'] ?? '').toString().trim();
    final mname = (json['middlename'] ?? json['mname'] ?? '').toString().trim();
    final lname = (json['lastname'] ?? json['lname'] ?? '').toString().trim();
    final ext = (json['ext_name'] ?? '').toString().trim();

    String computedFull = (json['full_name'] ?? '').toString().trim();
    if (computedFull.isEmpty) {
      final parts = [
        if (lname.isNotEmpty) '$lname,',
        if (fname.isNotEmpty) fname,
        if (mname.isNotEmpty) mname,
        if (ext.isNotEmpty) ext,
      ];
      computedFull = parts.join(' ').trim();
    }

    final empId = (json['employee_id'] ?? json['key_id'] ?? json['id'] ?? '').toString().trim();
    final bday = json['is_birthday'] is int
        ? json['is_birthday'] as int
        : int.tryParse(json['is_birthday']?.toString() ?? '0') ?? 0;

    return HrisEmployeeInfo(
      keyId: (json['key_id'] ?? json['id'] ?? '').toString(),
      employeeId: empId,
      firstname: fname,
      middlename: mname,
      lastname: lname,
      fullName: computedFull.isNotEmpty ? computedFull : empId,
      picture: json['picture']?.toString(),
      localImagePath: json['local_image_path']?.toString(),
      isBirthday: bday,
    );
  }
}

class HrisTodayLogEntry {
  final String employeeId;
  final String employeeName;
  final String? timeIn;
  final String? timeOut;
  final String? amIn;
  final String? amOut;
  final String? pmIn;
  final String? pmOut;
  final bool isPendingOffline;

  const HrisTodayLogEntry({
    this.employeeId = '',
    required this.employeeName,
    this.timeIn,
    this.timeOut,
    this.amIn,
    this.amOut,
    this.pmIn,
    this.pmOut,
    this.isPendingOffline = false,
  });

  factory HrisTodayLogEntry.fromJson(Map<String, dynamic> json) {
    return HrisTodayLogEntry(
      employeeId: (json['employee_id'] ?? '').toString(),
      employeeName: (json['employee_name'] ?? '-').toString(),
      timeIn: json['time_in']?.toString(),
      timeOut: json['time_out']?.toString(),
      amIn: json['am_in']?.toString(),
      amOut: json['am_out']?.toString(),
      pmIn: json['pm_in']?.toString(),
      pmOut: json['pm_out']?.toString(),
      isPendingOffline: json['is_pending_offline'] == true,
    );
  }
}

class HrisTapResponse {
  final bool isHttpSuccess;
  final bool isNetworkError;
  final int httpStatusCode;
  final HrisEmployeeInfo? employee;
  final String? logMessage;
  final bool logType;
  final String? logVoicePrompt;
  final bool showIntervalPrompt;
  final String? timeNow;
  final String? attendanceType;
  final bool isDifferentErrorPrompt;
  final List<HrisTodayLogEntry>? inlineLogs;

  const HrisTapResponse({
    required this.isHttpSuccess,
    this.isNetworkError = false,
    this.httpStatusCode = 200,
    this.employee,
    this.logMessage,
    this.logType = false,
    this.logVoicePrompt,
    this.showIntervalPrompt = false,
    this.timeNow,
    this.attendanceType,
    this.isDifferentErrorPrompt = false,
    this.inlineLogs,
  });

  /// True when the server processed a known employee tap (either recorded attendance,
  /// interval cooldown, completed schedule, or deterministic "No schedule available!").
  bool get hasValidEmployee => employee != null;

  /// True when the server responded HTTP 200 and explicitly rejected the code as non-existent/invalid
  bool get isPermanentRejection {
    if (isNetworkError || httpStatusCode != 200) return false;
    if (employee != null) return false;
    final msg = (logMessage ?? '').toLowerCase();
    return msg.contains('not found') ||
        msg.contains('invalid') ||
        msg.isEmpty;
  }

  factory HrisTapResponse.fromJson(Map<String, dynamic> json, {int httpStatusCode = 200}) {
    HrisEmployeeInfo? emp;
    if (json['employee'] is Map) {
      emp = HrisEmployeeInfo.fromJson(Map<String, dynamic>.from(json['employee'] as Map));
    }

    final rawLogType = json['log_type'];
    final bool parsedLogType = rawLogType == true || rawLogType == 1 || rawLogType == '1' || rawLogType == 'true';

    final rawInterval = json['show_interval_prompt'];
    final bool parsedInterval = rawInterval == true || rawInterval == 1 || rawInterval == '1';

    final rawDiffErr = json['is_different_error_prompt'];
    final bool parsedDiffErr = rawDiffErr == true || rawDiffErr == 1 || rawDiffErr == '1';

    List<HrisTodayLogEntry>? parsedInlineLogs;
    if (json['log_in'] is List) {
      parsedInlineLogs = (json['log_in'] as List)
          .whereType<Map>()
          .map((m) => HrisTodayLogEntry.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    }

    return HrisTapResponse(
      isHttpSuccess: httpStatusCode == 200,
      isNetworkError: false,
      httpStatusCode: httpStatusCode,
      employee: emp,
      logMessage: json['log_message']?.toString(),
      logType: parsedLogType,
      logVoicePrompt: json['log_voice_prompt']?.toString(),
      showIntervalPrompt: parsedInterval,
      timeNow: json['time_now']?.toString(),
      attendanceType: json['attendance_type']?.toString(),
      isDifferentErrorPrompt: parsedDiffErr,
      inlineLogs: parsedInlineLogs,
    );
  }

  factory HrisTapResponse.networkError(String message, {int httpStatusCode = 0}) {
    return HrisTapResponse(
      isHttpSuccess: false,
      isNetworkError: true,
      httpStatusCode: httpStatusCode,
      logMessage: message,
      logType: false,
    );
  }
}

class HrisQuote {
  final String text;
  final String? author;

  const HrisQuote({required this.text, this.author});

  static final Random _rng = Random();

  static HrisQuote random() => quotes[_rng.nextInt(quotes.length)];

  static const List<HrisQuote> quotes = [
    HrisQuote(
      text: 'Genius is one percent inspiration and ninety-nine percent perspiration.',
      author: 'Thomas Edison',
    ),
    HrisQuote(
      text: 'You can observe a lot just by watching.',
      author: 'Yogi Berra',
    ),
    HrisQuote(
      text: 'Well begun is half done.',
      author: 'Aristotle',
    ),
    HrisQuote(
      text: 'Nothing happens unless first we dream.',
      author: 'Carl Sandburg',
    ),
    HrisQuote(
      text: 'Life is a learning experience, only if you learn.',
      author: 'Yogi Berra',
    ),
    HrisQuote(
      text: 'Peace comes from within. Do not seek it without.',
      author: 'Buddha',
    ),
    HrisQuote(
      text: 'What you give is what you get.',
      author: 'Byron Pulsifer',
    ),
    HrisQuote(
      text: 'Life is change. Growth is optional. Choose wisely.',
      author: 'Karen Clark',
    ),
    HrisQuote(
      text: "You'll see it when you believe it.",
      author: 'Wayne Dyer',
    ),
    HrisQuote(
      text: 'To lead people walk behind them.',
      author: 'Lao Tzu',
    ),
    HrisQuote(
      text: 'Quality is not an act, it is a habit.',
      author: 'Aristotle',
    ),
    HrisQuote(
      text: 'The secret of getting ahead is getting started.',
      author: 'Mark Twain',
    ),
    HrisQuote(
      text: 'Act as if what you do makes a difference. It does.',
      author: 'William James',
    ),
    HrisQuote(
      text: 'Believe you can and you are halfway there.',
      author: 'Theodore Roosevelt',
    ),
  ];
}
