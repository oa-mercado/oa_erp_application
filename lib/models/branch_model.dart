/// Model representing a School Branch / Campus (loaded from ERP creds.json)
class BranchModel {
  /// The unique branch code (e.g. "esps", "la_salle_greenhills")
  final String id;

  /// The display name of the branch (e.g. "ESPS Santa Cruz", "scholastica")
  final String name;

  /// The school numerical ID
  final int schId;

  BranchModel({
    required this.id,
    required this.name,
    required this.schId,
  });

  factory BranchModel.fromJson(Map<String, dynamic> json) {
    return BranchModel(
      id: json['id']?.toString() ?? '',
      name: json['text']?.toString() ?? json['name']?.toString() ?? json['id']?.toString() ?? '',
      schId: json['sch_id'] is int
          ? json['sch_id']
          : int.tryParse(json['sch_id']?.toString() ?? '0') ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': name,
    'sch_id': schId,
  };
}
