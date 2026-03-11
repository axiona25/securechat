import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Servizio centralizzato per suoni chat: solo ricezione (notification.wav). Invio senza suono.
/// Evita doppi trigger e suoni per messaggi propri (echo).
class ChatSoundService {
  static final ChatSoundService _instance = ChatSoundService._internal();
  factory ChatSoundService() => _instance;
  ChatSoundService._internal();

  static const int _maxPlayedIds = 100;
  final Set<String> _playedIncomingIds = {};

  /// Unico asset per ricezione messaggi.
  static const String _assetIncoming = 'assets/sounds/notification.wav';

  /// Nuovo messaggio ricevuto (da altro utente): suona sempre notification.wav.
  /// Deduplica per messageId, salta echo propri messaggi.
  void tryPlayIncoming({
    required String? messageId,
    required int? senderId,
    required int? currentUserId,
  }) {
    if (messageId == null || messageId.isEmpty) return;
    if (senderId != null && currentUserId != null && senderId == currentUserId) {
      debugPrint('[ChatSound] skipped own message echo for message $messageId');
      return;
    }
    if (_playedIncomingIds.contains(messageId)) {
      debugPrint('[ChatSound] skipped duplicate for message $messageId');
      return;
    }
    _playedIncomingIds.add(messageId);
    _prunePlayedIds();
    _playAsset(_assetIncoming, volume: 0.7, label: 'incoming').then((_) {
      debugPrint('[ChatSound] incoming notification asset played for message $messageId');
    });
  }

  /// Invio messaggio: nessun suono (outgoing disabilitato).
  void playOutgoing({String? messageId}) {
    debugPrint('[ChatSound] outgoing disabled');
  }

  void _prunePlayedIds() {
    if (_playedIncomingIds.length > _maxPlayedIds) {
      final toRemove = _playedIncomingIds.length - _maxPlayedIds;
      final list = _playedIncomingIds.toList()..sort();
      for (var i = 0; i < toRemove && i < list.length; i++) {
        _playedIncomingIds.remove(list[i]);
      }
    }
  }

  Future<void> _playAsset(String path, {double volume = 0.7, String? label}) async {
    final assetLabel = label ?? path;
    AudioPlayer? player = AudioPlayer();
    try {
      await player.setAsset(path);
      await player.setVolume(volume);
      await player.play();
      player.playerStateStream.listen((state) {
        if (state.processingState == ProcessingState.completed) {
          player?.dispose();
        }
      });
    } catch (e) {
      player?.dispose();
      debugPrint('[ChatSound] play failed for $assetLabel: $e');
    }
  }
}
