import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../constants/app_constants.dart';
import '../utils/call_id_utils.dart';
import 'api_service.dart';
import 'call_kit_bridge.dart';
import 'call_sound_service.dart';

enum CallStatus { idle, ringing, connecting, connected, ended, busy }

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
  final String? endReason;

  const CallState({
    required this.status,
    this.callId,
    this.callType,
    this.isMuted = false,
    this.isVideoOff = false,
    this.isSpeakerOn = false,
    this.isIncoming = false,
    this.remoteUserId,
    this.remoteUserName,
    this.remoteUserAvatar,
    this.conversationId,
    this.localStream,
    this.remoteStream,
    this.duration,
    this.endReason,
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
    String? endReason,
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
      endReason: endReason ?? this.endReason,
    );
  }
}

/// Singleton service for WebRTC calls: WebSocket signaling and peer connection.
class CallService {
  CallService._internal();

  static final CallService _instance = CallService._internal();
  factory CallService() => _instance;

  static const MethodChannel _iosVoipChannel = MethodChannel('com.axphone.app/voip');

  static String? _lastAcceptedCallId;

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
  MediaStream? _remoteStream;
  DateTime? _callStartTime;
  StreamSubscription? _wsSubscription;
  StreamSubscription? _connectivitySubscription;
  bool _disposed = false;
  bool _isConnected = false;
  bool _isConnecting = false;
  Completer<void>? _connectingCompleter;
  bool _isAccepting = false;
  bool _isCreatingPeerConnection = false;
  final Set<String> _processedEventKeys = {};
  bool _speakerDefaultApplied = false;
  bool _isEnded = false;
  Timer? _speakerTimer;
  Timer? _wsPingTimer;
  /// WS `accept_call` already sent from native CallKit path (idempotent per callId).
  final Set<String> _nativeAcceptWsSent = {};
  /// ICE candidates ricevuti prima di setRemoteDescription; flush dopo offer/answer.
  final List<RTCIceCandidate> _pendingIceCandidates = [];
  /// iOS debug: forza speaker + snapshot route una sola volta per callId.
  final Set<String> _iosSpeakerForcedCallIds = {};
  /// iOS: toggle RTCAudioSession.isAudioEnabled una sola volta per callId (dopo track + Connected).
  final Set<String> _iosAudioRetriggerCallIds = {};

  Stream<CallState> get stateStream => _stateController.stream;
  Stream<CallState> get onIncomingCall => _incomingCallController.stream;
  CallState get state => _state;
  bool get isEnded => _isEnded;

  String get _wsCallsUrl {
    final token = _api.accessToken;
    if (token == null || token.isEmpty) return '';
    final base = Uri.parse(AppConstants.wsCallsUrl);
    return '${base.scheme}://${base.host}:${base.port}${base.path}?token=${Uri.encodeComponent(token)}';
  }

