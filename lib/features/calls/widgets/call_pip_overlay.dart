import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../core/widgets/user_avatar_widget.dart';
import '../screens/call_screen.dart';
import '../../../core/services/call_service.dart';

Map<String, dynamic> pipDataFromCallScreen({
  required String conversationId,
  required String callType,
  int? remoteUserId,
  String? remoteUserName,
  String? remoteUserAvatar,
}) {
  return <String, dynamic>{
    'conversationId': conversationId,
    'callType': callType,
    'remoteUserId': remoteUserId,
    'remoteUserName': remoteUserName ?? 'Utente',
    'remoteUserAvatar': remoteUserAvatar,
  };
}

class CallPipManager {
  CallPipManager._();
  static OverlayEntry? _entry;
  static bool get isShowing => _entry != null;

  static void show(BuildContext context, Map<String, dynamic> pipData) {
    if (_entry != null) {
      _entry!.remove();
      _entry = null;
    }
    final overlay = Overlay.of(context);
    final navigator = Navigator.of(context);
    _entry = OverlayEntry(
      builder: (ctx) => _CallPipOverlay(
        data: pipData,
        navigator: navigator,
        onRemove: () {
          _entry?.remove();
          _entry = null;
        },
      ),
    );
    overlay.insert(_entry!);
  }

  static void remove() {
    _entry?.remove();
    _entry = null;
  }
}

class _CallPipOverlay extends StatefulWidget {
  final Map<String, dynamic> data;
  final NavigatorState navigator;
  final VoidCallback onRemove;

  const _CallPipOverlay({
    required this.data,
    required this.navigator,
    required this.onRemove,
  });

  @override
  State<_CallPipOverlay> createState() => _CallPipOverlayState();
}

class _CallPipOverlayState extends State<_CallPipOverlay> {
  static const double _pipWidth = 160;
  static const double _pipHeight = 210;
  static const Color _teal = Color(0xFF2ABFBF);
  static const Color _endCallRed = Color(0xFFFF3B30);
  static const Color _navy = Color(0xFF1A2B4A);

  StreamSubscription<CallState>? _stateSub;
  Offset _position = Offset.zero;
  bool _initialized = false;

  // Video renderer per la PiP video
  RTCVideoRenderer? _remoteRenderer;
  bool _rendererReady = false;

  String get _conversationId => widget.data['conversationId']?.toString() ?? '';
  String get _callType => widget.data['callType']?.toString() ?? 'audio';
  int? get _remoteUserId => widget.data['remoteUserId'] as int?;
  String get _remoteUserName => widget.data['remoteUserName']?.toString() ?? 'Utente';
  String? get _remoteUserAvatar => widget.data['remoteUserAvatar']?.toString();

  bool get _isVideo => _callType == 'video';

  @override
  void initState() {
    super.initState();
    _stateSub = CallService().stateStream.listen((s) {
      if (!mounted) return;
      if (s.status == CallStatus.ended) {
        widget.onRemove();
        return;
      }
      // Aggiorna stream video se disponibile
      if (_rendererReady && s.remoteStream != null && _remoteRenderer != null) {
        _remoteRenderer!.srcObject = s.remoteStream;
      }
      setState(() {});
    });

    if (_isVideo) {
      _initVideoRenderer();
    }
  }

  Future<void> _initVideoRenderer() async {
    _remoteRenderer = RTCVideoRenderer();
    await _remoteRenderer!.initialize();
    if (!mounted) return;
    final remoteStream = CallService().state.remoteStream;
    if (remoteStream != null) {
      _remoteRenderer!.srcObject = remoteStream;
    }
    setState(() => _rendererReady = true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      final size = MediaQuery.sizeOf(context);
      final padding = MediaQuery.paddingOf(context);
      _position = Offset(
        size.width - _pipWidth - 16 - padding.right,
        size.height - _pipHeight - 100 - padding.bottom,
      );
    }
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _remoteRenderer?.dispose();
    super.dispose();
  }

  void _onExpand() {
    widget.onRemove();
    widget.navigator.push(
      MaterialPageRoute(
        builder: (_) => CallScreen(
          conversationId: _conversationId,
          callType: _callType,
          isIncoming: false,
          isRejoining: true,
          remoteUserId: _remoteUserId,
          remoteUserName: _remoteUserName,
          remoteUserAvatar: _remoteUserAvatar,
        ),
      ),
    );
  }

  void _onEndCall() async {
    await CallService().endCall();
    widget.onRemove();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: _position.dx.clamp(padding.left, size.width - _pipWidth - padding.right),
          top: _position.dy.clamp(padding.top, size.height - _pipHeight - padding.bottom - 80),
            child: GestureDetector(
              onTap: _onExpand,
              onPanUpdate: (d) {
              setState(() {
                _position = Offset(
                  (_position.dx + d.delta.dx).clamp(padding.left, size.width - _pipWidth - padding.right),
                  (_position.dy + d.delta.dy).clamp(padding.top, size.height - _pipHeight - padding.bottom - 80),
                );
              });
            },
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              color: _navy,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: _pipWidth,
                  height: _pipHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Contenuto principale: video o avatar
                      if (_isVideo && _rendererReady && _remoteRenderer!.srcObject != null)
                        RTCVideoView(
                          _remoteRenderer!,
                          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        )
                      else
                        Center(
                          child: UserAvatarWidget(
                            avatarUrl: _remoteUserAvatar,
                            displayName: _remoteUserName,
                            size: 56,
                          ),
                        ),
                      // Pulsanti in basso
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.6),
                              ],
                            ),
                          ),
                          padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8, top: 16),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Material(
                                color: _endCallRed,
                                shape: const CircleBorder(),
                                clipBehavior: Clip.antiAlias,
                                child: InkWell(
                                  onTap: _onEndCall,
                                  child: const SizedBox(
                                    width: 40,
                                    height: 40,
                                    child: Icon(Icons.call_end_rounded, color: Colors.white, size: 20),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
