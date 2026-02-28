import '../constants/app_constants.dart';

class LastMessage {
  final String? id;
  String? content;
  final String? contentEncryptedB64;
  final String? senderName;
  final int? senderId;
  final DateTime? createdAt;
  final String? messageType;
  /// True se l'ultimo messaggio ha un allegato E2E (is_encrypted).
  final bool hasEncryptedAttachment;
  /// Stati invio/lettura (lista di { user, status, timestamp }) dal backend.
  final List<dynamic>? statuses;

  LastMessage({
    this.id,
    this.content,
    this.contentEncryptedB64,
    this.senderName,
    this.senderId,
    this.createdAt,
    this.messageType,
    this.hasEncryptedAttachment = false,
    this.statuses,
  });

  factory LastMessage.fromJson(Map<String, dynamic> json) {
    final sender = json['sender'] is Map ? json['sender'] as Map : null;
    final attachments = json['attachments'] as List?;
    final hasEncrypted = attachments != null &&
        attachments.isNotEmpty &&
        attachments.first is Map &&
        (attachments.first as Map)['is_encrypted'] == true;
    return LastMessage(
      id: json['id']?.toString(),
      content: json['content']?.toString() ?? '',
      contentEncryptedB64: json['content_encrypted_b64']?.toString(),
      senderName: sender?['username']?.toString(),
      senderId: sender != null ? (sender['id'] is int ? sender['id'] as int : int.tryParse(sender['id']?.toString() ?? '')) : null,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString())
          : null,
      messageType: json['message_type']?.toString(),
      hasEncryptedAttachment: hasEncrypted,
      statuses: json['statuses'] as List<dynamic>?,
    );
  }

  /// True se almeno uno status è 'read'.
  bool get isRead =>
      (statuses ?? []).any((s) => s is Map && (s['status']?.toString() == 'read'));

  /// True se almeno uno status è 'delivered'.
  bool get isDelivered =>
      (statuses ?? []).any((s) => s is Map && (s['status']?.toString() == 'delivered'));
}

class ConversationModel {
  final String id;
  final String convType;
  final String? name;
  final String? groupAvatarUrl;
  final List<ConversationParticipant> participants;
  final LastMessage? lastMessage;
  final int unreadCount;
  final bool isMuted;
  final bool isLocked;
  final bool isFavorite;
  final DateTime? createdAt;

  ConversationModel({
    required this.id,
    required this.convType,
    this.name,
    this.groupAvatarUrl,
    this.participants = const [],
    this.lastMessage,
    this.unreadCount = 0,
    this.isMuted = false,
    this.isLocked = false,
    this.isFavorite = false,
    this.createdAt,
  });

  bool get isGroup => convType == 'group';

  /// Restituisce l'altro partecipante (non l'utente corrente). Per gruppi restituisce null.
  ConversationParticipant? otherParticipant(int? currentUserId) {
    if (isGroup || participants.isEmpty) return null;
    if (currentUserId == null) {
      return participants.length > 1 ? participants[1] : participants.first;
    }
    for (final p in participants) {
      if (p.userId != currentUserId) return p;
    }
    return participants.first;
  }

  String get displayName {
    if (isGroup && name != null && name!.isNotEmpty) {
      return name!;
    }
    if (participants.isNotEmpty) {
      final other = participants.length > 1 ? participants[1] : participants.first;
      return other.displayName;
    }
    return 'Unknown';
  }

  String displayNameFor(int? currentUserId) {
    if (isGroup && name != null && name!.isNotEmpty) return name!;
    final other = otherParticipant(currentUserId);
    return other?.displayName ?? displayName;
  }

  String? get avatarUrl {
    if (!isGroup && participants.isNotEmpty) {
      final other = participants.length > 1 ? participants[1] : participants.first;
      return other.avatar;
    }
    return null;
  }

  String? avatarUrlFor(int? currentUserId) {
    if (isGroup) return null;
    final other = otherParticipant(currentUserId);
    return other?.avatar ?? avatarUrl;
  }

  bool get isOtherOnline {
    if (!isGroup && participants.length > 1) {
      return participants[1].isOnline;
    }
    return false;
  }

  bool isOtherOnlineFor(int? currentUserId) {
    final other = otherParticipant(currentUserId);
    return other?.isOnline ?? false;
  }

  List<String?> get groupAvatars {
    if (isGroup) {
      // Se c'è un avatar dedicato del gruppo, usalo come primo
      if (groupAvatarUrl != null && groupAvatarUrl!.isNotEmpty && groupAvatarUrl != 'null') {
        return [groupAvatarUrl];
      }
      return participants.take(3).map((p) => p.avatar).toList();
    }
    return [];
  }

  String get previewText => previewTextFor(null);