  /// Ensures WebSocket is connected (e.g. when Home loads to receive incoming calls).
  Future<void> ensureConnected() async {
    _remoteLog('[CallService.ensureConnected] called, isConnected=$_isConnected channel=${_channel != null} isConnecting=$_isConnecting');
    if (_channel != null && _isConnected) return;
    if (_disposed) return;
    if (_isConnecting) {
      // Aspetta che la connessione in corso sia completata
      await _connectingCompleter?.future;
      return;
    }
    _isConnecting = true;
    _connectingCompleter = Completer<void>();
    try {
      if (_channel != null) {
        _wsPingTimer?.cancel();
        _wsPingTimer = null;
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
        _remoteLog('[CallService.ensureConnected] WebSocket opened successfully');
        _wsPingTimer?.cancel();
        _wsPingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
          try {
            _channel?.add(jsonEncode({'action': 'ping'}));
          } catch (_) {}
        });
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
    } finally {
      _isConnecting = false;
      _connectingCompleter?.complete();
      _connectingCompleter = null;
    }
  }

  void _closeChannel() {
    _wsPingTimer?.cancel();
    _wsPingTimer = null;
    _wsSubscription?.cancel();
    _wsSubscription = null;
    _channel?.close();
    _channel = null;
    _isConnected = false;
  }

  void startNetworkMonitoring() {
    _connectivitySubscription?.cancel();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((results) {
      final hasNetwork = results.any((r) => r != ConnectivityResult.none);
      if (!hasNetwork) return;
      debugPrint('[CallService] Network changed — forcing WebSocket reconnect');
      _closeChannel();
      ensureConnected();

      // Se c'è una chiamata attiva, riavvia ICE per adattarsi alla nuova rete
      if (_peerConnection != null &&
          (_state.status == CallStatus.connected ||
           _state.status == CallStatus.connecting)) {
        debugPrint('[CallService] Active call detected — restarting ICE for new network');
        _restartIce();
      }
    });
  }

  Future<void> _restartIce() async {
    if (_peerConnection == null) return;
    try {
      if (!_state.isIncoming) {
        // Caller: crea nuova offer con iceRestart=true
        final offer = await _peerConnection!.createOffer({
          'offerToReceiveAudio': true,
          'offerToReceiveVideo': _callType == 'video',
          'iceRestart': true,
        });
        await _peerConnection!.setLocalDescription(offer);
        await _send({
          'action': 'offer',
          'call_id': _callId,
          'target_user_id': _remoteUserId,
          'sdp': offer.toMap(),
        });
        debugPrint('[CallService] ICE restart offer sent');
      }
      // Il receiver risponderà automaticamente con answer
    } catch (e) {
      debugPrint('[CallService] ICE restart failed: $e');
      // Fallback: termina e lascia all utente richiamare
    }
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
    final prev = _state.status;
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
    if (s.status == CallStatus.connected && prev != CallStatus.connected) {
      _remoteLog('[CallService] state transition -> connected callId=${s.callId}');
    }
    // iOS: mai setCallConnected — nel plugin invoca CXAnswerCallAction (error 2 / audio rotto).
    if (s.status == CallStatus.connected && _callId != null) {
      final callId = _callId!;
      Future.microtask(() async {
        try {
          if (!kIsWeb && Platform.isIOS) {
            debugPrint(
              '[CallKit-iOS] skip setCallConnected on iOS path context=_emit.connected callId=$callId',
            );
            return;
          }
          await FlutterCallkitIncoming.setCallConnected(callId);
        } catch (_) {}
      });
    }
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
      _remoteLog('[CallService._onMessage] type=${map['type']} callId=${map['call_id']}');
      // Dedup: ignora eventi già processati (es. dopo riconnessione WS)
      final callId = normalizeCallId(map['call_id']?.toString());
      final dedupKey = '${type}_$callId';
      if (callId.isNotEmpty && type != null &&
          type != 'call.ice_candidate' &&
          type != 'call.participant_update') {
        if (_processedEventKeys.contains(dedupKey)) {
          debugPrint('[CallService] Duplicate event ignored: $dedupKey');
          return;
        }
        _processedEventKeys.add(dedupKey);
        // Pulisci vecchi eventi dopo 30 secondi
        Future.delayed(const Duration(seconds: 30), () {
          _processedEventKeys.remove(dedupKey);
        });
      }
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
        case 'pong':
          // Risposta al ping heartbeat — ignorare silenziosamente
          break;
        default:
          if (map.containsKey('error')) {
            final errorMsg = map['error']?.toString() ?? '';
            debugPrint('[CallService] WS error message: $errorMsg');
            // Solo errori relativi a una chiamata attiva devono terminare la call.
            // Errori generici (es. "Unknown action: None" da ping) vanno ignorati.
            if (_callId != null && map['call_id'] != null) {
              debugPrint('[CallService] call-related error, ending call: $errorMsg');
              _emit(_state.copyWith(status: CallStatus.ended));
            }
          }
      }
    } catch (e) {
      debugPrint('[CallService] parse error: $e');
    }
  }

  CallStatus _incomingStatusWhenCallKitAlreadyAnswered() {
    if (_state.status == CallStatus.connected) return CallStatus.connected;
    if (_state.status == CallStatus.connecting) return CallStatus.connecting;
    return CallStatus.connecting;
  }

  void _onCallIncoming(Map<String, dynamic> map) {
    final callId = normalizeCallId(map['call_id']?.toString());
    _remoteLog('[CallService._onCallIncoming] callId=$callId from=${map['caller_name']}');
    debugPrint('[CallService] call.incoming received: callId=$callId, from=${map['caller_name']}');

    if (callId.isNotEmpty && CallKitBridge.instance.wasAnswered(callId)) {
      _remoteLog('[CallService._onCallIncoming] skip ringing+incoming stream, CallKit already answered callId=$callId');
      _applyIncomingPayload(
        map,
        status: _incomingStatusWhenCallKitAlreadyAnswered(),
        notifyIncomingController: false,
      );
      return;
    }

    _remoteLog('[CallService._onCallIncoming] standard WebSocket incoming callId=$callId');
    _applyIncomingPayload(
      map,
      status: CallStatus.ringing,
      notifyIncomingController: true,
    );
  }

  void _applyIncomingPayload(
    Map<String, dynamic> map, {
    required CallStatus status,
    required bool notifyIncomingController,
  }) {
    final n = normalizeCallId(map['call_id']?.toString());
    final callId = n.isEmpty ? null : n;
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
      status: status,
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
    if (notifyIncomingController && !_incomingCallController.isClosed) {
      _incomingCallController.add(state);
    }
  }

  void _onCallInitiated(Map<String, dynamic> map) {
    final n = normalizeCallId(map['call_id']?.toString());
    final callId = n.isEmpty ? null : n;
    final callType = map['call_type']?.toString() ?? 'audio';
    final ice = map['ice_servers'];
    if (ice is List) {
      _iceServers = List<Map<String, dynamic>>.from(
        ice.map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{}),
      );
    }
    _remoteLog('[CallService] iceServers: $_iceServers');
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
    final callId = normalizeCallId(map['call_id']?.toString());
    if (callId.isEmpty) {
      _remoteLog('[CallService._onCallAccepted] ignored empty call_id');
      return;
    }

    // Ignora duplicati per lo stesso callId
    if (callId == _lastAcceptedCallId) {
      _remoteLog('[CallService._onCallAccepted] ignored duplicate callId=$callId');
      return;
    }

    // Ignora se già in connecting/connected o peer connection esistente
    if (_state.status == CallStatus.connecting ||
        _state.status == CallStatus.connected ||
        _peerConnection != null ||
        _isAccepting) {
      _remoteLog('[CallService._onCallAccepted] ignored duplicate, status=${_state.status}');
      return;
    }

    // Registra callId e imposta stato connecting ATOMICAMENTE
    _lastAcceptedCallId = callId;
    _isAccepting = true;
    _emit(_state.copyWith(status: CallStatus.connecting));

    try {
      final acceptedBy = map['accepted_by'];
      final ice = map['ice_servers'];
      if (ice is List) {
        _iceServers = List<Map<String, dynamic>>.from(
          ice.map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{}),
        );
      }
      _remoteLog('[CallService] iceServers: $_iceServers');
      int? acceptedById;
      if (acceptedBy != null) {
        acceptedById = acceptedBy is int ? acceptedBy : int.tryParse(acceptedBy.toString());
      }
      if (_remoteUserId == null && acceptedById != null) {
        _remoteUserId = acceptedById;
      }
      // iOS CallKit-accepted: didActivateAudioSession già fa handoff a RTCAudioSession; evitare
      // riconfigurazione immediata da Dart per ridurre conflitti SessionCore / NSOSStatus.
      final isIosCallKitAccepted =
          !kIsWeb && Platform.isIOS && _nativeAcceptWsSent.contains(callId);
      if (isIosCallKitAccepted) {
        _remoteLog(
          '[CallService] skip _configureAudioSession on iOS CallKit-accepted path (handoff in didActivateAudioSession)',
        );
      } else {
        await _configureAudioSession();
      }
      await _createPeerConnection();
      if (_peerConnection == null) return;
      if (_state.isIncoming) {
        await _getUserMedia();
      } else {
        await _getUserMedia();
        if (_state.localStream == null) return;
        if (_peerConnection == null) return;
        final offer = await _peerConnection!.createOffer({
          'offerToReceiveAudio': true,
          'offerToReceiveVideo': _callType == 'video',
        });
        await _peerConnection!.setLocalDescription(offer);
        _debugPcState('_onCallAccepted outgoing after setLocalDescription before send offer', callId: callId);
        _send({
          'action': 'offer',
          'call_id': callId,
          'target_user_id': _remoteUserId,
          'sdp': offer.toMap(),
        });
        _debugPcState('_onCallAccepted outgoing after send offer', callId: callId);
      }
    } finally {
      _isAccepting = false;
    }
  }

  void _onCallRejected(Map<String, dynamic> map) {
    final reason = map['reason']?.toString();
    final message = map['message']?.toString();
    if (reason == 'busy') {
      CallSoundService().playBusy();
      _emit(_state.copyWith(status: CallStatus.busy));
    } else if (reason == 'unavailable') {
      _emit(_state.copyWith(
        status: CallStatus.ended,
        endReason: message ?? 'Utente non disponibile. Riprova più tardi.',
      ));
      _cleanup();
    } else {
      _emit(_state.copyWith(status: CallStatus.ended));
      _cleanup();
    }
  }

  Future<void> _onCallOffer(Map<String, dynamic> map) async {
    _remoteLog('[CallService._handleOffer] received offer');
    final sdpMap = map['sdp'];
    if (sdpMap is! Map) return;
    final callId = normalizeCallId(map['call_id']?.toString());
    if (!kIsWeb && Platform.isIOS) {
      debugPrint('[PC-IOS] _onCallOffer entry callId=$callId');
    }
    // iOS CallKit-accepted: audio already configured in didActivateAudioSession; avoid
    // reconfiguring in offer path to prevent SessionCore/NSOSStatus conflicts.
    final isIosCallKitAccepted =
        !kIsWeb && Platform.isIOS && callId.isNotEmpty && _nativeAcceptWsSent.contains(callId);
    if (isIosCallKitAccepted) {
      debugPrint('[CallService] skip _configureAudioSession in _onCallOffer on iOS CallKit-accepted path');
      _remoteLog('[CallService] skip _configureAudioSession in _onCallOffer on iOS CallKit-accepted path');
    } else {
      await _configureAudioSession();
    }
    await _createPeerConnection();
    if (_peerConnection == null) return;
    _debugPcState('_onCallOffer after createPeerConnection', callId: callId);
    final desc = RTCSessionDescription(
      sdpMap['sdp'] as String? ?? '',
      sdpMap['type'] as String? ?? 'offer',
    );
    await _peerConnection!.setRemoteDescription(desc);
    _debugPcState('_onCallOffer after setRemoteDescription', callId: callId);
    await _flushPendingIceCandidates();
    await _getUserMedia();
    if (_state.localStream == null) return;
    _debugPcState('_onCallOffer after getUserMedia before createAnswer', callId: callId);
    final answer = await _peerConnection!.createAnswer({});
    await _peerConnection!.setLocalDescription(answer);
    _debugPcState('_onCallOffer after setLocalDescription before send answer', callId: callId);
    _send({
      'action': 'answer',
      'call_id': _callId,
      'target_user_id': _remoteUserId,
      'sdp': answer.toMap(),
    });
    _debugPcState('_onCallOffer after send answer', callId: callId);
  }

  Future<void> _onCallAnswer(Map<String, dynamic> map) async {
    _remoteLog('[CallService._handleAnswer] received answer');
    if (!kIsWeb && Platform.isIOS) {
      debugPrint('[PC-IOS] _onCallAnswer entry callId=$_callId');
    }
    final sdpMap = map['sdp'];
    if (sdpMap is! Map) return;
    if (_peerConnection == null) return;
    final desc = RTCSessionDescription(
      sdpMap['sdp'] as String? ?? '',
      sdpMap['type'] as String? ?? 'answer',
    );
    await _peerConnection!.setRemoteDescription(desc);
    await _flushPendingIceCandidates();
    _debugPcState('_onCallAnswer after setRemoteDescription');
    // Richiedi audio session dopo che CallKit rilascia il controllo
    await Future.delayed(const Duration(milliseconds: 500));
    await _configureAudioSession();
    await Future.delayed(const Duration(milliseconds: 200));
    await _applySpeakerphoneOnIosLogged(
      false,
      context: '_onCallAnswer after reconfigure',
      callId: _callId,
    );
    _remoteLog('[CallService._handleAnswer] audio session reconfigured');
    // Log stato audio 2 secondi dopo connessione
    Future.delayed(const Duration(seconds: 2), () {
      final localAudio = _state.localStream?.getAudioTracks() ?? [];
      final remoteAudio = _state.remoteStream?.getAudioTracks() ?? [];
      _remoteLog('[CallService.audioState] localTracks=${localAudio.length} remoteTracks=${remoteAudio.length} localEnabled=${localAudio.map((t) => t.enabled).toList()} remoteEnabled=${remoteAudio.map((t) => t.enabled).toList()} isSpeaker=${_state.isSpeakerOn} status=${_state.status} remoteStream=${_state.remoteStream != null}');
    });
  }

  Future<void> _onCallIceCandidate(Map<String, dynamic> map) async {
    final cand = map['candidate'];
    if (cand is! Map || _peerConnection == null) return;
    final c = RTCIceCandidate(
      cand['candidate'] as String? ?? '',
      cand['sdpMid'] as String? ?? '',
      cand['sdpMLineIndex'] as int? ?? 0,
    );
    final remoteDesc = await _peerConnection!.getRemoteDescription();
    if (remoteDesc == null) {
      _pendingIceCandidates.add(c);
      _remoteLog('[CallService] queue remote ICE candidate: remoteDescription null callId=$_callId');
      return;
    }
    try {
      await _peerConnection!.addCandidate(c);
    } catch (e) {
      debugPrint('[CallService] addCandidate error: $e');
    }
  }

  Future<void> _flushPendingIceCandidates() async {
    if (_peerConnection == null || _pendingIceCandidates.isEmpty) return;
    final n = _pendingIceCandidates.length;
    final cid = _callId;
    for (final c in _pendingIceCandidates) {
      try {
        await _peerConnection!.addCandidate(c);
      } catch (e) {
        debugPrint('[CallService] flush addCandidate error: $e');
      }
    }
    _pendingIceCandidates.clear();
    _remoteLog('[CallService] flushing queued ICE candidates count=$n callId=$cid');
  }

  void _onCallEnded(Map<String, dynamic> map) {
    debugPrint('[CallService] call.ended received: callId=${map['call_id']}');
    final wsCallId = normalizeCallId(map['call_id']?.toString());
    if (wsCallId.isNotEmpty) {
      try {
        FlutterCallkitIncoming.endCall(wsCallId);
      } catch (_) {}
    } else if (_state.callId != null && _state.callId!.isNotEmpty) {
      try {
        FlutterCallkitIncoming.endCall(_state.callId!);
      } catch (_) {}
    }
    _isEnded = true;
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

  Future<void> _remoteLog(String msg) async {
    try {
      final line =
          msg.contains('[REMOTE-DEBUG]') ? msg : '[REMOTE-DEBUG] $msg';
      await _api.post('/encryption/debug/log/', body: {'message': line}, requiresAuth: true);
    } catch (_) {}
  }

  static const Set<String> _iosRtcAudioStatTypes = {
    'inbound-rtp',
    'outbound-rtp',
    'remote-inbound-rtp',
    'remote-outbound-rtp',
    'track',
    'media-source',
    'transport',
    'candidate-pair',
  };

  static const List<String> _iosRtcAudioStatValueKeys = [
    'kind',
    'mediaType',
    'ssrc',
    'packetsReceived',
    'bytesReceived',
    'packetsSent',
    'bytesSent',
    'packetsLost',
    'jitter',
    'jitterBufferDelay',
    'totalAudioEnergy',
    'audioLevel',
    'totalSamplesReceived',
    'concealedSamples',
    'insertedSamplesForDeceleration',
    'removedSamplesForAcceleration',
    'roundTripTime',
    'selectedCandidatePairId',
    'dtlsState',
    'iceRole',
    'candidateType',
    'localCandidateId',
    'remoteCandidateId',
    'state',
    'nominated',
    'writable',
    'readable',
    'selected',
  ];

  static dynamic _iosStatMapVal(Map<dynamic, dynamic> m, String key) {
    if (m.containsKey(key)) return m[key];
    for (final e in m.entries) {
      if (e.key?.toString() == key) return e.value;
    }
    return null;
  }

  static bool _iosStatsReportIsAudioRelevant(StatsReport r) {
    final t = r.type;
    if (!_iosRtcAudioStatTypes.contains(t)) return false;
    if (t == 'inbound-rtp' ||
        t == 'outbound-rtp' ||
        t == 'remote-inbound-rtp' ||
        t == 'remote-outbound-rtp') {
      final kind = _iosStatMapVal(r.values, 'kind')?.toString().toLowerCase() ?? '';
      final mediaType =
          _iosStatMapVal(r.values, 'mediaType')?.toString().toLowerCase() ?? '';
      final k = kind.isNotEmpty ? kind : mediaType;
      if (k == 'video') return false;
      return k.isEmpty || k == 'audio';
    }
    return true;
  }

  static String _iosShortStackTrace() =>
      StackTrace.current.toString().split('\n').take(6).join('\n');

  /// iOS-only: log every app path that changes speaker / audio route.
  static void logIosAudioRouteChange({
    required bool requestedSpeakerOn,
    required String context,
    String? callId,
  }) {
    if (kIsWeb || !Platform.isIOS) return;
    final cid = callId ?? '';
    debugPrint(
      '[AUDIO-ROUTE-IOS] requested=$requestedSpeakerOn callId=$cid context=$context stack:\n${_iosShortStackTrace()}',
    );
  }

  void _logIosAudioRoute({
    required bool requestedSpeakerOn,
    required String context,
    String? callId,
  }) {
    CallService.logIosAudioRouteChange(
      requestedSpeakerOn: requestedSpeakerOn,
      context: context,
      callId: callId ?? _callId ?? '',
    );
  }

  Future<void> _applySpeakerphoneOnIosLogged(
    bool on, {
    required String context,
    String? callId,
  }) async {
    if (!kIsWeb && Platform.isIOS) {
      _logIosAudioRoute(
        requestedSpeakerOn: on,
        context: context,
        callId: callId ?? _callId,
      );
    }
    await Helper.setSpeakerphoneOn(on);
  }

  void _debugAudioRtcStats(String context, {String? callId}) {
    if (kIsWeb || !Platform.isIOS) return;
    final pc = _peerConnection;
    if (pc == null) return;
    final cid = callId ?? _callId ?? '';
    unawaited(_runDebugAudioRtcStats(pc, cid, context));
  }

  Future<void> _runDebugAudioRtcStats(
    RTCPeerConnection pc,
    String cid,
    String context,
  ) async {
    if (_disposed || _peerConnection == null) return;
    try {
      final reports = await pc.getStats();
      for (final r in reports) {
        if (!_iosStatsReportIsAudioRelevant(r)) continue;
        final parts = <String>[];
        for (final k in _iosRtcAudioStatValueKeys) {
          final v = _iosStatMapVal(r.values, k);
          if (v != null) parts.add('$k=$v');
        }
        final extra = parts.isEmpty ? '' : ' ${parts.join(' ')}';
        debugPrint(
          '[RTC-AUDIO-IOS] callId=$cid context=$context type=${r.type} id=${r.id}$extra',
        );
      }
    } catch (e) {
      debugPrint('[RTC-AUDIO-IOS] callId=$cid context=$context getStats error=$e');
    }
  }

  void _debugLogAudioTracksSummary(String context, {String? callId}) {
    if (kIsWeb || !Platform.isIOS) return;
    final pc = _peerConnection;
    if (pc == null) return;
    final cid = callId ?? _callId ?? '';
    unawaited(_runDebugLogAudioTracksSummary(pc, cid, context));
  }

  Future<void> _runDebugLogAudioTracksSummary(
    RTCPeerConnection pc,
    String cid,
    String context,
  ) async {
    if (_disposed || _peerConnection == null) return;
    try {
      final senders = await pc.getSenders();
      final receivers = await pc.getReceivers();
      final localAudio = _state.localStream?.getAudioTracks() ?? [];
      final remoteAudio = _state.remoteStream?.getAudioTracks() ?? [];
      for (var i = 0; i < localAudio.length; i++) {
        final t = localAudio[i];
        debugPrint(
          '[RTC-AUDIO-IOS-TRACK] callId=$cid context=$context local[$i] id=${t.id} enabled=${t.enabled} muted=${t.muted}',
        );
      }
      for (var i = 0; i < remoteAudio.length; i++) {
        final t = remoteAudio[i];
        debugPrint(
          '[RTC-AUDIO-IOS-TRACK] callId=$cid context=$context remote[$i] id=${t.id} enabled=${t.enabled} muted=${t.muted}',
        );
      }
      for (var i = 0; i < senders.length; i++) {
        final s = senders[i];
        if (s.track != null && s.track!.kind != 'audio') continue;
        final has = s.track != null;
        final tid = s.track?.id;
        final en = s.track?.enabled;
        final mu = s.track?.muted;
        debugPrint(
          '[RTC-AUDIO-IOS-TRACK] callId=$cid context=$context sender[$i] track!=null=$has trackId=$tid enabled=$en muted=$mu',
        );
      }
      for (var i = 0; i < receivers.length; i++) {
        final r = receivers[i];
        if (r.track != null && r.track!.kind != 'audio') continue;
        final has = r.track != null;
        final tid = r.track?.id;
        final en = r.track?.enabled;
        final mu = r.track?.muted;
        debugPrint(
          '[RTC-AUDIO-IOS-TRACK] callId=$cid context=$context receiver[$i] track!=null=$has trackId=$tid enabled=$en muted=$mu',
        );
      }
    } catch (e) {
      debugPrint(
        '[RTC-AUDIO-IOS-TRACK] callId=$cid context=$context error=$e',
      );
    }
  }

  void _scheduleIosAudioRtcStatsAfterConnected() {
    if (kIsWeb || !Platform.isIOS) return;
    final cidSnap = _callId ?? '';
    if (cidSnap.isEmpty) return;
    void tick(String ctx) {
      if (_disposed || _peerConnection == null || _callId != cidSnap) return;
      _debugAudioRtcStats(ctx, callId: cidSnap);
      _debugLogAudioTracksSummary(ctx, callId: cidSnap);
    }

    tick('onConnectionState immediate');
    Future.delayed(const Duration(seconds: 1), () => tick('onConnectionState +1s'));
    Future.delayed(const Duration(seconds: 3), () => tick('onConnectionState +3s'));
  }

  /// iOS: prova route playout su speaker + snapshot nativo (debug; una volta per callId).
  Future<void> _forceSpeakerAfterConnectedForIosDebug({required String context}) async {
    if (kIsWeb || !Platform.isIOS) return;
    final cid = _callId;
    if (cid == null || cid.isEmpty) return;
    if (!_iosSpeakerForcedCallIds.add(cid)) {
      debugPrint(
        '[AUDIO-IOS] skip duplicate force speaker callId=$cid context=$context',
      );
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (_disposed) return;
    try {
      final forced = await _iosVoipChannel.invokeMethod<dynamic>(
        'forceSpeakerOnDebug',
      );
      debugPrint(
        '[AUDIO-IOS] force speaker ON context=$context callId=$cid (native forceSpeakerOnDebug)',
      );
      debugPrint(
        '[AUDIO-IOS] route snapshot after speaker ON context=$context data=$forced',
      );
      final outsStr = forced is Map ? '${forced['outputs']}' : '';
      if (outsStr.toLowerCase().contains('speaker')) {
        debugPrint(
          '[AUDIO-IOS] Route shows Speaker; if audio still silent, next suspect is '
          'flutter_webrtc playout / remote track (not CallKit route).',
        );
      }
    } catch (e, st) {
      debugPrint(
        '[AUDIO-IOS] forceSpeakerOnDebug FAILED context=$context callId=$cid error=$e',
      );
      debugPrint('[AUDIO-IOS] forceSpeakerOnDebug stack: $st');
      try {
        await _applySpeakerphoneOnIosLogged(
          true,
          context:
              '_forceSpeakerAfterConnectedForIosDebug fallback after native failure',
          callId: cid,
        );
        debugPrint(
          '[AUDIO-IOS] fallback Helper.setSpeakerphoneOn(true) after native failure',
        );
      } catch (e2) {
        debugPrint('[AUDIO-IOS] fallback Helper.setSpeakerphoneOn failed: $e2');
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (_disposed) return;
    try {
      final data = await _iosVoipChannel.invokeMethod<dynamic>(
        'getAudioRouteSnapshot',
      );
      debugPrint(
        '[AUDIO-IOS] route snapshot verify context=$context data=$data',
      );
    } catch (e) {
      debugPrint(
        '[AUDIO-IOS] route snapshot error context=$context callId=$cid $e',
      );
    }
    await _maybeRetriggerIosAudioSessionIfReady(context: context);
  }

  /// iOS: dopo playout remoto + stato Connected, ritoggle `RTCAudioSession.isAudioEnabled` (una volta per callId).
  Future<void> _maybeRetriggerIosAudioSessionIfReady({required String context}) async {
    if (kIsWeb || !Platform.isIOS) return;
    final cid = _callId;
    if (cid == null || cid.isEmpty) return;
    final pc = _peerConnection;
    if (pc == null) return;
    if (pc.connectionState != RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      return;
    }
    final hasRemoteAudio = (_remoteStream?.getAudioTracks().isNotEmpty ?? false);
    if (!hasRemoteAudio) return;
    if (!_iosAudioRetriggerCallIds.add(cid)) {
      debugPrint(
        '[AUDIO-RETRIGGER-DART] skip duplicate retrigger callId=$cid context=$context',
      );
      return;
    }
    try {
      debugPrint(
        '[AUDIO-RETRIGGER-DART] calling retriggerAudioEnabled for callId=$cid',
      );
      await _iosVoipChannel.invokeMethod<dynamic>('retriggerAudioEnabled');
      debugPrint(
        '[AUDIO-RETRIGGER-DART] retriggerAudioEnabled completed for callId=$cid',
      );
    } catch (e) {
      debugPrint(
        '[AUDIO-RETRIGGER-DART] retriggerAudioEnabled FAILED: $e',
      );
    }
  }

  /// Snapshot PeerConnection + sender/receiver/transceiver in console Xcode (solo iOS).
  void _debugPcState(String context, {String? callId}) {
    if (kIsWeb || !Platform.isIOS) return;
    final pc = _peerConnection;
    final cid = callId ?? _callId ?? '';
    if (pc == null) {
      debugPrint('[PC-IOS] $context callId=$cid peerConnection=null');
      return;
    }
    Future.microtask(() async {
      try {
        final sig = pc.signalingState?.toString() ?? 'null';
        final ice = pc.iceConnectionState?.toString() ?? 'null';
        final conn = pc.connectionState?.toString() ?? 'null';
        final loc = await pc.getLocalDescription();
        final rem = await pc.getRemoteDescription();
        final senders = await pc.getSenders();
        final receivers = await pc.getReceivers();
        final trans = await pc.getTransceivers();
        debugPrint(
          '[PC-IOS] $context callId=$cid signalingState=$sig iceConnectionState=$ice connectionState=$conn remoteDescription=${rem != null} localDescription=${loc != null} senders=${senders.length} receivers=${receivers.length} transceivers=${trans.length}',
        );
        for (var i = 0; i < senders.length; i++) {
          final t = senders[i].track;
          final extra = t != null
              ? 'enabled=${t.enabled} muted=${t.muted}'
              : 'track=null';
          debugPrint(
            '[PC-IOS]   sender[$i] kind=${senders[i].track?.kind} trackId=${senders[i].track?.id} $extra',
          );
        }
        for (var i = 0; i < receivers.length; i++) {
          final t = receivers[i].track;
          final extra = t != null
              ? 'enabled=${t.enabled} muted=${t.muted}'
              : 'track=null';
          debugPrint(
            '[PC-IOS]   receiver[$i] kind=${receivers[i].track?.kind} trackId=${receivers[i].track?.id} $extra',
          );
        }
      } catch (e) {
        debugPrint('[PC-IOS] $context callId=$cid error=$e');
      }
    });
  }

  /// Configures AVAudioSession on iOS (playAndRecord + voiceChat) before WebRTC.
  /// Required for audio to pass on iOS; no-op or ignored on other platforms.
  Future<void> _configureAudioSession() async {
    _remoteLog('[CallService] _configureAudioSession start');
    try {
      await Helper.setAppleAudioConfiguration(AppleAudioConfiguration(
        appleAudioCategory: AppleAudioCategory.playAndRecord,
        appleAudioCategoryOptions: {
          AppleAudioCategoryOption.allowBluetooth,
          AppleAudioCategoryOption.allowBluetoothA2DP,
          AppleAudioCategoryOption.defaultToSpeaker,
        },
        appleAudioMode: AppleAudioMode.voiceChat,
      ));
      _remoteLog('[CallService] _configureAudioSession ok');
    } catch (e) {
      debugPrint('[CallService] _configureAudioSession error: $e');
      _remoteLog('[CallService] _configureAudioSession error: $e');
    }
  }

  Future<void> _createPeerConnection() async {
    _remoteLog('[CallService._createPeerConnection] called, existing=${_peerConnection != null}');
    if (_peerConnection != null) return;
    if (_isCreatingPeerConnection) {
      _remoteLog('[CallService._createPeerConnection] already in progress, skip');
      return;
    }
    _isCreatingPeerConnection = true;
    try {
      final config = <String, dynamic>{
      'iceServers': _iceServers ?? [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
      ],
    };
    _remoteLog('[CallService] peerConnection config: $config');
    final constraints = <String, dynamic>{
      'mandatory': {},
      'optional': [
        {'DtlsSrtpKeyAgreement': true},
      ],
    };
    try {
      _peerConnection = await createPeerConnection(config, constraints);
      _remoteLog('[CallService] peerConnection created ok');
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
        _setRemoteStream(stream);
        _callStartTime ??= DateTime.now();
        _remoteLog('[CallService.onAddStream] stream=${stream.id} audioTracks=${stream.getAudioTracks().length}');
        if (!kIsWeb && Platform.isIOS) {
          debugPrint(
            '[PC-IOS] onAddStream streamId=${stream.id} audioTracks=${stream.getAudioTracks().length} videoTracks=${stream.getVideoTracks().length} callId=$_callId',
          );
          for (final t in stream.getAudioTracks()) {
            debugPrint(
              '[PC-IOS] onAddStream remote audio track id=${t.id} enabled=${t.enabled} muted=${t.muted}',
            );
          }
          _debugPcState('onAddStream');
        }
        _emit(_state.copyWith(remoteStream: _remoteStream, status: CallStatus.connected));
      };
      _peerConnection!.onTrack = (RTCTrackEvent event) {
        final stream = event.streams.isNotEmpty
            ? event.streams.first
            : null;
        _remoteLog('[CallService.onTrack] kind=${event.track.kind} enabled=${event.track.enabled} muted=${event.track.muted} streams=${event.streams.length}');
        if (!kIsWeb && Platform.isIOS) {
          final sids = event.streams.map((s) => s.id).join(',');
          debugPrint(
            '[PC-IOS] onTrack kind=${event.track.kind} trackId=${event.track.id} enabled=${event.track.enabled} muted=${event.track.muted} streamIds=[$sids] callId=$_callId',
          );
          if (event.track.kind == 'audio') {
            debugPrint(
              '[PC-IOS] remote audio track received id=${event.track.id} enabled=${event.track.enabled} muted=${event.track.muted}',
            );
            // forceSpeakerOnDebug rimosso — retriggerAudioEnabled è sufficiente
          }
        }
        if (stream != null) {
          _addRemoteTrackFromStream(stream, event.track);
        } else {
          _addRemoteTrack(event.track);
        }
        _callStartTime ??= DateTime.now();
        _remoteLog('[CallService.onTrack] remote stream attach callId=$_callId remoteAudio=${_remoteStream?.getAudioTracks().length ?? 0}');
        _debugPcState('onTrack');
        if (!kIsWeb && Platform.isIOS && event.track.kind == 'audio') {
          _debugAudioRtcStats('onTrack remote-audio');
          _debugLogAudioTracksSummary('onTrack remote-audio');
          unawaited(
            _maybeRetriggerIosAudioSessionIfReady(context: 'onTrack'),
          );
        }
        _emit(_state.copyWith(remoteStream: _remoteStream, status: CallStatus.connected));
        final cid = _callId;
        final skipSpeakerSoonAfterCallKit =
            !kIsWeb &&
            Platform.isIOS &&
            _state.isIncoming &&
            cid != null &&
            cid.isNotEmpty &&
            CallKitBridge.instance.wasAnswered(cid);
        if (skipSpeakerSoonAfterCallKit) {
          _remoteLog(
            '[CallKit-iOS] skip _scheduleSpeakerDefault on onTrack (incoming CallKit-accepted; evita route override precoce)',
          );
        } else {
          _scheduleSpeakerDefault();
        }
      };
      _peerConnection!.onSignalingState = (RTCSignalingState state) {
        if (!kIsWeb && Platform.isIOS) {
          debugPrint('[PC-IOS] onSignalingState state=$state callId=$_callId');
          _debugPcState('onSignalingState($state)');
        }
      };
      _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
        if (!kIsWeb && Platform.isIOS) {
          debugPrint('[PC-IOS] onConnectionState state=$state callId=$_callId');
          _debugPcState('onConnectionState($state)');
          if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
            // forceSpeakerOnDebug rimosso — retriggerAudioEnabled è sufficiente
            _scheduleIosAudioRtcStatsAfterConnected();
            unawaited(
              _maybeRetriggerIosAudioSessionIfReady(context: 'onConnectionState'),
            );
          }
        }
      };
      _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
        if (!kIsWeb && Platform.isIOS) {
          debugPrint('[PC-IOS] onIceConnectionState state=$state callId=$_callId');
          _debugPcState('onIceConnectionState($state)');
        }
        if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
            state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
          // Connection lost
        }
      };
    } catch (e) {
      debugPrint('[CallService] createPeerConnection error: $e');
    }
    } finally {
      _isCreatingPeerConnection = false;
    }
  }

  Future<Map<String, dynamic>> _getVideoConstraints() async {
    try {
      final result = await Connectivity().checkConnectivity();
      final isWifi = result.contains(ConnectivityResult.wifi);
      if (isWifi) {
        return {
          'facingMode': 'user',
          'width': {'ideal': 1280},
          'height': {'ideal': 720},
          'frameRate': {'ideal': 30},
        };
      } else {
        return {
          'facingMode': 'user',
          'width': {'ideal': 640},
          'height': {'ideal': 480},
          'frameRate': {'ideal': 24},
        };
      }
    } catch (e) {
      return {
        'facingMode': 'user',
        'width': 640,
        'height': 480,
      };
    }
  }

  Future<void> _getUserMedia() async {
    if (_state.localStream != null) return;
    final audio = true;
    final video = _callType == 'video';
    _remoteLog('[CallService._getUserMedia] start audio=$audio video=$video callId=$_callId');
    try {
      // ignore: deprecated_member_use — navigator.mediaDevices from factory not used to keep API simple
      final stream = await MediaDevices.getUserMedia({
        'audio': audio,
        'video': video ? await _getVideoConstraints() : false,
      });
      final tracksCount = stream.getTracks().length;
      _remoteLog('[CallService] _getUserMedia success tracks=$tracksCount');
      _emit(_state.copyWith(localStream: stream));
      final audioTracks = _state.localStream?.getAudioTracks() ?? [];
      _remoteLog('[CallService._getUserMedia] audioTracks=${audioTracks.length} enabled=${audioTracks.map((t) => t.enabled).toList()} muted=${audioTracks.map((t) => t.muted).toList()} callId=$_callId');
      if (!kIsWeb && Platform.isIOS) {
        for (final t in stream.getAudioTracks()) {
          debugPrint(
            '[PC-IOS] local audio track created id=${t.id} enabled=${t.enabled} muted=${t.muted}',
          );
        }
      }
      if (_peerConnection != null) {
        stream.getTracks().forEach((track) {
          if (!kIsWeb && Platform.isIOS) {
            debugPrint(
              '[PC-IOS] local addTrack to peerConnection kind=${track.kind} id=${track.id} streamId=${stream.id}',
            );
          }
          _peerConnection!.addTrack(track, stream);
          if (!kIsWeb && Platform.isIOS && track.kind == 'audio') {
            debugPrint(
              '[PC-IOS] local audio track added to peerConnection id=${track.id}',
            );
          }
        });
      }
    } catch (e) {
      debugPrint('[CallService] getUserMedia error: $e');
      _remoteLog('[CallService] _getUserMedia error: $e');
    }
  }

  Future<void> switchCamera() async {
    final tracks = _state.localStream?.getVideoTracks() ?? [];
    final videoTrack = tracks.isNotEmpty ? tracks.first : null;
    if (videoTrack == null) return;
    try {
      await Helper.switchCamera(videoTrack);
      _remoteLog('[CallService] switchCamera OK');
    } catch (e) {
      debugPrint('[CallService] switchCamera error: $e');
    }
  }

  void _setRemoteStream(MediaStream stream) {
    _remoteLog('[CallService._setRemoteStream] stream=${stream.id} audioTracks=${stream.getAudioTracks().length} videoTracks=${stream.getVideoTracks().length}');
    _remoteStream = stream;
  }

  void _addRemoteTrackFromStream(MediaStream stream, MediaStreamTrack? track) {
    if (_remoteStream == null) {
      _remoteStream = stream;
    } else if (track != null && !_remoteStream!.getTracks().contains(track)) {
      _remoteStream!.addTrack(track);
    }
  }

  void _addRemoteTrack(MediaStreamTrack track) {
    if (_remoteStream != null) {
      _remoteStream!.addTrack(track);
    }
  }

  void _scheduleSpeakerDefault() {
    if (_speakerDefaultApplied) return;
    _speakerDefaultApplied = true;
    _speakerTimer?.cancel();
    _speakerTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!_disposed && _peerConnection != null) {
        _setSpeakerOnByDefault();
        _remoteLog('[CallService] _scheduleSpeakerDefault executing');
      }
    });
    _remoteLog('[CallService] _scheduleSpeakerDefault scheduled 1500ms');
  }

  void _cleanup() {
    final endedId = _callId;
    if (endedId != null && endedId.isNotEmpty) {
      _iosSpeakerForcedCallIds.remove(endedId);
      _iosAudioRetriggerCallIds.remove(endedId);
      CallKitBridge.instance.clear(endedId);
      _nativeAcceptWsSent.remove(endedId);
      // End call in plugin CallManager so next incoming does not see callsInManager=2 (stale).
      try {
        FlutterCallkitIncoming.endCall(endedId);
      } catch (_) {}
    }
    _lastAcceptedCallId = null;
    final localStream = _state.localStream;
    final remoteStream = _state.remoteStream ?? _remoteStream;
    _speakerTimer?.cancel();
    _speakerTimer = null;
    _peerConnection?.close();
    _peerConnection = null;
    _remoteStream = null;
    localStream?.getTracks().forEach((t) => t.stop());
    remoteStream?.getTracks().forEach((t) => t.stop());
    _emit(const CallState(status: CallStatus.idle));
    _callId = null;
    _callType = null;
    _remoteUserId = null;
    _iceServers = null;
    _callStartTime = null;
    _speakerDefaultApplied = false;
    _processedEventKeys.clear();
    _pendingIceCandidates.clear();
  }

  /// Start an outgoing call (1-to-1). Participants are derived from conversation on the backend.
  Future<void> initiateCall(String conversationId, String callType) async {
    debugPrint('[CallService] initiateCall: conversationId=$conversationId, callType=$callType');
    _isEnded = false;
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
    final n = normalizeCallId(callId);
    _remoteLog('[CallService.acceptCall] callId=$n isConnected=$_isConnected channel=${_channel != null}');
    if (_callId != n) return;
    _send({'action': 'accept_call', 'call_id': n});
    _remoteLog('[CallService.acceptCall] sent accept message');
  }

  /// CallKit / native UI already accepted; ensure WS + state machine (idempotent per [callId]).
  Future<void> onAcceptedFromNative(String callId) async {
    final n = normalizeCallId(callId);
    if (n.isEmpty) return;
    _remoteLog('[CallService.onAcceptedFromNative] entry callId=$n _callId=$_callId status=${_state.status}');
    await ensureConnected();
    if (_callId != n) {
      _remoteLog('[CallService.onAcceptedFromNative] skip accept_call: _callId mismatch');
      return;
    }
    if (!_nativeAcceptWsSent.contains(n)) {
      _nativeAcceptWsSent.add(n);
      _remoteLog('[CallService] native accept callId=$n');
      acceptCall(n);
    } else {
      _remoteLog('[CallService] native accept idempotent callId=$n (accept_call already sent)');
    }
    if (_state.status == CallStatus.ringing ||
        (_state.status == CallStatus.idle && _callId == n)) {
      final prev = _state.status;
      _emit(_state.copyWith(status: CallStatus.connecting, isIncoming: true));
      _remoteLog(
        '[CallService] state transition $prev -> connecting after native accept callId=$n',
      );
    }
    _remoteLog('[CallService] start media for accepted native call callId=$n');
  }

  void rejectCall(String callId) {
    final n = normalizeCallId(callId);
    _send({'action': 'reject_call', 'call_id': n});
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

  /// Vivavoce di default solo per le videochiamate.
  void _setSpeakerOnByDefault() {
    final wantSpeaker = _callType == 'video';
    _setSpeaker(wantSpeaker, routeContext: '_setSpeakerOnByDefault');
    debugPrint('[CallService] Speaker default: $wantSpeaker (callType=$_callType)');
  }

  void toggleSpeaker() {
    final next = !_state.isSpeakerOn;
    _setSpeaker(next, routeContext: 'toggleSpeaker');
    if (kDebugMode) debugPrint('[CallService] Speaker toggled to: $next');
    if (_callId != null) {
      _send({'action': 'toggle_speaker', 'call_id': _callId, 'is_speaker_on': next});
    }
  }

  Future<void> _setSpeaker(bool on, {String? routeContext}) async {
    _remoteLog('[CallService] _setSpeaker on=$on');
    _emit(_state.copyWith(isSpeakerOn: on));
    try {
      await Future.delayed(const Duration(milliseconds: 200));
      await _applySpeakerphoneOnIosLogged(
        on,
        context: routeContext ?? '_setSpeaker',
        callId: _callId,
      );
      _remoteLog('[CallService._setSpeaker] completed on=$on');
    } catch (e) {
      if (kDebugMode) debugPrint('[CallService] setSpeaker error: $e');
    }
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
    _isEnded = false;
    final n = normalizeCallId(callId);
    _remoteLog('[CallService.setIncomingCallContext] callId=$n callType=$callType remoteUserId=$remoteUserId');
    _callId = n.isEmpty ? null : n;
    _callType = callType;
    _remoteUserId = remoteUserId;
    _emit(_state.copyWith(
      callId: n.isEmpty ? null : n,
      callType: callType,
      remoteUserId: remoteUserId,
      remoteUserName: remoteUserName ?? _state.remoteUserName,
      remoteUserAvatar: remoteUserAvatar ?? _state.remoteUserAvatar,
      conversationId: conversationId ?? _state.conversationId,
    ));
    _remoteLog('[CallService.setIncomingCallContext] done, status=${_state.status}');
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
