import 'dart:async';
import 'dart:io';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'permission_service.dart';

enum RecordingState { idle, recording, paused }

class AudioService {
  static final AudioService _instance = AudioService._internal();
  factory AudioService() => _instance;
  AudioService._internal();

  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  RecordingState _state = RecordingState.idle;
  RecordingState get state => _state;

  DateTime? _recordingStartTime;
  Timer? _durationTimer;
  Duration _currentDuration = Duration.zero;

  final StreamController<Duration> _durationController =
      StreamController<Duration>.broadcast();
  Stream<Duration> get durationStream => _durationController.stream;

  final StreamController<RecordingState> _stateController =
      StreamController<RecordingState>.broadcast();
  Stream<RecordingState> get stateStream => _stateController.stream;

  final StreamController<Duration> _playbackPositionController =
      StreamController<Duration>.broadcast();
  Stream<Duration> get playbackPositionStream =>
      _playbackPositionController.stream;

  Duration? _playbackDuration;
  Duration get playbackDuration => _playbackDuration ?? Duration.zero;

  bool _isPlaying = false;
  bool get isPlaying => _isPlaying;

  Future<bool> startRecording() async {
    final granted = await PermissionService.requestMicrophone();
    if (!granted) return false;

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) return false;

    final dir = await getTemporaryDirectory();
    final filePath = p.join(
      dir.path,
      'voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
    );

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
      ),
      path: filePath,
    );

    _state = RecordingState.recording;
    _stateController.add(_state);
    _recordingStartTime = DateTime.now();
    _currentDuration = Duration.zero;

    _durationTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_state == RecordingState.recording && _recordingStartTime != null) {
        _currentDuration = DateTime.now().difference(_recordingStartTime!);
        _durationController.add(_currentDuration);
      }
    });

    return true;
  }

  Future<File?> stopRecording() async {
    _durationTimer?.cancel();
    _durationTimer = null;

    if (_state != RecordingState.recording) return null;

    final path = await _recorder.stop();
    _state = RecordingState.idle;
    _stateController.add(_state);
    _recordingStartTime = null;

    if (path != null) {
      return File(path);
    }
    return null;
  }

  Future<void> cancelRecording() async {
    _durationTimer?.cancel();
    _durationTimer = null;

    if (_state == RecordingState.recording) {
      final path = await _recorder.stop();
      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }

    _state = RecordingState.idle;
    _stateController.add(_state);
    _recordingStartTime = null;
    _currentDuration = Duration.zero;
  }

  Duration get currentDuration => _currentDuration;

  Future<void> play(String source, {bool isUrl = false}) async {
    if (isUrl) {
      await _player.play(UrlSource(source));
    } else {
      await _player.play(DeviceFileSource(source));
    }

    _isPlaying = true;

    _player.onPositionChanged.listen((position) {
      _playbackPositionController.add(position);
    });

    _player.onDurationChanged.listen((duration) {
      _playbackDuration = duration;
    });

    _player.onPlayerComplete.listen((_) {
      _isPlaying = false;
    });
  }

  Future<void> pause() async {
    await _player.pause();
    _isPlaying = false;
  }

  Future<void> resume() async {
    await _player.resume();
    _isPlaying = true;
  }

  Future<void> stop() async {
    await _player.stop();
    _isPlaying = false;
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  void dispose() {
    _durationTimer?.cancel();
    _durationController.close();
    _stateController.close();
    _playbackPositionController.close();
    _recorder.dispose();
    _player.dispose();
  }
}