  /// Anteprima ultimo messaggio; se [currentUserId] è fornito e il messaggio è dell'utente corrente, mostra "Tu: ...".
  String previewTextFor(int? currentUserId) {
    if (lastMessage == null) return 'Nessun messaggio';
    final content = (lastMessage!.content ?? '').trim();
    final type = lastMessage!.messageType ?? '';
    final isMe = currentUserId != null && lastMessage!.senderId == currentUserId;
    final prefix = isMe ? 'Tu: ' : '';

    // Preview uniforme per messaggi E2E: stesso testo su tutti i device
    if (content.contains('🔒') || content.contains('Messaggio cifrato')) {
      return '$prefix🔒 Messaggio cifrato';
    }

    if (lastMessage!.hasEncryptedAttachment) {
      return '$prefix📎 Allegato cifrato';
    }
    switch (type) {
      case 'image':
        return '$prefix📷 Foto';
      case 'video':
        return '$prefix▶️ Video';
      case 'audio':
        return '$prefix🎵 Audio';
      case 'voice':
        return '$prefix🎤 Messaggio vocale';
      case 'location':
      case 'location_live':
        return '$prefix📍 Posizione';
      case 'contact':
        return '$prefix👤 Contatto';
      case 'file': {
        final fileName = content.isNotEmpty ? content : 'Documento';
        final ext = fileName.split('.').last.toLowerCase();
        switch (ext) {
          case 'pdf':
            return '$prefix📕 $fileName';
          case 'doc':
          case 'docx':
            return '$prefix📘 $fileName';
          case 'xls':
          case 'xlsx':
            return '$prefix📗 $fileName';
          case 'ppt':
          case 'pptx':
            return '$prefix📙 $fileName';
          default:
            return '$prefix📎 $fileName';
        }
      }
      default:
        if (content.isNotEmpty) return isMe ? 'Tu: $content' : content;
        return 'Nessun messaggio';
    }
  }

  /// Formato: "HH:mm" se oggi, "ieri" se ieri, "dd/MM" altrimenti.
  String get formattedTime {
    if (lastMessage?.createdAt == null) return '';
    final now = DateTime.now();
    final msgTime = lastMessage!.createdAt!;
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(msgTime.year, msgTime.month, msgTime.day);

    if (msgDay == today) {
      return '${msgTime.hour.toString().padLeft(2, '0')}:${msgTime.minute.toString().padLeft(2, '0')}';
    }
    if (today.difference(msgDay).inDays == 1) return 'Ieri';
    return '${msgTime.day.toString().padLeft(2, '0')}/${msgTime.month.toString().padLeft(2, '0')}';
  }

  static String? toAbsoluteUrl(String? url) {
    if (url == null || url.isEmpty || url == 'null') return null;
    if (url.startsWith('http')) return url;
    // Usa solo il dominio (senza /api) per path come /media/
    final baseUrl = AppConstants.baseUrl;
    final uri = Uri.parse(baseUrl);
    final domainOnly = '${uri.scheme}://${uri.host}${uri.port != 80 && uri.port != 443 ? ':${uri.port}' : ''}';
    return '$domainOnly$url';
  }

  factory ConversationModel.fromJson(Map<String, dynamic> json) {
    // Backend usa participants_info (lista con { user, role, unread_count }), fallback a participants
    final rawList = json['participants_info'] as List<dynamic>? ?? json['participants'] as List<dynamic>?;
    final participantsList = rawList
        ?.map((p) => ConversationParticipant.fromJson(
            p is Map<String, dynamic> ? p : <String, dynamic>{}))
        .toList() ?? [];

    return ConversationModel(
      id: json['id']?.toString() ?? '',
      convType: json['conv_type'] ?? 'private',
      name: json['name']?.toString() ?? json['group_name']?.toString(),
      groupAvatarUrl: toAbsoluteUrl(json['group_avatar']?.toString()),
      participants: participantsList,
      lastMessage: json['last_message'] != null
          ? LastMessage.fromJson(
              json['last_message'] is Map<String, dynamic>
                  ? json['last_message'] as Map<String, dynamic>
                  : <String, dynamic>{})
          : null,
      unreadCount: json['unread_count'] ?? 0,
      isMuted: json['is_muted'] ?? false,
      isLocked: json['is_locked'] ?? false,
      isFavorite: json['is_favorite'] ?? false,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString())
          : null,
    );
  }
}

class ConversationParticipant {
  final int userId;
  final String username;
  final String displayName;
  final String? avatar;
  final bool isOnline;

  ConversationParticipant({
    required this.userId,
    required this.username,
    required this.displayName,
    this.avatar,
    this.isOnline = false,
  });

  factory ConversationParticipant.fromJson(Map<String, dynamic> json) {
    final user = json['user'] is Map<String, dynamic> ? json['user'] as Map<String, dynamic> : json;
    final firstName = user['first_name']?.toString() ?? '';
    final lastName = user['last_name']?.toString() ?? '';
    final username = user['username']?.toString() ?? '';

    String display = username;
    if (firstName.isNotEmpty || lastName.isNotEmpty) {
      display = '$firstName $lastName'.trim();
    }

    return ConversationParticipant(
      userId: user['id'] ?? 0,
      username: username,
      displayName: display,
      avatar: ConversationModel.toAbsoluteUrl(user['avatar']?.toString()),
      isOnline: user['is_online'] ?? false,
    );
  }
}
