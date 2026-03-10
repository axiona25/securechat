import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../constants/app_constants.dart';
import 'api_service.dart';
import 'call_sound_service.dart';

enum CallStatus { idle, ringing, connecting, connected, ended }

class CallState {
  final CallStatus status;
  final String? callId;
  final String? callType;
  final bool isMuted;
  final bool isVideoOff;
  final bool isSpeakerOn;
  final bool isIncoming;
  final int? remoteUserId;
  final String? remoteUserName;
  final String? remoteUserAvatar;
  final String? conversationId;
  final MediaStream? localStream;
  final MediaStream? remoteStream;
  final Duration? duration;

  const CallState({
    required this.status,
    this.callId,
    this.callType,
    this.isMuted = false,
    this.isVideoOff = false,
    this.isSpeakerOn = true,
    this.isIncoming = false,
    this.remoteUserId,
    this.remoteUserName,
    this.remoteUserAvatar,
    this.conversationId,
    this.localStream,
    this.remoteStream,
    this.duration,
  });

  CallState copyWith({
    CallStatus? status,
    String? callId,
    String? callType,
    bool? isMuted,
    bool? isVideoOff,
    bool? isSpeakerOn,
    bool? isIncoming,
    int? remoteUserId,
    String? remoteUserName,
    String? remoteUserAvatar,
    String? conversationId,
    MediaStream? localStream,
    MediaStream? remoteStream,
    Duration? duration,
  }) {
    return CallState(
      status: status ?? this.status,
      callId: callId ?? this.callId,
      callType: callType ?? this.callType,
      isMuted: isMuted ?? this.isMuted,
      isVideoOff: isVideoOff ?? this.isVideoOff,
      isSpeakerOn: isSpeakerOn ?? this.isSpeakerOn,
      isIncoming: isIncoming ?? this.isIncoming,
      remoteUserId: remoteUserId ?? this.remoteUserId,
      remoteUserName: remoteUserName ?? this.remoteUserName,
      remoteUserAvatar: remoteUserAvatar ?? this.remoteUserAvatar,
      conversationId: conversationId ?? this.conversationId,
      localStream: localStream ?? this.localStream,
      remoteStream: remoteStream ?? this.remoteStream,
      duration: duration ?? this.duration,
    );
  }
}

/// Singleton service for WebRTC calls: WebSocket signaling and peer connection.
class CallService {
  static final CallService _instance = CallService._internal();
  factory CallService() => _instance;
  CallService._internal();

  final ApiService _api = ApiService();
  WebSocket? _channel;
  final StreamController<CallState> _stateController =
      StreamController<CallState>.broadcast();
  final StreamController<CallState> _incomingCallController =
      StreamController<CallState>.broadcast();

  CallState _state = const CallState(status: CallStatus.idle);
  String? _callId;
  String? _callType;
  int? _remoteUserId;
  List<Map<String, dynamic>>? _iceServers;
  RTCPeerConnection? _peerConnection;
  DateTime? _callStartTime;
  StreamSubscription? _wsSubscription;
  bool _disposed = false;
  bool _isConnected = false;

  Stream<CallState> get stateStream => _stateController.stream;
  Stream<CallState> get onIncomingCall => _incomingCallController.stream;
  CallState get state => _state;

  String get _wsCallsUrl {
    final token = _api.accessToken;
    if (token == null || token.isEmpty) return '';
    final base = Uri.parse(AppConstants.wsCallsUrl);
    return '${base.scheme}://${base.host}:${base.port}${base.path}?token=${Uri.encodeComponent(token)}';
  }

  /// Ensures WebSocket is connected (e.g. when Home loads to receive incoming calls).
  Future<void> ensureConnected() async {
    if (_channel != null && _isConnected) return;
    if (_disposed) return;

    if (_channel != null) {
      try {
        _channel!.close();
      } catch (_) {}
      _channel = null;
      _isConnected = false;
      _wsSubscription?.cancel();
      _wsSubscription = null;
    }

    final url = _wsCallsUrl;
    if (url.isEmpty) return;
    try {
      _channel = await WebSocket.connect(url);
      _wsSubscription = _channel!.listen(
        _onMessage,
        onError: (e) {
          debugPrint('[CallService] WebSocket error: $e');
          _closeChannel();
          _scheduleReconnect();
        },
        onDone: () {
          _isConnected = false;
          _channel = null;
          _wsSubscription = null;
          debugPrint('[CallService] WebSocket closed, will try to reconnect');
          _scheduleReconnect();
        },
        cancelOnError: false,
      );
      _isConnected = true;
      debugPrint('[CallService] WebSocket connected');
    } catch (e) {
      debugPrint('[CallService] WebSocket connect error: $e');
    }
  }

