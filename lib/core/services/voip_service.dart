import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';
import 'api_service.dart';
import 'call_service.dart';
import 'conversation_cache_service.dart';
import '../../features/calls/screens/call_screen.dart';
import '../../main.dart';

/// Handles VoIP push (iOS PushKit) and CallKit incoming call UI.
/// Listens to native MethodChannel for token and incoming call payloads.
class VoipService {
  VoipService._();
  static final instance = VoipService._();

  static const _channel = MethodChannel('com.axphone.app/voip');

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _channel.setMethodCallHandler(_onMethodCall);
    FlutterCallkitIncoming.onEvent.listen(_onCallKitEvent);
    _initialized = true;
    debugPrint('[VoipService] Initialized');
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'voipTokenReceived':
        final token = call.arguments as String?;
        if (token != null && token.isNotEmpty) {
          await _sendVoipTokenToBackend(token);
        }
        return null;
      case 'incomingCall':
        final args = call.arguments;
        if (args is Map) {
          final handle = args['handle'] as String? ?? '';
          final callerName = args['callerName'] as String? ?? handle;
          final callId = args['callId'] as String? ?? '';
          final callType = args['callType'] as String? ?? 'audio';
          final callerUserId = args['callerUserId'] as String? ?? '';
          final conversationId = args['conversationId'] as String? ?? '';
          await _showCallKitIncoming(
            callId: callId,
            callerName: callerName,
            handle: handle,
            callType: callType,
            callerUserId: callerUserId,
            conversationId: conversationId,
          );
        }
        return null;
      default:
        return null;
    }
  }

  Future<void> _sendVoipTokenToBackend(String token) async {
    try {
      final accessToken = ApiService().accessToken;
      if (accessToken == null) return;
      final response = await http.post(
        Uri.parse('${AppConstants.baseUrl}/auth/voip-token/'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'voip_token': token}),
      );
      debugPrint('[VoipService] VoIP token registered: ${response.statusCode}');
    } catch (e) {
      debugPrint('[VoipService] VoIP token registration error: $e');
    }
  }

  Future<void> _showCallKitIncoming({
    required String callId,
    required String callerName,
    required String handle,
    required String callType,
    required String callerUserId,
    required String conversationId,
  }) async {
    final type = callType == 'video' ? 1 : 0;
    final params = CallKitParams(
      id: callId,
      nameCaller: callerName,
      handle: handle,
      type: type,
      appName: 'AXPHONE',
      textAccept: 'Accetta',
      textDecline: 'Rifiuta',
      duration: 45000,
      headers: <String, dynamic>{
        'callerUserId': callerUserId,
        'callId': callId,
        'conversationId': conversationId,
        'callType': callType,
      },
    );
    await FlutterCallkitIncoming.showCallkitIncoming(params);
  }

  void _onCallKitEvent(dynamic event) {
    if (event == null) return;
    final eventName = event.event?.toString() ?? '';
    final body = event.body;
    if (eventName.contains('Accept') || eventName.contains('accept')) {
      _onAccept(body);
    } else if (eventName.contains('Decline') || eventName.contains('decline')) {
      _onDecline(body);
    }
  }

  void _onAccept(dynamic body) async {
    if (body == null) return;
    final callId = body.id?.toString() ?? '';
    final headers = body.headers is Map ? Map<String, dynamic>.from(body.headers as Map) : <String, dynamic>{};
    final callerUserId = int.tryParse(headers['callerUserId']?.toString() ?? '') ?? 0;
    final conversationId = headers['conversationId']?.toString() ?? '';
    final callType = headers['callType']?.toString() ?? 'audio';
    final callerName = body.nameCaller?.toString() ?? '';

    String? avatarUrl = ConversationCacheService.instance.getAvatarForUser(callerUserId);

    CallService().ensureConnected();
    CallService().setIncomingCallContext(
      callId: callId,
      callType: callType,
      remoteUserId: callerUserId,
      remoteUserName: callerName,
      remoteUserAvatar: avatarUrl,
      conversationId: conversationId,
    );
    if (callId.isNotEmpty) {
      CallService().acceptCall(callId);
    }

    final nav = navigatorKey.currentState;
    if (nav != null) {
      nav.push(
        MaterialPageRoute(
          builder: (_) => CallScreen(
            conversationId: conversationId,
            callType: callType,
            isIncoming: true,
            callId: callId,
            remoteUserId: callerUserId,
            remoteUserName: callerName,
            remoteUserAvatar: avatarUrl,
            skipRingingSound: true,
          ),
        ),
      );
    }
    FlutterCallkitIncoming.endCall(callId);
  }

  void _onDecline(dynamic body) {
    final id = body?.id?.toString();
    if (id == null || id.isEmpty) return;
    CallService().ensureConnected();
    CallService().rejectCall(id);
    FlutterCallkitIncoming.endCall(id);
  }
}
