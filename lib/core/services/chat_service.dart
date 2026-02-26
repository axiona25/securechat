import 'dart:io';

import '../models/conversation_model.dart';
import '../models/user_model.dart';
import 'api_service.dart';

class ChatService {
  static final ChatService _instance = ChatService._internal();
  factory ChatService() => _instance;
  ChatService._internal();

  final ApiService _api = ApiService();

  /// GET /api/chat/conversations/ — il backend restituisce una lista JSON diretta [{...}, {...}].
  Future<List<ConversationModel>> getConversations() async {
    try {
      final list = await _api.getList('/chat/conversations/');
      return list
          .map((e) => ConversationModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } on ApiException {
      return [];
    } catch (e) {
      return [];
    }
  }

  /// Get a single conversation by id.
  Future<ConversationModel?> getConversation(String id) async {
    try {
      final data = await _api.get('/chat/conversations/$id/');
      return ConversationModel.fromJson(data as Map<String, dynamic>);
    } on ApiException {
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<UserModel?> getCurrentUser() async {
    try {
      final data = await _api.get('/auth/profile/');
      return UserModel.fromJson(data);
    } catch (e) {
      return null;
    }
  }

  Future<int> getNotificationBadgeCount() async {
    try {
      final data = await _api.get('/notifications/badge/');
      return data['unread_count'] ?? data['count'] ?? 0;
    } catch (e) {
      return 0;
    }
  }

  /// Lookup user by email for starting a chat. Returns null if not found or self.
  Future<Map<String, dynamic>?> lookupUserByEmail(String email) async {
    try {
      final data = await _api.get(
        '/auth/users/lookup/',
        queryParams: {'email': email.trim().toLowerCase()},
      );
      return data;
    } on ApiException catch (e) {
      if (e.statusCode == 404 || e.statusCode == 400) return null;
      rethrow;
    }
  }

  /// Search users by email, first_name, last_name, username. Empty query returns all users (excl. current). Returns list of {id, email, first_name, last_name, username, avatar_url}.
  Future<List<Map<String, dynamic>>> searchUsers(String query) async {
    try {
      final list = await _api.getList(
        '/auth/users/search/',
        queryParams: query.trim().isEmpty ? null : {'q': query.trim()},
      );
      return list
          .map((e) => e as Map<String, dynamic>)
          .toList();
    } on ApiException {
      return [];
    } catch (e) {
      return [];
    }
  }

  /// Create a private conversation with one other user. Returns conversation payload or null.
  Future<Map<String, dynamic>?> createPrivateConversation(int otherUserId) async {
    try {
      final data = await _api.post(
        '/chat/conversations/',
        body: {
          'participants': [otherUserId],
          'conv_type': 'private',
        },
      );
      return data as Map<String, dynamic>;
    } on ApiException {
      rethrow;
    }
  }

  /// Create a group conversation. Returns conversation payload or null.
  Future<Map<String, dynamic>?> createGroupConversation(
    List<int> participantIds, {
    required String name,
    String? description,
  }) async {
    try {
      final body = <String, dynamic>{
        'participants': participantIds,
        'conv_type': 'group',
        'name': name,
      };
      if (description != null && description.isNotEmpty) {
        body['description'] = description;
      }
      final data = await _api.post('/chat/conversations/', body: body);
      return data as Map<String, dynamic>;
    } on ApiException {
      rethrow;
    }
  }

  /// Create a broadcast list. Returns conversation payload or null.
  Future<Map<String, dynamic>?> createBroadcastConversation(
    List<int> participantIds, {
    required String name,
  }) async {
    try {
      final data = await _api.post(
        '/chat/conversations/',
        body: {
          'participants': participantIds,
          'conv_type': 'broadcast',
          'name': name,
        },
      );
      return data as Map<String, dynamic>;
    } on ApiException {
      rethrow;
    }
  }

  /// Get messages for a conversation (paginated: extracts results from response).
  Future<List<Map<String, dynamic>>> getMessages(String conversationId) async {
    try {
      final response = await _api.get(
        '/chat/conversations/$conversationId/messages/',
      );
      if (response is! Map<String, dynamic>) return [];
      final results = response['results'];
      if (results is List) {
        return results.map((e) => e as Map<String, dynamic>).toList();
      }
      return [];
    } on ApiException {
      return [];
    } catch (e) {
      return [];
    }
  }

  /// Upload file to /api/media/upload/. Returns url or id string for message content, or null.
  Future<String?> uploadMedia(File file) async {
    try {
      final data = await _api.uploadFile(file);
      return data['url']?.toString() ??
          data['id']?.toString() ??
          data['file_url']?.toString() ??
          data['media_url']?.toString();
    } on ApiException {
      rethrow;
    }
  }

  /// Send a text message. Returns the created message payload.
  Future<Map<String, dynamic>?> sendMessage(
    String conversationId, {
    required String content,
    String messageType = 'text',
  }) async {
    try {
      final data = await _api.post(
        '/chat/conversations/$conversationId/messages/',
        body: {'content': content, 'message_type': messageType},
      );
      return data as Map<String, dynamic>;
    } on ApiException {
      rethrow;
    }
  }
}