  void _closeChannel() {
    _wsSubscription?.cancel();
    _wsSubscription = null;
    _channel?.close();
    _channel = null;
    _isConnected = false;
  }

  static bool _reconnectScheduled = false;

  void _scheduleReconnect() {
    if (_disposed || _reconnectScheduled) return;
    _reconnectScheduled = true;
    Future.delayed(const Duration(seconds: 2), () {
      _reconnectScheduled = false;
      if (_disposed) return;
      debugPrint('[CallService] Reconnecting WebSocket...');
      ensureConnected();
    });
  }

  Future<void> _send(Map<String, dynamic> data) async {
    if (_channel == null || !_isConnected) {
      debugPrint('[CallService] WebSocket not connected, reconnecting...');
      await ensureConnected();
    }
    if (_channel == null || !_isConnected) {
      debugPrint('[CallService] ERROR: Cannot send, WebSocket still not connected');
      return;
    }
    try {
      final encoded = jsonEncode(data);
      debugPrint('[CallService] Sending: $encoded');
      _channel!.add(encoded);
    } catch (e) {
      debugPrint('[CallService] Send error: $e');
      _isConnected = false;
      _channel = null;
    }
  }

  void _emit(CallState s) {
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  void _onMessage(dynamic raw) {
    if (raw is! List<int> && raw is! String) return;
    String text;
    if (raw is List<int>) {
      text = utf8.decode(raw);
    } else {
      text = raw as String;
    }
    try {
      final map = jsonDecode(text) as Map<String, dynamic>;
      final type = map['type'] as String?;
      switch (type) {
        case 'call.incoming':
          _onCallIncoming(map);
          break;
        case 'call.initiated':
          _onCallInitiated(map);
          break;
        case 'call.accepted':
          _onCallAccepted(map);
          break;
        case 'call.rejected':
          _onCallRejected(map);
          break;
        case 'call.offer':
          _onCallOffer(map);
          break;
        case 'call.answer':
          _onCallAnswer(map);
          break;
        case 'call.ice_candidate':
          _onCallIceCandidate(map);
          break;
        case 'call.ended':
          _onCallEnded(map);
          break;
        case 'call.participant_update':
          _onParticipantUpdate(map);
          break;
        default:
          if (map.containsKey('error')) {
            debugPrint('[CallService] error: ${map['error']}');
            _emit(_state.copyWith(status: CallStatus.ended));
          }
      }
    } catch (e) {
      debugPrint('[CallService] parse error: $e');
    }
  }

  void _onCallIncoming(Map<String, dynamic> map) {
    debugPrint('[CallService] call.incoming received: callId=${map['call_id']}, from=${map['caller_name']}');
    final callId = map['call_id']?.toString();
    final callType = map['call_type']?.toString() ?? 'audio';
    final callerId = map['caller_id'];
    final conversationId = map['conversation_id']?.toString();
    int? remoteId;
    if (callerId != null) {
      remoteId = callerId is int ? callerId : int.tryParse(callerId.toString());
    }
    String? avatar = map['caller_avatar']?.toString();
    if (avatar != null &&
        avatar.isNotEmpty &&
        !avatar.startsWith('http')) {
      avatar = '${AppConstants.mediaBaseUrl}$avatar';
    }
    final name = map['caller_name']?.toString() ?? '';
    final state = CallState(
      status: CallStatus.ringing,
      callId: callId,
      callType: callType,
      isIncoming: true,
      remoteUserId: remoteId,
      remoteUserName: name,
      remoteUserAvatar: avatar,
      conversationId: conversationId,
    );
    _callId = callId;
    _callType = callType;
    _remoteUserId = remoteId;
    _emit(state);
    if (!_incomingCallController.isClosed) {
      _incomingCallController.add(state);
    }
  }

  void _onCallInitiated(Map<String, dynamic> map) {
    final callId = map['call_id']?.toString();
    final callType = map['call_type']?.toString() ?? 'audio';
    final ice = map['ice_servers'];
    if (ice is List) {
      _iceServers = List<Map<String, dynamic>>.from(
        ice.map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{}),
      );
    }
    _callId = callId;
    _callType = callType;
    _emit(_state.copyWith(
      status: CallStatus.ringing,
      callId: callId,
      callType: callType,
      isIncoming: false,
    ));
  }

