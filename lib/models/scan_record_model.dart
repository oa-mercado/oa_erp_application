import 'scan_response_model.dart';

/// Model representing an individual RFID tap record based on `stud_entry_tbl` columns
class ScanRecordModel {
  final String uuid;
  final String rfidCode;
  final DateTime scannedAt;
  final String branchCode;
  final int placeId;
  final String placeName;
  final String studentId;
  final String studentIdDesc; // person_id (e.g. "03-003258" or "OA001")
  final String studentName;
  final String studentType; // e.g. "Kto12" or "College"
  final int isCommuter;
  final String enterAt; // "YYYY-MM-DD HH:mm:ss"
  final int isExit; // 0 = Entrance, 1 = Exit
  final String type; // "Student" or "Employee"
  final String temperature;
  final String remarks;
  final String gradeLevel;
  final String section;
  final int adviserId;
  final String schoolStart;
  final int textReceived;
  final bool isSynced;
  final StudentInfoModel? studentInfo;
  final String? errorMessage;

  ScanRecordModel({
    String? uuid,
    required this.rfidCode,
    required this.scannedAt,
    required this.branchCode,
    required this.placeId,
    required this.placeName,
    this.studentId = '',
    this.studentIdDesc = '',
    this.studentName = '',
    this.studentType = 'Kto12',
    this.isCommuter = 0,
    String? enterAt,
    this.isExit = 0,
    this.type = 'Student',
    this.temperature = '',
    this.remarks = '',
    this.gradeLevel = 'N/A',
    this.section = 'N/A',
    this.adviserId = 0,
    this.schoolStart = '',
    this.textReceived = 0,
    this.isSynced = false,
    this.studentInfo,
    this.errorMessage,
  })  : uuid = uuid ?? '${scannedAt.microsecondsSinceEpoch}_$rfidCode',
        enterAt = enterAt ?? _formatSqlDateTime(scannedAt);

  static String _formatSqlDateTime(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min:$s';
  }

  /// Payload sent to POST /save_rfid_entry (includes stud_entry_tbl columns for sync)
  Map<String, dynamic> toErpPayload() => {
        'uuid': uuid,
        'rfid_code': rfidCode,
        'branch_code': branchCode,
        'place_id': placeId,
        'place_name': placeName,
        'scanned_at': scannedAt.toIso8601String(),
        'enter_at': enterAt,
        'date_local': enterAt,
        'is_exit': isExit,
        if (studentId.isNotEmpty) 'student_id': studentId,
        if (studentIdDesc.isNotEmpty) 'student_id_desc': studentIdDesc,
        if (studentName.isNotEmpty) 'student_name': studentName,
        'student_type': studentType,
        'is_commuter': isCommuter,
        'type': type,
        'grade_level': gradeLevel,
        'section': section,
        'adviser_id': adviserId,
        'school_start': schoolStart,
        'text_received': textReceived,
      };

  /// Full stud_entry_tbl JSON representation stored in the Local DB
  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'rfid_code': rfidCode,
        'student_id': studentId,
        'student_id_desc': studentIdDesc,
        'student_name': studentName,
        'student_type': studentType,
        'is_commuter': isCommuter,
        'place_id': placeId,
        'place_name': placeName,
        'enter_at': enterAt,
        'is_exit': isExit,
        'type': type,
        'temperature': temperature,
        'remarks': remarks,
        'grade_level': gradeLevel,
        'section': section,
        'adviser_id': adviserId,
        'branch_code': branchCode,
        'school_start': schoolStart,
        'text_received': textReceived,
        'scanned_at': scannedAt.toIso8601String(),
        'is_synced': isSynced,
        'error_message': errorMessage,
      };

  factory ScanRecordModel.fromJson(Map<String, dynamic> json) {
    final parsedDate = DateTime.tryParse(json['scanned_at']?.toString() ?? '') ??
        DateTime.tryParse(json['enter_at']?.toString() ?? '') ??
        DateTime.now();
    return ScanRecordModel(
      uuid: json['uuid']?.toString(),
      rfidCode: json['rfid_code']?.toString() ?? '',
      scannedAt: parsedDate,
      branchCode: json['branch_code']?.toString() ?? '',
      placeId: json['place_id'] is int
          ? json['place_id']
          : int.tryParse('${json['place_id']}') ?? 0,
      placeName: json['place_name']?.toString() ?? '',
      studentId: json['student_id']?.toString() ?? '',
      studentIdDesc: json['student_id_desc']?.toString() ?? '',
      studentName: json['student_name']?.toString() ?? '',
      studentType: json['student_type']?.toString() ?? 'Kto12',
      isCommuter: json['is_commuter'] is int
          ? json['is_commuter']
          : int.tryParse('${json['is_commuter'] ?? 0}') ?? 0,
      enterAt: json['enter_at']?.toString(),
      isExit: json['is_exit'] is int
          ? json['is_exit']
          : int.tryParse('${json['is_exit'] ?? 0}') ?? 0,
      type: json['type']?.toString() ?? 'Student',
      temperature: json['temperature']?.toString() ?? '',
      remarks: json['remarks']?.toString() ?? '',
      gradeLevel: json['grade_level']?.toString() ?? 'N/A',
      section: json['section']?.toString() ?? 'N/A',
      adviserId: json['adviser_id'] is int
          ? json['adviser_id']
          : int.tryParse('${json['adviser_id'] ?? 0}') ?? 0,
      schoolStart: json['school_start']?.toString() ?? '',
      textReceived: json['text_received'] is int
          ? json['text_received']
          : int.tryParse('${json['text_received'] ?? 0}') ?? 0,
      isSynced: json['is_synced'] == true || json['is_synced'] == 1,
      errorMessage: json['error_message']?.toString(),
    );
  }

  ScanRecordModel copyWith({
    String? studentId,
    String? studentIdDesc,
    String? studentName,
    String? studentType,
    int? isCommuter,
    int? isExit,
    String? type,
    String? gradeLevel,
    String? section,
    bool? isSynced,
    StudentInfoModel? studentInfo,
    String? errorMessage,
  }) {
    return ScanRecordModel(
      uuid: uuid,
      rfidCode: rfidCode,
      scannedAt: scannedAt,
      branchCode: branchCode,
      placeId: placeId,
      placeName: placeName,
      studentId: studentId ?? this.studentId,
      studentIdDesc: studentIdDesc ?? this.studentIdDesc,
      studentName: studentName ?? this.studentName,
      studentType: studentType ?? this.studentType,
      isCommuter: isCommuter ?? this.isCommuter,
      enterAt: enterAt,
      isExit: isExit ?? this.isExit,
      type: type ?? this.type,
      temperature: temperature,
      remarks: remarks,
      gradeLevel: gradeLevel ?? this.gradeLevel,
      section: section ?? this.section,
      adviserId: adviserId,
      schoolStart: schoolStart,
      textReceived: textReceived,
      isSynced: isSynced ?? this.isSynced,
      studentInfo: studentInfo ?? this.studentInfo,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}
