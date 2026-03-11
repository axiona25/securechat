import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

class SoundService {
  static final SoundService _instance = SoundService._internal();
  factory SoundService() => _instance;
  SoundService._internal();

  /// Suono + vibrazione per messaggio ricevuto
  Future<void> playMessageReceived() async {
    await HapticFeedback.mediumImpact();
    await _playCustomSound();
  }

  /// Suono leggero per messaggio inviato
  Future<void> playMessageSent() async {
    await HapticFeedback.lightImpact();
  }

  /// Suono per notifica toast in home
  Future<void> playNotification() async {
    await HapticFeedback.heavyImpact();
    await _playCustomSound();
  }

  /// Vibrazione semplice per azioni (tap, reaction, etc)
  Future<void> playTap() async {
    await HapticFeedback.selectionClick();
  }

  Future<void> _playCustomSound() async {
    AudioPlayer? player;
    try {
      player = AudioPlayer();
      await player.setAsset('assets/sounds/notification.wav');
      await player.setVolume(0.7);
      await player.play();
      // Dispose after playback completes
      player.playerStateStream.listen((state) {
        if (state.processingState == ProcessingState.completed) {
          player?.dispose();
        }
      });
    } catch (e) {
      player?.dispose();
    }
  }
}
