import '../models/conversation_model.dart';

/// Singleton cache delle conversazioni caricate in home.
/// Permette ad altri servizi (es. VoipService) di leggere avatar e dati utente
/// senza dipendere direttamente da HomeScreen.
class ConversationCacheService {
  ConversationCacheService._();
  static final instance = ConversationCacheService._();

  List<ConversationModel> _conversations = [];

  void update(List<ConversationModel> conversations) {
    _conversations = List.from(conversations);
  }

  /// Restituisce l'URL avatar dell'utente con [userId], cercando nelle conversazioni.
  String? getAvatarForUser(int userId) {
    for (final conv in _conversations) {
      for (final p in conv.participants) {
        if (p.userId == userId) return p.avatar;
      }
    }
    return null;
  }

  /// Restituisce il nome display dell'utente con [userId].
  String? getNameForUser(int userId) {
    for (final conv in _conversations) {
      for (final p in conv.participants) {
        if (p.userId == userId) {
          final name = p.displayName.trim();
          return name.isNotEmpty ? name : p.username;
        }
      }
    }
    return null;
  }
}
