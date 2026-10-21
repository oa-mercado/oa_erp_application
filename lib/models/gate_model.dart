/// Model representing a Gate / Place (loaded from places_tbl in MySQL)
class GateModel {
  /// Numerical ID of the gate in places_tbl (required when logging taps)
  final int id;

  /// The physical gate name (e.g. "Main Gate", "Elementary Gate")
  final String placeName;

  /// Branch code this gate belongs to (e.g. "esps", "la_salle_greenhills")
  final String branchCode;

  /// Cooldown period in minutes before a student can tap again
  final int tapInterval;

  /// 1 = Gate supports both entrance and exit, 0 = entrance only
  final bool allowExit;

  /// 1 = Trigger SMS notifications to parents on card tap
  final bool allowNotif;

  /// MD5 hash of the ID (used in web kiosk URLs)
  final String md5Id;

  GateModel({
    required this.id,
    required this.placeName,
    required this.branchCode,
    this.tapInterval = 15,
    this.allowExit = true,
    this.allowNotif = false,
    this.md5Id = '',
  });

  factory GateModel.fromJson(Map<String, dynamic> json) {
    return GateModel(
      id: json['id'] is int ? json['id'] : int.tryParse(json['id']?.toString() ?? '0') ?? 0,
      placeName: json['place_name']?.toString() ?? 'Unknown Gate',
      branchCode: json['branch_code']?.toString() ?? '',
      tapInterval: json['tap_interval'] is int
          ? json['tap_interval']
          : int.tryParse(json['tap_interval']?.toString() ?? '3') ?? 3,
      allowExit: json['allow_exit'] == 1 || json['allow_exit'] == '1' || json['allow_exit'] == true,
      allowNotif: json['allow_notif'] == 1 || json['allow_notif'] == '1' || json['allow_notif'] == true,
      md5Id: json['md5_id']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'place_name': placeName,
    'branch_code': branchCode,
    'tap_interval': tapInterval,
    'allow_exit': allowExit ? 1 : 0,
    'allow_notif': allowNotif ? 1 : 0,
    'md5_id': md5Id,
  };
}
