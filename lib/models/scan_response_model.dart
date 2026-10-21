/// Represents student or employee details returned by the ERP or loaded from the Local DB.
class StudentInfoModel {
  final String name;
  final String personId; // student_id_desc in stud_entry_tbl, e.g. "03-003258" or "OA001"
  final String? imageUrl;
  final String? localImagePath; // Local file path in local_db/images/ for instant & offline display
  final String? date;
  final String? time;
  final String? ent; // "Entrance" or "Exit"
  final String? gradeLevel;
  final String? section;
  final String? type; // "Student" or "Employee"
  final int birthday;
  final int isCommuter;

  StudentInfoModel({
    required this.name,
    required this.personId,
    this.imageUrl,
    this.localImagePath,
    this.date,
    this.time,
    this.ent,
    this.gradeLevel,
    this.section,
    this.type = 'Student',
    this.birthday = 0,
    this.isCommuter = 0,
  });

  factory StudentInfoModel.fromJson(Map<String, dynamic> json, {int isCommuter = 0}) {
    return StudentInfoModel(
      name: json['name']?.toString() ?? json['student_name']?.toString() ?? '',
      personId: json['person_id']?.toString() ?? json['student_id_desc']?.toString() ?? '',
      imageUrl: json['image']?.toString() ?? json['image_url']?.toString(),
      localImagePath: json['local_image_path']?.toString(),
      date: json['date']?.toString(),
      time: json['time']?.toString(),
      ent: json['ent']?.toString(),
      gradeLevel: json['grade_level']?.toString(),
      section: json['section']?.toString(),
      type: json['type']?.toString() ?? 'Student',
      birthday: json['birthday'] is int
          ? json['birthday']
          : int.tryParse(json['birthday']?.toString() ?? '0') ?? 0,
      isCommuter: json['is_commuter'] is int
          ? json['is_commuter']
          : int.tryParse(json['is_commuter']?.toString() ?? '$isCommuter') ?? isCommuter,
    );
  }

  StudentInfoModel copyWith({
    String? name,
    String? personId,
    String? imageUrl,
    String? localImagePath,
    String? date,
    String? time,
    String? ent,
    String? gradeLevel,
    String? section,
    String? type,
    int? birthday,
    int? isCommuter,
  }) {
    return StudentInfoModel(
      name: name ?? this.name,
      personId: personId ?? this.personId,
      imageUrl: imageUrl ?? this.imageUrl,
      localImagePath: localImagePath ?? this.localImagePath,
      date: date ?? this.date,
      time: time ?? this.time,
      ent: ent ?? this.ent,
      gradeLevel: gradeLevel ?? this.gradeLevel,
      section: section ?? this.section,
      type: type ?? this.type,
      birthday: birthday ?? this.birthday,
      isCommuter: isCommuter ?? this.isCommuter,
    );
  }

  /// Checks if the core profile data matches another StudentInfoModel
  bool hasSameCoreProfile(StudentInfoModel other) {
    return name == other.name &&
        personId == other.personId &&
        (imageUrl ?? '') == (other.imageUrl ?? '') &&
        (gradeLevel ?? '') == (other.gradeLevel ?? '') &&
        (section ?? '') == (other.section ?? '') &&
        (type ?? 'Student') == (other.type ?? 'Student') &&
        birthday == other.birthday;
  }

  /// Resolves the absolute URL for the student picture given the ERP baseUrl
  String? getFullImageUrl(String baseUrl) {
    if (imageUrl == null || imageUrl!.isEmpty) return null;
    if (imageUrl!.startsWith('http://') || imageUrl!.startsWith('https://')) {
      return imageUrl;
    }
    // Prefix relative URL with baseUrl
    final cleanBase = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final cleanPath = imageUrl!.startsWith('/') ? imageUrl! : '/$imageUrl';
    return '$cleanBase$cleanPath';
  }
}

/// Represents the response received from POST /save_rfid_entry
class ScanResponseModel {
  final bool isSuccess;
  final String? message;
  final String? title;
  final int? status;
  final int isCommuter;
  final StudentInfoModel? studentInfo;

  ScanResponseModel({
    required this.isSuccess,
    this.message,
    this.title,
    this.status,
    this.isCommuter = 0,
    this.studentInfo,
  });

  factory ScanResponseModel.fromJson(Map<String, dynamic> json) {
    final hasInfo = json['info'] != null && json['info'] is Map<String, dynamic>;
    final statusVal = json['status'] is int ? json['status'] : null;
    final isSuccess = (statusVal == null || statusVal != 0) && hasInfo;
    final commuterVal = json['is_commuter'] is int
        ? json['is_commuter']
        : int.tryParse(json['is_commuter']?.toString() ?? '0') ?? 0;

    // Clean HTML tags from message if present (e.g. <b>Unable to Process...</b>)
    String? rawMsg = json['message']?.toString();
    if (rawMsg != null) {
      rawMsg = rawMsg.replaceAll(RegExp(r'<[^>]*>'), '');
    }

    return ScanResponseModel(
      isSuccess: isSuccess,
      message: rawMsg,
      title: json['title']?.toString(),
      status: statusVal,
      isCommuter: commuterVal,
      studentInfo: hasInfo
          ? StudentInfoModel.fromJson(
              json['info'] as Map<String, dynamic>,
              isCommuter: commuterVal,
            )
          : null,
    );
  }

  factory ScanResponseModel.networkError(String message) {
    return ScanResponseModel(
      isSuccess: false,
      message: message,
      title: 'Connection Error',
      status: 0,
    );
  }
}
