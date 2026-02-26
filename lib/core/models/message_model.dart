/// Models for chat messages and attachments (used by chat detail, media gallery, contact picker).
class ContactData {
  final String name;
  final String? email;
  final String? phone;

  ContactData({
    required this.name,
    this.email,
    this.phone,
  });
}

class LocationData {
  final double latitude;
  final double longitude;
  final String? name;
  final String? address;

  LocationData({
    required this.latitude,
    required this.longitude,
    this.name,
    this.address,
  });
}

class AttachmentModel {
  final String? fileUrl;
  final String? thumbnailUrl;
  final String? fileName;
  final int? fileSize;
  final String? mimeType;

  AttachmentModel({
    this.fileUrl,
    this.thumbnailUrl,
    this.fileName,
    this.fileSize,
    this.mimeType,
  });

  bool get isImage {
    final mime = mimeType?.toLowerCase() ?? '';
    return mime.startsWith('image/');
  }

  bool get isPdf => mimeType?.toLowerCase() == 'application/pdf';

  String get fileSizeFormatted {
    if (fileSize == null || fileSize! < 0) return '';
    final size = fileSize!;
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(0)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  factory AttachmentModel.fromJson(Map<String, dynamic> json) {
    return AttachmentModel(
      fileUrl: json['file_url']?.toString() ?? json['url']?.toString(),
      thumbnailUrl: json['thumbnail_url']?.toString(),
      fileName: json['file_name']?.toString() ?? json['name']?.toString(),
      fileSize: json['file_size'] ?? json['size'],
      mimeType: json['mime_type']?.toString(),
    );
  }
}

enum MessageStatus { sending, sent, delivered, read, failed }

class MessageModel {
  final String id;
  final String senderId;
  final String senderName;
  final String content;
  final String messageType;
  final List<AttachmentModel> attachments;
  final LocationData? locationData;
  final ContactData? contactData;
  final DateTime createdAt;
  final MessageStatus status;

  MessageModel({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.content,
    this.messageType = 'text',
    this.attachments = const [],
    this.locationData,
    this.contactData,
    required this.createdAt,
    this.status = MessageStatus.sent,
  });

  /// Prova content, content_encrypted_b64, text, body per il testo del messaggio.
  static String _getMessageText(Map<String, dynamic> json) {
    return json['content']?.toString() ??
        json['content_encrypted_b64']?.toString() ??
        json['text']?.toString() ??
        json['body']?.toString() ??
        '';
  }

  factory MessageModel.fromJson(Map<String, dynamic> json) {
    final attList = json['attachments'] as List<dynamic>?;
    return MessageModel(
      id: json['id']?.toString() ?? '',
      senderId: json['sender'] is Map
          ? (json['sender'] as Map)['id']?.toString() ?? ''
          : json['sender_id']?.toString() ?? '',
      senderName: json['sender'] is Map
          ? (json['sender'] as Map)['username']?.toString() ?? ''
          : json['sender_name']?.toString() ?? '',
      content: _getMessageText(json),
      messageType: json['message_type']?.toString() ?? 'text',
      attachments: attList
              ?.map((a) => AttachmentModel.fromJson(a as Map<String, dynamic>))
              .toList() ??
          [],
      locationData: json['metadata'] is Map
          ? _parseLocationFromMetadata(
              Map<String, dynamic>.from(json['metadata'] as Map))
          : null,
      contactData: json['metadata'] is Map
          ? _parseContactFromMetadata(
              Map<String, dynamic>.from(json['metadata'] as Map))
          : null,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
      status: MessageStatus.sent,
    );
  }

  static LocationData? _parseLocationFromMetadata(Map<String, dynamic> m) {
    final lat = m['latitude'];
    final lng = m['longitude'];
    if (lat == null || lng == null) return null;
    return LocationData(
      latitude: (lat is num) ? lat.toDouble() : double.tryParse(lat.toString()) ?? 0,
      longitude: (lng is num) ? lng.toDouble() : double.tryParse(lng.toString()) ?? 0,
      name: m['name']?.toString(),
      address: m['address']?.toString(),
    );
  }

  static ContactData? _parseContactFromMetadata(Map<String, dynamic> m) {
    final name = m['name']?.toString();
    if (name == null || name.isEmpty) return null;
    return ContactData(
      name: name,
      email: m['email']?.toString(),
      phone: m['phone']?.toString(),
    );
  }
}
