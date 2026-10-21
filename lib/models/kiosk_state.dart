import 'scan_response_model.dart';

/// Type of card displayed in the floating kiosk overlay
enum KioskCardType {
  processing,
  success,
  error,
  offlineSaved,
  cooldown,
}

/// An active or pushed card in the kiosk display stack
class ActiveKioskCard {
  final String id;
  final String rfidCode;
  final KioskCardType type;
  final StudentInfoModel? studentInfo;
  final DateTime scannedAt;
  final String? errorMessage;
  final int? queuedCount;
  final int? cooldownSecondsRemaining;

  const ActiveKioskCard({
    required this.id,
    required this.rfidCode,
    required this.type,
    this.studentInfo,
    required this.scannedAt,
    this.errorMessage,
    this.queuedCount,
    this.cooldownSecondsRemaining,
  });

  bool get isProcessing => type == KioskCardType.processing;
  bool get isSuccess => type == KioskCardType.success;
  bool get isError => type == KioskCardType.error;
  bool get isOfflineSaved => type == KioskCardType.offlineSaved;
  bool get isCooldown => type == KioskCardType.cooldown;

  ActiveKioskCard copyWith({
    KioskCardType? type,
    StudentInfoModel? studentInfo,
    DateTime? scannedAt,
    String? errorMessage,
    int? queuedCount,
    int? cooldownSecondsRemaining,
  }) {
    return ActiveKioskCard(
      id: id,
      rfidCode: rfidCode,
      type: type ?? this.type,
      studentInfo: studentInfo ?? this.studentInfo,
      scannedAt: scannedAt ?? this.scannedAt,
      errorMessage: errorMessage ?? this.errorMessage,
      queuedCount: queuedCount ?? this.queuedCount,
      cooldownSecondsRemaining: cooldownSecondsRemaining ?? this.cooldownSecondsRemaining,
    );
  }
}

/// Overall Kiosk state supporting card stacking and push-left transitions
class KioskState {
  final List<ActiveKioskCard> activeCards;

  const KioskState({
    this.activeCards = const [],
  });

  bool get hasActiveCards => activeCards.isNotEmpty;

  KioskState copyWith({
    List<ActiveKioskCard>? activeCards,
  }) {
    return KioskState(
      activeCards: activeCards ?? this.activeCards,
    );
  }
}

