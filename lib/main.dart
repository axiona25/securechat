import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'core/routes/app_router.dart';
import 'package:flutter_app_badger/flutter_app_badger.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'core/services/local_notification_service.dart';
import 'core/services/securechat_notify_service.dart';
import 'core/services/voip_service.dart';

/// Global navigator key for navigation from outside the widget tree (e.g. incoming call).
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// IDs dei messaggi già mostrati come notifica (deduplicazione).
final Set<String> _shownMessageIds = {};

/// Payload opzionale: tutti i campi come stringhe; nessuna assunzione su presenza.
void _handleOpenFromPush(Map<String, dynamic>? data) {
  debugPrint('[PushOpen] before _handleOpenFromPush');
  Map<String, dynamic> map;
  try {
    map = data != null ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  } catch (e, st) {
    debugPrint('[PushOpen] open-from-push failed (parse data): $e');
    debugPrint('[PushOpen] stack: $st');
    return;
  }
  String conversationId;
  try {
    conversationId = map['conversation_id']?.toString().trim() ??
        map['conversationId']?.toString().trim() ??
        map['source_id']?.toString().trim() ??
        '';
  } catch (e, st) {
    debugPrint('[PushOpen] open-from-push failed (parse conversationId): $e');
    debugPrint('[PushOpen] stack: $st');
    return;
  }
  if (conversationId.isEmpty) {
    debugPrint('[PushOpen] navigation skipped: invalid payload');
    return;
  }
  WidgetsBinding.instance.addPostFrameCallback((_) {
    try {
      final nav = navigatorKey.currentState;
      if (nav == null) {
        debugPrint('[PushOpen] navigation skipped: navigator not ready');
        return;
      }
      debugPrint('[PushOpen] before pushNamed to chatDetail');
      try {
        nav.pushNamed(
          AppRouter.chatDetail,
          arguments: <String, dynamic>{'conversationId': conversationId},
        );
      } catch (e, st) {
        debugPrint('[PushOpen] pushNamed failed: $e');
        debugPrint('[PushOpen] stack: $st');
        try {
          nav.pushNamed(AppRouter.home);
          debugPrint('[PushOpen] fallback to Home');
        } catch (e2) {
          debugPrint('[PushOpen] fallback to Home failed: $e2');
        }
      }
    } catch (e, st) {
      debugPrint('[PushOpen] open-from-push failed: $e');
      debugPrint('[PushOpen] stack: $st');
    }
  });
}

Future<void> _showCallKitFromPushData(Map<String, dynamic> data) async {
  final callId = data['callId']?.toString() ?? '';
  final callerName = data['callerName']?.toString() ?? '';
  final callType = data['callType']?.toString() ?? 'audio';
  final callerUserId = data['callerUserId']?.toString() ?? '';
  final conversationId = data['conversationId']?.toString() ?? '';
  if (callId.isEmpty) return;
  final type = callType == 'video' ? 1 : 0;
  final params = CallKitParams(
    id: callId,
    nameCaller: callerName,
    handle: callerName,
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

Future<void> initNotifyService(int userId) async {
  await SecureChatNotifyService().init(userId: userId);
  SecureChatNotifyService().onMessage = (data) {
    final messageId = data['message_id']?.toString();
    if (messageId != null && _shownMessageIds.contains(messageId)) return;
    if (messageId != null) _shownMessageIds.add(messageId);
  };
  SecureChatNotifyService().onCall = (data) {
    _showCallKitFromPushData(data);
  };
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Init local notifications
  await LocalNotificationService.instance.init();

  // VoIP / CallKit for incoming calls (iOS PushKit, Android)
  await VoipService.instance.init();

  // Badge: non azzerare qui; Home lo sincronizzerà al primo caricamento

  // Lock orientation to portrait
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Transparent status bar
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
  ));

  runApp(SecureChatApp(navigatorKey: navigatorKey));

  // Tap su notifica locale: callback da LocalNotificationService
  LocalNotificationService.setNotificationTapCallback((String? payload) {
    debugPrint('[PushOpen] local notification tap payload = $payload');
    try {
      _handleOpenFromPush(
        payload != null && payload.isNotEmpty
            ? <String, dynamic>{'conversation_id': payload, 'source_id': payload}
            : null,
      );
    } catch (e, st) {
      debugPrint('[PushOpen] local notification tap handler failed: $e');
      debugPrint('[PushOpen] stack: $st');
    }
  });
}
