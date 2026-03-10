/// Model for a call log entry from GET /api/calls/log/
/// Matches CallLogSerializer: id, call_type, status, initiated_by, other_party, direction, is_group_call, duration, created_at
class CallLogModel {
  final String id;
  final String callType;
  final String status;
  final int initiatedById;
  final String initiatedByName;
  final String? initiatedByAvatar;
  final CallLogUser? otherParty;
  final String direction; // 'outgoing' | 'incoming'
  final bool isGroupCall;
  final int duration; // seconds
  final DateTime createdAt;

  CallLogModel({
    required this.id,
    required this.callType,
    required this.status,
    required this.initiatedById,
    required this.initiatedByName,
    this.initiatedByAvatar,
    this.otherParty,
    required this.direction,
    required this.isGroupCall,
    required this.duration,
    required this.createdAt,
  });

  bool get isMissed => status == 'missed' || status == 'failed';
  bool get isRejected => status == 'rejected';
  bool get isOutgoing => direction == 'outgoing';
  bool get isCompleted => status == 'ended';

  /// Duration as Duration object
  Duration? get durationDuration =>
      duration > 0 ? Duration(seconds: duration) : null;

  /// Display name for the "other" participant (never the current user).
  /// Outgoing: show callee (other_party); incoming: show caller (initiator).
  /// If other_party is null for outgoing, fallback to avoid showing own name.
  String displayName([int? currentUserId]) {
    if (otherParty != null) return otherParty!.displayName;
    if (direction == 'incoming') return initiatedByName;
    // Outgoing but other_party null (e.g. call not answered): avoid showing initiator (self)
    return 'Utente';
  }

  /// Avatar URL for the other party (for list row).
  String? displayAvatarUrl([int? currentUserId]) {
    if (otherParty != null) return otherParty!.avatarUrl;
    if (direction == 'incoming') return initiatedByAvatar;
    return null;
  }

  /// Other user id (for starting a call or opening chat). Never the current user.
  int? otherUserId([int? currentUserId]) {
    if (isOutgoing) return otherParty?.id;
    return initiatedById;
  }

  /// [currentUserId] se fornito permette di calcolare la direzione lato client (io ho chiamato = outgoing, mi hanno chiamato = incoming).
  static CallLogModel fromJson(Map<String, dynamic> json, {int? currentUserId}) {
    final initiatedBy = json['initiated_by'] as Map<String, dynamic>?;
    final initId = initiatedBy != null
        ? (initiatedBy['id'] is int
            ? initiatedBy['id'] as int
            : int.tryParse(initiatedBy['id']?.toString() ?? '0') ?? 0)
        : 0;
    final first = initiatedBy?['first_name']?.toString() ?? '';
    final last = initiatedBy?['last_name']?.toString() ?? '';
    final initName = '$first $last'.trim();
    final initNameFinal = initName.isNotEmpty ? initName : (initiatedBy?['username']?.toString() ?? 'Utente');
    final initAvatar = initiatedBy?['avatar']?.toString();

    CallLogUser? other;
    final op = json['other_party'];
    if (op is Map<String, dynamic>) {
      other = CallLogUser.fromJson(op);
    }

    final createdAtStr = json['created_at']?.toString();
    final createdAt = createdAtStr != null
        ? DateTime.tryParse(createdAtStr) ?? DateTime.now()
        : DateTime.now();

    // Direzione: se abbiamo currentUserId la calcoliamo (initiator == io → outgoing, altrimenti incoming)
    String direction;
    if (currentUserId != null) {
      direction = initId == currentUserId ? 'outgoing' : 'incoming';
    } else {
      final raw = (json['direction']?.toString() ?? 'incoming').trim().toLowerCase();
      direction = (raw == 'outgoing') ? 'outgoing' : 'incoming';
    }

    return CallLogModel(
      id: json['id']?.toString() ?? '',
      callType: json['call_type']?.toString() ?? 'audio',
      status: json['status']?.toString() ?? 'ended',
      initiatedById: initId,
      initiatedByName: initNameFinal,
      initiatedByAvatar: initAvatar,
      otherParty: other,
      direction: direction,
      isGroupCall: json['is_group_call'] == true,
      duration: json['duration'] is int
          ? json['duration'] as int
          : int.tryParse(json['duration']?.toString() ?? '0') ?? 0,
      createdAt: createdAt,
    );
  }
}

/// Minimal user info from other_party / initiated_by (UserPublicSerializer)
class CallLogUser {
  final int id;
  final String username;
  final String displayName;
  final String? avatarUrl;

  CallLogUser({
    required this.id,
    required this.username,
    required this.displayName,
    this.avatarUrl,
  });

  static CallLogUser fromJson(Map<String, dynamic> json) {
    final id = json['id'] is int
        ? json['id'] as int
        : int.tryParse(json['id']?.toString() ?? '0') ?? 0;
    final first = json['first_name']?.toString() ?? '';
    final last = json['last_name']?.toString() ?? '';
    final name = '$first $last'.trim();
    final displayName = name.isNotEmpty ? name : (json['username']?.toString() ?? 'Utente');
    final avatar = json['avatar']?.toString();
    return CallLogUser(
      id: id,
      username: json['username']?.toString() ?? '',
      displayName: displayName,
      avatarUrl: avatar,
    );
  }
}