  Future<void> _onCallAccepted(Map<String, dynamic> map) async {
    final callId = map['call_id']?.toString();
    final acceptedBy = map['accepted_by'];
    final ice = map['ice_servers'];
    if (ice is List) {
      _iceServers = List<Map<String, dynamic>>.from(
        ice.map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{}),
      );
    }
    int? acceptedById;
    if (acceptedBy != null) {
      acceptedById = acceptedBy is int ? acceptedBy : int.tryParse(acceptedBy.toString());
    }
    if (_remoteUserId == null && acceptedById != null) {
      _remoteUserId = acceptedById;
    }
    _emit(_state.copyWith(status: CallStatus.connecting));
    await _createPeerConnection();
    if (_peerConnection == null) return;
    if (_state.isIncoming) {
      await _getUserMedia();
    } else {
      await _getUserMedia();
      if (_state.localStream == null) return;
      final offer = await _peerConnection!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': _callType == 'video',
      });
      await _peerConnection!.setLocalDescription(offer);
      _send({
        'action': 'offer',
        'call_id': callId,
        'target_user_id': _remoteUserId,
        'sdp': offer.toMap(),
      });
    }
  }

  void _onCallRejected(Map<String, dynamic> map) {
    final reason = map['reason']?.toString();
    if (reason == 'busy') {
      CallSoundService().playBusy();
    }
    _emit(_state.copyWith(status: CallStatus.ended));
    _cleanup();
  }

  Future<void> _onCallOffer(Map<String, dynamic> map) async {
    final sdpMap = map['sdp'];
    if (sdpMap is! Map) return;
    await _createPeerConnection();
    if (_peerConnection == null) return;
    final desc = RTCSessionDescription(
      sdpMap['sdp'] as String? ?? '',
      sdpMap['type'] as String? ?? 'offer',
    );
    await _peerConnection!.setRemoteDescription(desc);
    await _getUserMedia();
    if (_state.localStream == null) return;
    final answer = await _peerConnection!.createAnswer({});
    await _peerConnection!.setLocalDescription(answer);
    _send({
      'action': 'answer',
      'call_id': _callId,
      'target_user_id': _remoteUserId,
      'sdp': answer.toMap(),
    });
  }

  Future<void> _onCallAnswer(Map<String, dynamic> map) async {
    final sdpMap = map['sdp'];
    if (sdpMap is! Map) return;
    if (_peerConnection == null) return;
    final desc = RTCSessionDescription(
      sdpMap['sdp'] as String? ?? '',
      sdpMap['type'] as String? ?? 'answer',
    );
    await _peerConnection!.setRemoteDescription(desc);
  }

  Future<void> _onCallIceCandidate(Map<String, dynamic> map) async {
    final cand = map['candidate'];
    if (cand is! Map || _peerConnection == null) return;
    try {
      final c = RTCIceCandidate(
        cand['candidate'] as String? ?? '',
        cand['sdpMid'] as String? ?? '',
        cand['sdpMLineIndex'] as int? ?? 0,
      );
      await _peerConnection!.addCandidate(c);
    } catch (e) {
      debugPrint('[CallService] addCandidate error: $e');
    }
  }

  void _onCallEnded(Map<String, dynamic> map) {
    debugPrint('[CallService] call.ended received: callId=${map['call_id']}');
    final duration = map['duration'];
    int sec = 0;
    if (duration != null) {
      if (duration is int) {
        sec = duration;
      } else if (duration is num) {
        sec = duration.toInt();
      }
    }
    _emit(_state.copyWith(
      status: CallStatus.ended,
      duration: Duration(seconds: sec),
    ));
    _cleanup();
  }

  void _onParticipantUpdate(Map<String, dynamic> map) {
    // Optional: update UI for remote mute/video (e.g. show icon)
  }

  Future<void> _createPeerConnection() async {
    if (_peerConnection != null) return;
    final config = <String, dynamic>{
      'iceServers': _iceServers ?? [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
      ],
    };
    final constraints = <String, dynamic>{
      'mandatory': {},
      'optional': [
        {'DtlsSrtpKeyAgreement': true},
      ],
    };
    try {
      _peerConnection = await createPeerConnection(config, constraints);
      _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        if (_callId == null || _remoteUserId == null) return;
        _send({
          'action': 'ice_candidate',
          'call_id': _callId,
          'target_user_id': _remoteUserId,
          'candidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        });
      };
      _peerConnection!.onAddStream = (MediaStream stream) {
        _emit(_state.copyWith(remoteStream: stream, status: CallStatus.connected));
        _callStartTime ??= DateTime.now();
      };
      _peerConnection!.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty) {
          _emit(_state.copyWith(
            remoteStream: event.streams.first,
            status: CallStatus.connected,
          ));
          _callStartTime ??= DateTime.now();
        }
      };
      _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
        if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
            state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
          // Connection lost
        }
      };
    } catch (e) {
      debugPrint('[CallService] createPeerConnection error: $e');
    }
  }

  Future<void> _getUserMedia() async {
    if (_state.localStream != null) return;
    final audio = true;
    final video = _callType == 'video';
    try {
      // ignore: deprecated_member_use — navigator.mediaDevices from factory not used to keep API simple
      final stream = await MediaDevices.getUserMedia({
        'audio': audio,
        'video': video
            ? {
                'facingMode': 'user',
                'width': 640,
                'height': 480,
              }
            : false,
      });
      _emit(_state.copyWith(localStream: stream));
      if (_peerConnection != null) {
        stream.getTracks().forEach((track) {
          _peerConnection!.addTrack(track, stream);
        });
      }
    } catch (e) {
      debugPrint('[CallService] getUserMedia error: $e');
    }
  }

  void _cleanup() {
    final localStream = _state.localStream;
    final remoteStream = _state.remoteStream;
    _peerConnection?.close();
    _peerConnection = null;
    localStream?.getTracks().forEach((t) => t.stop());
    remoteStream?.getTracks().forEach((t) => t.stop());
    _emit(const CallState(status: CallStatus.idle));
    _callId = null;
    _callType = null;
    _remoteUserId = null;
    _iceServers = null;
    _callStartTime = null;
  }

  /// Start an outgoing call (1-to-1). Participants are derived from conversation on the backend.
  Future<void> initiateCall(String conversationId, String callType) async {
    debugPrint('[CallService] initiateCall: conversationId=$conversationId, callType=$callType');
    if (_state.status != CallStatus.idle) return;
    await ensureConnected();
    if (_channel == null || !_isConnected) {
      _emit(_state.copyWith(status: CallStatus.ended));
    } else {
      _callType = callType;
      _emit(_state.copyWith(
        status: CallStatus.connecting,
        callType: callType,
        isIncoming: false,
      ));
      await _send({
        'action': 'initiate_call',
        'conversation_id': conversationId,
        'call_type': callType,
      });
      debugPrint('[CallService] initiateCall: message sent');
    }
    return;
  }

  void acceptCall(String callId) {
    if (_callId != callId) return;
    _send({'action': 'accept_call', 'call_id': callId});
  }

  void rejectCall(String callId) {
    _send({'action': 'reject_call', 'call_id': callId});
    _emit(_state.copyWith(status: CallStatus.ended));
    _cleanup();
  }

  Future<void> endCall() async {
    if (_callId == null) {
      _cleanup();
      return;
    }
    _send({'action': 'end_call', 'call_id': _callId});
    _cleanup();
    return;
  }

  void toggleMute() {
    final next = !_state.isMuted;
    _emit(_state.copyWith(isMuted: next));
    if (_callId != null) {
      _send({'action': 'toggle_mute', 'call_id': _callId, 'is_muted': next});
    }
    _state.localStream?.getAudioTracks().forEach((t) {
      t.enabled = !next;
    });
  }

  void toggleVideo() {
    final next = !_state.isVideoOff;
    _emit(_state.copyWith(isVideoOff: next));
    if (_callId != null) {
      _send({'action': 'toggle_video', 'call_id': _callId, 'is_video_off': next});
    }
    _state.localStream?.getVideoTracks().forEach((t) {
      t.enabled = !next;
    });
  }

  void toggleSpeaker() {
    final next = !_state.isSpeakerOn;
    _emit(_state.copyWith(isSpeakerOn: next));
    if (_callId != null) {
      _send({'action': 'toggle_speaker', 'call_id': _callId, 'is_speaker_on': next});
    }
    // Actual speaker routing is device-dependent; UI can reflect the toggle.
  }

  /// Caller: set remote user id when we receive call.accepted (accepted_by).
  void setRemoteUserIdForCall(int userId) {
    _remoteUserId = userId;
  }

  /// Incoming call: set call context from call.incoming (caller_id, conversation_id, etc.).
  void setIncomingCallContext({
    required String callId,
    required String callType,
    required int remoteUserId,
    String? remoteUserName,
    String? remoteUserAvatar,
    String? conversationId,
  }) {
    _callId = callId;
    _callType = callType;
    _remoteUserId = remoteUserId;
    _emit(_state.copyWith(
      callId: callId,
      callType: callType,
      remoteUserId: remoteUserId,
      remoteUserName: remoteUserName ?? _state.remoteUserName,
      remoteUserAvatar: remoteUserAvatar ?? _state.remoteUserAvatar,
      conversationId: conversationId ?? _state.conversationId,
    ));
  }

  Duration? get currentCallDuration {
    if (_callStartTime == null) return null;
    return DateTime.now().difference(_callStartTime!);
  }

  void dispose() {
    _disposed = true;
    _cleanup();
    _closeChannel();
    _stateController.close();
    _incomingCallController.close();
  }
}
