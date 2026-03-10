import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Singleton service for call sounds: ringback, ringtone, busy, end.
class CallSoundService {
  static final CallSoundService _instance = CallSoundService._();
  factory CallSoundService() => _instance;
  CallSoundService._();

  AudioPlayer? _ringbackPlayer;
  AudioPlayer? _ringtonePlayer;
  AudioPlayer? _busyPlayer;
  AudioPlayer? _endPlayer;

  /// Ringback tone (caller hears tu...tu...tu)
  Future<void> playRingback() async {
    await stopAll();
    _ringbackPlayer = AudioPlayer();
    try {
      await _ringbackPlayer!.setAsset('assets/sounds/ringback.wav');
      await _ringbackPlayer!.setLoopMode(LoopMode.all);
      await _ringbackPlayer!.setVolume(0.5);
      await _ringbackPlayer!.play();
    } catch (e) {
      debugPrint('[CallSound] Error playing ringback: $e');
    }
  }

  /// Ringtone (callee hears the ring)
  Future<void> playRingtone() async {
    await stopAll();
    _ringtonePlayer = AudioPlayer();
    try {
      await _ringtonePlayer!.setAsset('assets/sounds/ringtone.wav');
      await _ringtonePlayer!.setLoopMode(LoopMode.all);
      await _ringtonePlayer!.setVolume(0.8);
      await _ringtonePlayer!.play();
    } catch (e) {
      debugPrint('[CallSound] Error playing ringtone: $e');
    }
  }

  /// Busy tone (fast tu-tu-tu)
  Future<void> playBusy() async {
    await stopAll();
    _busyPlayer = AudioPlayer();
    try {
      await _busyPlayer!.setAsset('assets/sounds/busy.wav');
      await _busyPlayer!.setLoopMode(LoopMode.off);
      await _busyPlayer!.setVolume(0.6);
      await _busyPlayer!.play();
      Future.delayed(const Duration(seconds: 3), () {
        _busyPlayer?.stop();
        _busyPlayer?.dispose();
        _busyPlayer = null;
      });
    } catch (e) {
      debugPrint('[CallSound] Error playing busy: $e');
    }
  }

  /// Short beep when call ends
  Future<void> playEnd() async {
    await stopAll();
    _endPlayer = AudioPlayer();
    try {
      await _endPlayer!.setAsset('assets/sounds/end.wav');
      await _endPlayer!.setLoopMode(LoopMode.off);
      await _endPlayer!.setVolume(0.5);
      await _endPlayer!.play();
      _endPlayer!.playerStateStream.listen((state) {
        if (state.processingState == ProcessingState.completed) {
          _endPlayer?.dispose();
          _endPlayer = null;
        }
      });
    } catch (e) {
      debugPrint('[CallSound] Error playing end: $e');
    }
  }

  /// Stop all call sounds
  Future<void> stopAll() async {
    try {
      await _ringbackPlayer?.stop();
      _ringbackPlayer?.dispose();
      _ringbackPlayer = null;
    } catch (_) {}
    try {
      await _ringtonePlayer?.stop();
      _ringtonePlayer?.dispose();
      _ringtonePlayer = null;
    } catch (_) {}
    try {
      await _busyPlayer?.stop();
      _busyPlayer?.dispose();
      _busyPlayer = null;
    } catch (_) {}
    try {
      await _endPlayer?.stop();
      _endPlayer?.dispose();
      _endPlayer = null;
    } catch (_) {}
  }
}
