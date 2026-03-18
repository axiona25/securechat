import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/widgets/user_avatar_widget.dart';
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
    this.isRejoining = false,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final CallService _callService = CallService();
  StreamSubscription<CallState>? _stateSub;
  Timer? _durationTimer;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _renderersInitialized = false;
  bool _hasPopped = false;

  static const Color _teal = Color(0xFF2ABFBF);
  static const Color _endCallRed = Color(0xFFFF3B30);
  static const Color _navy = Color(0xFF1A2B4A);

  @override
  void initState() {
    super.initState();
    if (widget.isRejoining) {
      // Riattacco a stato e renderer; la chiamata è già attiva.
      _stateSub = _callService.stateStream.listen(_onStateUpdate);
      _initRenderersAndReattach();
      return;
    }
    if (widget.isIncoming && widget.callId != null && widget.remoteUserId != null) {
      _callService.setIncomingCallContext(
        callId: widget.callId!,
        callType: widget.callType,
        remoteUserId: widget.remoteUserId!,
        remoteUserName: widget.remoteUserName,
        remoteUserAvatar: widget.remoteUserAvatar,
        conversationId: widget.conversationId,
      );
      if (!widget.skipRingingSound) CallSoundService().playRingtone();
    } else if (!widget.isIncoming) {
      _callService.initiateCall(widget.conversationId, widget.callType);
    } else if (widget.isIncoming && !widget.skipRingingSound) {
      CallSoundService().playRingtone();
    }
    _stateSub = _callService.stateStream.listen(_onStateUpdate);
    _initRenderers();
    // Status bar con icone bianche su sfondo scuro (chiamata audio/video)
    _setLightStatusBar();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _setLightStatusBar();
    });
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
      if (mounted) setState(() => _renderersInitialized = true);
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
      CallSoundService().stopAll();
      WakelockPlus.enable();
      _startDurationTimer();
    }
    if (s.remoteStream != null && _renderersInitialized) {
      _remoteRenderer.srcObject = s.remoteStream;
    }
    if (s.localStream != null && _renderersInitialized && widget.callType == 'video') {
      _localRenderer.srcObject = s.localStream;
    }
    if (s.status == CallStatus.ended) {
      debugPrint('[CallScreen] Call ended received, closing screen');
      CallSoundService().stopAll();
      WakelockPlus.disable();
      _durationTimer?.cancel();
      _durationTimer = null;
      _closeScreen();
      return;
    }
    setState(() {});
  }

  void _closeScreen() {
    if (_hasPopped) return;
    _hasPopped = true;
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
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
    // Ripristina status bar predefinita (icone scure)
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
    ));
    CallSoundService().stopAll();
    WakelockPlus.disable();
    _durationTimer?.cancel();
    _stateSub?.cancel();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                _callService.state.status == CallStatus.ringing && widget.isIncoming
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
