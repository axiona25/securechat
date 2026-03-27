import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/widgets/user_avatar_widget.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/call_kit_bridge.dart';
import '../../../core/utils/call_id_utils.dart';
import '../../../core/services/call_service.dart';
import '../../../core/services/call_sound_service.dart';
import '../widgets/call_pip_overlay.dart';

/// Single screen for outgoing and incoming audio/video calls (1-to-1).
class CallScreen extends StatefulWidget {
  final String conversationId;
  final String callType;
  final bool isIncoming;
  final String? callId;
  final int? remoteUserId;
  final String? remoteUserName;
  final String? remoteUserAvatar;
  /// When true (e.g. opened after accepting from CallKit), do not start ringtone.
  final bool skipRingingSound;
  /// True when this route was opened right after native CallKit accept (explicit UX / logs).
  final bool answeredFromCallKit;
  /// When true, reattach to existing call (e.g. after expanding from PiP).
  final bool isRejoining;

  const CallScreen({
    super.key,
    required this.conversationId,
    required this.callType,
    required this.isIncoming,
    this.callId,
    this.remoteUserId,
    this.remoteUserName,
    this.remoteUserAvatar,
    this.skipRingingSound = false,
    this.answeredFromCallKit = false,
    this.isRejoining = false,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> with WidgetsBindingObserver {
  final CallService _callService = CallService();
  StreamSubscription<CallState>? _stateSub;
  Timer? _durationTimer;
  Timer? _connectingTimeoutTimer;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _renderersInitialized = false;
  bool _hasPopped = false;
  bool _pendingClose = false;
  /// True se UI incoming ringing va soppressa (CallKit / skipRingingSound).
  late final bool _suppressIncomingRingingUi;
  bool _nativeAcceptFlowScheduled = false;
  bool _speakerDebugForcedOnce = false;

  static const Color _teal = Color(0xFF2ABFBF);
  static const Color _endCallRed = Color(0xFFFF3B30);
  static const Color _navy = Color(0xFF1A2B4A);

  void _registerCallUiWithBridge() {
    final cid = normalizeCallId(widget.callId);
    if (cid.isNotEmpty) {
      CallKitBridge.instance.registerFlutterCallUi(cid);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _registerCallUiWithBridge();
    final cid = normalizeCallId(widget.callId);
    final bridgeAnswered = widget.answeredFromCallKit ||
        (cid.isNotEmpty && CallKitBridge.instance.wasAnswered(cid));
    _suppressIncomingRingingUi =
        widget.skipRingingSound || bridgeAnswered;
    debugPrint(
      '[CallScreen.initState] isIncoming=${widget.isIncoming} skipRinging=${widget.skipRingingSound} bridgeAnswered=$bridgeAnswered answeredFromCallKit=${widget.answeredFromCallKit} callId=$cid',
    );
    ApiService().postLog(
      '[REMOTE-DEBUG] [CallScreen.initState] isIncoming=${widget.isIncoming} skipRinging=${widget.skipRingingSound} bridgeAnswered=$bridgeAnswered answeredFromCallKit=${widget.answeredFromCallKit} callId=$cid status=${_callService.state.status}',
    );
    // Log stato audio all'apertura della schermata
    Future.delayed(const Duration(seconds: 1), () {
      final localTracks = _callService.state.localStream?.getAudioTracks() ?? [];
      final remoteTracks = _callService.state.remoteStream?.getAudioTracks() ?? [];
      ApiService().postLog(
        '[REMOTE-DEBUG] [CallScreen] audioCheck localTracks=${localTracks.length} remoteTrack=${remoteTracks.length} localEnabled=${localTracks.map((t) => t.enabled).toList()} remoteEnabled=${remoteTracks.map((t) => t.enabled).toList()} status=${_callService.state.status} isSpeaker=${_callService.state.isSpeakerOn}',
      );
    });
    if (widget.isRejoining) {
      // Riattacco a stato e renderer; la chiamata è già attiva.
      _stateSub = _callService.stateStream.listen(_onStateUpdate);
      _initRenderersAndReattach();
      return;
    }
    if (widget.isIncoming && widget.callId != null && widget.remoteUserId != null) {
      if (!_suppressIncomingRingingUi) {
        _callService.setIncomingCallContext(
          callId: widget.callId!,
          callType: widget.callType,
          remoteUserId: widget.remoteUserId!,
          remoteUserName: widget.remoteUserName,
          remoteUserAvatar: widget.remoteUserAvatar,
          conversationId: widget.conversationId,
        );
        CallSoundService().playRingtone();
      }
    } else if (!widget.isIncoming) {
      _callService.initiateCall(widget.conversationId, widget.callType);
    } else if (widget.isIncoming && !_suppressIncomingRingingUi) {
      CallSoundService().playRingtone();
    }
    _stateSub = _callService.stateStream.listen(_onStateUpdate);
    if (_suppressIncomingRingingUi && cid.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _nativeAcceptFlowScheduled) return;
        _nativeAcceptFlowScheduled = true;
        ApiService().postLog(
          '[REMOTE-DEBUG] [CallScreen] entering native-accepted flow callId=$cid',
        );
        CallService().onAcceptedFromNative(cid);
      });
    }
    if (_suppressIncomingRingingUi) {
      _initRenderersAndReattach();
    } else {
      _initRenderers();
    }
    // Status bar con icone bianche su sfondo scuro (chiamata audio/video)
    _setLightStatusBar();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _setLightStatusBar();
    });
    if (!widget.isRejoining && (widget.isIncoming || widget.answeredFromCallKit)) {
      // Timeout: incoming / CallKit — se resta in connecting o ringing oltre 15s, chiudi (no outgoing)
      _connectingTimeoutTimer = Timer(const Duration(seconds: 15), () {
        final status = CallService().state.status;
        if (status == CallStatus.connecting || status == CallStatus.ringing) {
          debugPrint('[CallScreen] timeout: call still $status after 15s, ending');
          CallService().endCall();
          final kitId = normalizeCallId(CallService().state.callId);
          if (kitId.isNotEmpty) {
            FlutterCallkitIncoming.endCall(kitId);
          }
          _closeScreen();
        }
      });
    }
  }

  static const SystemUiOverlayStyle _lightStatusBarStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
  );

  void _setLightStatusBar() {
    SystemChrome.setSystemUIOverlayStyle(_lightStatusBarStyle);
  }

  Future<void> _initRenderers() async {
    try {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();
      if (mounted) {
        // Assegna stream già disponibili prima che setState aggiorni la UI
        final s = _callService.state;
        if (s.remoteStream != null) _remoteRenderer.srcObject = s.remoteStream;
        if (s.localStream != null && widget.callType == 'video') _localRenderer.srcObject = s.localStream;
        setState(() => _renderersInitialized = true);
      }
    } catch (e) {
      debugPrint('[CallScreen] renderer init error: $e');
    }
  }

  Future<void> _initRenderersAndReattach() async {
    await _initRenderers();
    if (!mounted) return;
    final s = _callService.state;
    if (s.remoteStream != null) {
      _remoteRenderer.srcObject = s.remoteStream;
    }
    if (s.localStream != null && widget.callType == 'video') {
      _localRenderer.srcObject = s.localStream;
    }
    if (s.status == CallStatus.connected) {
      _connectingTimeoutTimer?.cancel();
      WakelockPlus.enable();
      _startDurationTimer();
    }
    if (mounted) setState(() {});
  }

  void _onStateUpdate(CallState s) {
    if (!mounted) return;
    if (s.status == CallStatus.ringing && !widget.isIncoming) {
      CallSoundService().playRingback();
    }
    if (s.status == CallStatus.connected) {
      _connectingTimeoutTimer?.cancel();
      CallSoundService().stopAll();
      WakelockPlus.enable();
      _startDurationTimer();
    }
    if (s.remoteStream != null) {
      if (_renderersInitialized) {
        _remoteRenderer.srcObject = s.remoteStream;
      }
      // renderer non ancora pronti: verranno assegnati in _initRenderers
    }
    if (s.localStream != null && widget.callType == 'video') {
      if (_renderersInitialized) {
        _localRenderer.srcObject = s.localStream;
      }
    }
    if (s.status == CallStatus.ended) {
      debugPrint('[CallScreen] Call ended received, closing screen');
      _connectingTimeoutTimer?.cancel();
      CallSoundService().stopAll();
      WakelockPlus.disable();
      _durationTimer?.cancel();
      _durationTimer = null;
      // Mostra messaggio se utente non disponibile
      final endReason = s.endReason;
      if (endReason != null && endReason.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(endReason),
            duration: const Duration(seconds: 4),
            backgroundColor: const Color(0xFF1A2B4A),
          ),
        );
        Future.delayed(const Duration(seconds: 4), _closeScreen);
      } else {
        _closeScreen();
      }
      return;
    }
    if (s.status == CallStatus.busy) {
      debugPrint('[CallScreen] Remote user busy, closing screen after delay');
      _connectingTimeoutTimer?.cancel();
      WakelockPlus.disable();
      setState(() {});
      Future.delayed(const Duration(seconds: 3), () {
        CallSoundService().stopAll();
        CallService().endCall();
        _closeScreen();
      });
      return;
    }
    setState(() {});
  }

  void _closeScreen() {
    if (_hasPopped) return;
    if (!mounted) {
      _pendingClose = true;
      return;
    }
    _hasPopped = true;
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final currentStatus = CallService().state.status;
      if (_pendingClose ||
          currentStatus == CallStatus.ended ||
          currentStatus == CallStatus.idle) {
        ApiService().postLog(
          '[REMOTE-DEBUG] [CallScreen] resumed with pendingClose=$_pendingClose status=$currentStatus, closing',
        );
        _pendingClose = false;
        _hasPopped = false;
        _closeScreen();
      }
    }
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  String get _statusText {
    final s = _callService.state;
    switch (s.status) {
      case CallStatus.ringing:
        return widget.isIncoming ? 'Chiamata in arrivo' : 'In attesa...';
      case CallStatus.connecting:
        return 'In collegamento...';
      case CallStatus.connected:
        final d = _callService.currentCallDuration;
        if (d != null) {
          final m = d.inMinutes;
          final sec = d.inSeconds % 60;
          return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
        }
        return 'In collegamento...';
      case CallStatus.ended:
        return 'Chiamata terminata';
      case CallStatus.busy:
        return 'Utente occupato';
      default:
        return '';
    }
  }

  String get _remoteDisplayName =>
      widget.remoteUserName ?? _callService.state.remoteUserName ?? 'Utente';

  String? get _remoteAvatar =>
      widget.remoteUserAvatar ?? _callService.state.remoteUserAvatar;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Ripristina status bar predefinita (icone scure)
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
    ));
    CallSoundService().stopAll();
    WakelockPlus.disable();
    _connectingTimeoutTimer?.cancel();
    _durationTimer?.cancel();
    _stateSub?.cancel();
    final cid = normalizeCallId(widget.callId);
    if (cid.isNotEmpty) {
      CallKitBridge.instance.unregisterFlutterCallUi(cid);
    }
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Se la chiamata è terminata in background, non mostrare nulla
    if (_pendingClose || _hasPopped) {
      return const SizedBox.shrink();
    }
    // Se la chiamata è già terminata (ended/idle) e non stiamo iniziando una nuova, nascondi
    final buildStatus = CallService().state.status;
    final buildCallId = CallService().state.callId;
    final expectedId = normalizeCallId(widget.callId);
    if ((buildStatus == CallStatus.ended || buildStatus == CallStatus.idle) &&
        (expectedId.isEmpty || buildCallId != expectedId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_hasPopped) _closeScreen();
      });
      return const SizedBox.shrink();
    }
    return PopScope(
      canPop: _callService.state.status != CallStatus.connected &&
          _callService.state.status != CallStatus.connecting &&
          _callService.state.status != CallStatus.ringing,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final leave = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Terminare la chiamata?'),
            content: const Text(
              'Se esci la chiamata verrà interrotta.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Annulla'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Esci', style: TextStyle(color: _endCallRed)),
              ),
            ],
          ),
        );
        if (leave == true && mounted) {
          await _callService.endCall();
          if (mounted) _closeScreen();
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: _lightStatusBarStyle,
        child: Scaffold(
          backgroundColor: _navy,
          body: SafeArea(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _callService.state.status == CallStatus.ringing &&
                        widget.isIncoming &&
                        !_suppressIncomingRingingUi
                    ? _buildIncomingLayout()
                    : widget.callType == 'video'
                        ? _buildVideoLayout()
                        : _buildAudioLayout(),
                if (_callService.state.status == CallStatus.connected ||
                    _callService.state.status == CallStatus.connecting)
                  Positioned(
                    top: 0,
                    left: 0,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          final pipData = pipDataFromCallScreen(
                            conversationId: widget.conversationId,
                            callType: widget.callType,
                            remoteUserId: widget.remoteUserId,
                            remoteUserName: widget.remoteUserName,
                            remoteUserAvatar: widget.remoteUserAvatar,
                          );
                          CallPipManager.show(context, pipData);
                          Navigator.of(context).pop('minimized');
                        },
                        borderRadius: BorderRadius.circular(24),
                        child: const Padding(
                          padding: EdgeInsets.all(12),
                          child: Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 24),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIncomingLayout() {
    return Column(
      children: [
        const SizedBox(height: 40),
        SizedBox(
          width: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                _remoteDisplayName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                widget.callType == 'video'
                    ? 'Videochiamata in arrivo'
                    : 'Chiamata audio in arrivo',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 16,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        const Spacer(),
        UserAvatarWidget(
          avatarUrl: _remoteAvatar,
          displayName: _remoteDisplayName,
          size: 165,
        ),
        const Spacer(),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _circleButton(
              icon: Icons.call_end_rounded,
              color: _endCallRed,
              onTap: () {
                CallSoundService().stopAll();
                if (widget.callId != null) _callService.rejectCall(widget.callId!);
                _closeScreen();
              },
            ),
            const SizedBox(width: 48),
            _circleButton(
              icon: widget.callType == 'video' ? Icons.videocam_rounded : Icons.call_rounded,
              color: _teal,
              onTap: () {
                CallSoundService().stopAll();
                if (widget.callId != null) _callService.acceptCall(widget.callId!);
              },
            ),
          ],
        ),
        const SizedBox(height: 48),
      ],
    );
  }

  /// Layout centrato per chiamata in attesa (ringing/connecting): nome, stato, avatar grande.
  Widget _buildWaitingLayout({required bool audioOnly}) {
    return Column(
      children: [
        const SizedBox(height: 40),
        SizedBox(
          width: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                _remoteDisplayName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                _statusText,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 16,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        const Spacer(),
        UserAvatarWidget(
          avatarUrl: _remoteAvatar,
          displayName: _remoteDisplayName,
          size: 165,
        ),
        const Spacer(),
        _buildBottomActions(audioOnly: audioOnly),
      ],
    );
  }

  Widget _buildAudioLayout() {
    return _buildWaitingLayout(audioOnly: true);
  }

  Widget _buildVideoLayout() {
    final hasRemoteVideo = _renderersInitialized && _callService.state.remoteStream != null;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasRemoteVideo)
          RTCVideoView(
            _remoteRenderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
          )
        else
          _buildWaitingLayout(audioOnly: false),
        if (_renderersInitialized &&
            widget.callType == 'video' &&
            _callService.state.localStream != null)
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            right: 16,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 120,
                height: 160,
                child: RTCVideoView(
                  _localRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  mirror: true,
                ),
              ),
            ),
          ),
        if (hasRemoteVideo)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.only(bottom: 32),
              child: _buildBottomActions(audioOnly: false),
            ),
          ),
        if (_callService.state.status == CallStatus.connected)
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.45),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _statusText,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBottomActions({required bool audioOnly}) {
    final s = _callService.state;
    final isConnected = s.status == CallStatus.connected;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        if (!widget.isIncoming || isConnected) ...[
          _actionButton(
            icon: s.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
            label: 'Microfono',
            isOn: !s.isMuted,
            onTap: () => _callService.toggleMute(),
          ),
          if (!audioOnly)
            _actionButton(
              icon: s.isVideoOff ? Icons.videocam_off_rounded : Icons.videocam_rounded,
              label: 'Video',
              isOn: !s.isVideoOff,
              onTap: () => _callService.toggleVideo(),
            ),
          _actionButton(
            icon: Icons.volume_up_rounded,
            label: 'Speaker',
            isOn: s.isSpeakerOn,
            onTap: () => _callService.toggleSpeaker(),
          ),
          if (!audioOnly)
            _actionButton(
              icon: Icons.cameraswitch_rounded,
              label: 'Cambia',
              isOn: true,
              onTap: () => _callService.switchCamera(),
            ),
        ],
        _circleButton(
          icon: Icons.call_end_rounded,
          color: _endCallRed,
          size: 64,
          onTap: () async {
            await _callService.endCall();
            if (mounted) _closeScreen();
          },
        ),
      ],
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required bool isOn,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: onTap,
          icon: Icon(
            icon,
            color: isOn ? _teal : Colors.white54,
            size: 28,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            color: Colors.white70,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _circleButton({
    required IconData icon,
    required Color color,
    double size = 56,
    required VoidCallback onTap,
  }) {
    return Material(
      color: color,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: Colors.white, size: size * 0.45),
        ),
      ),
    );
  }
}
