import 'package:flutter/services.dart';

class SoundService {
  static final SoundService _instance = SoundService._internal();
  factory SoundService() => _instance;
  SoundService._internal();

  /// Suono + vibrazione per messaggio ricevuto
  Future<void> playMessageReceived() async {
    await HapticFeedback.mediumImpact();
    await SystemSound.play(SystemSoundType.alert);
  }

  /// Suono leggero per messaggio inviato
  Future<void> playMessageSent() async {
    await HapticFeedback.lightImpact();
  }

  /// Suono per notifica toast in home
  Future<void> playNotification() async {
    await HapticFeedback.heavyImpact();
    await SystemSound.play(SystemSoundType.alert);
  }

  /// Vibrazione semplice per azioni (tap, reaction, etc)
  Future<void> playTap() async {
    await HapticFeedback.selectionClick();
  }
}
