import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
  bool? _isSimulator;

  static const _nativeChannel = MethodChannel('com.axphone.app/sounds');

  Future<bool> get isSimulator async {
    if (_isSimulator != null) return _isSimulator!;
    try {
      _isSimulator = Platform.resolvedExecutable.contains('CoreSimulator');
    } catch (_) {
      _isSimulator = false;
    }
    return _isSimulator!;
  }

  /// Ringback tone (caller hears tu...tu...tu) — always custom
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

  /// Ringtone (callee hears the ring) — always uses assets/sounds/ringtone.wav
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
    // Stop native ringtone if it was started elsewhere (e.g. CallKit)
    try { await _nativeChannel.invokeMethod('stopSystemRingtone'); } catch (_) {}
  }

  /// Busy tone (fast tu-tu-tu) — always custom
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

  /// Short beep when call ends — always custom
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
    // Capture references and null them immediately
    final rt = _ringtonePlayer;
    final rb = _ringbackPlayer;
    final bp = _busyPlayer;
    final ep = _endPlayer;
    _ringtonePlayer = null;
    _ringbackPlayer = null;
    _busyPlayer = null;
    _endPlayer = null;

    // Stop playback
    try { await rt?.stop(); } catch (_) {}
    try { await rb?.stop(); } catch (_) {}
    try { await bp?.stop(); } catch (_) {}
    try { await ep?.stop(); } catch (_) {}

    // Stop native ringtone
    try { await _nativeChannel.invokeMethod('stopSystemRingtone'); } catch (_) {}

    // Dispose after a short delay to avoid audio session conflicts
    Future.delayed(const Duration(milliseconds: 300), () {
      try { rt?.dispose(); } catch (_) {}
      try { rb?.dispose(); } catch (_) {}
      try { bp?.dispose(); } catch (_) {}
      try { ep?.dispose(); } catch (_) {}
    });
  }
}
