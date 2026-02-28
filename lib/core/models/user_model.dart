import '../constants/app_constants.dart';

class UserModel {
  final int id;
  final String username;
  final String email;
  final String firstName;
  final String lastName;
  final String? avatar;
  final String? phoneNumber;
  final bool isOnline;
  final DateTime? lastSeen;
  final bool isVerified;

  UserModel({
    required this.id,
    required this.username,
    required this.email,
    this.firstName = '',
    this.lastName = '',
    this.avatar,
    this.phoneNumber,
    this.isOnline = false,
    this.lastSeen,
    this.isVerified = false,
  });

  String get displayName {
    if (firstName.isNotEmpty || lastName.isNotEmpty) {
      return '$firstName $lastName'.trim();
    }
    return username;
  }

  static String? _toAbsoluteUrl(String? url) {
    if (url == null || url.isEmpty || url == 'null') return null;
    if (url.startsWith('http')) return url;
    final baseUrl = AppConstants.baseUrl;
    final uri = Uri.parse(baseUrl);
    final domainOnly = '${uri.scheme}://${uri.host}${uri.port != 80 && uri.port != 443 ? ':${uri.port}' : ''}';
    return '$domainOnly$url';
  }

  String get initials {
    final name = displayName;
    final parts = name.split(' ');
    if (parts.length >= 2) {
      final a = parts[0][0];
      final b = parts[1][0];
      return '$a$b'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: json['id'] ?? 0,
      username: json['username'] ?? '',
      email: json['email'] ?? '',
      firstName: json['first_name'] ?? '',
      lastName: json['last_name'] ?? '',
      avatar: _toAbsoluteUrl(json['avatar']?.toString()),
      phoneNumber: json['phone_number'],
      isOnline: json['is_online'] ?? false,
      lastSeen: json['last_seen'] != null
          ? DateTime.tryParse(json['last_seen'].toString())
          : null,
      isVerified: json['is_verified'] ?? false,
    );
  }
}
