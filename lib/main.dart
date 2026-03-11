import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/constants/app_constants.dart';
import 'core/routes/app_router.dart';
import 'core/services/api_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_app_badger/flutter_app_badger.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'core/services/local_notification_service.dart';
import 'core/services/voip_service.dart';

/// Global navigator key for navigation from outside the widget tree (e.g. incoming call).
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

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

// Handler per notifiche in background (deve essere top-level)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  final data = message.data;
  final type = data['type']?.toString() ?? '';

  if (type == 'incoming_call') {
    debugPrint('[Push] background message received (incoming_call)');
    try {
      await VoipService.instance.init();
      await _showCallKitFromFcmData(data);
    } catch (e) {
      debugPrint('[FCM] incoming_call handler error: $e');
    }
    return;
  }

  if (type == 'new_message' || type == 'message_reaction') {
    debugPrint('[Push] background message received (chat)');
    try {
      final badge = data['badge'];
      if (badge != null) {
        final count = badge is int ? badge : int.tryParse(badge.toString());
        if (count != null && count >= 0) {
          await FlutterAppBadger.updateBadgeCount(count);
          debugPrint('[Badge] set badge count = $count');
          debugPrint('[Push] badge updated from message event');
        }
      }
      if (message.notification == null) {
        final title = data['title']?.toString() ?? 'SecureChat';
        final body = data['body']?.toString() ?? 'Nuovo messaggio';
        await LocalNotificationService.instance.init();
        await LocalNotificationService.instance.show(
          title: title,
          body: body,
          payload: data['source_id']?.toString(),
          channelId: 'messages',
        );
        debugPrint('[Push] showing local notification for chat message');
      } else {
        debugPrint('[Push] system notification expected from FCM payload');
      }
    } catch (e) {
      debugPrint('[Push] background chat handler error: $e');
    }
  }
}

const List<int> _apnsRetryDelaysSeconds = [2, 5, 10];

void _scheduleApnsRetry(
  FirebaseMessaging messaging,
  Future<void> Function(String) sendFcmTokenToServer,
) {
  int attempt = 0;
  void doRetry() async {
    if (attempt >= _apnsRetryDelaysSeconds.length) {
      debugPrint('[Push] APNs still unavailable after ${_apnsRetryDelaysSeconds.length} retries');
      return;
    }
    attempt++;
    final delay = _apnsRetryDelaysSeconds[attempt - 1];
    await Future<void>.delayed(Duration(seconds: delay));
    debugPrint('[Push] APNs retry #$attempt');
    try {
      final apnsToken = await messaging.getAPNSToken();
      if (apnsToken == null || apnsToken.isEmpty) {
        debugPrint('[Push] APNs still unavailable');
        doRetry();
        return;
      }
      debugPrint('[Push] APNs token = ${apnsToken.substring(0, apnsToken.length.clamp(0, 20))}...');
      final token = await messaging.getToken();
      debugPrint('[Push] FCM token = ${token != null ? "${token.substring(0, token.length.clamp(0, 20))}..." : "null"}');
      if (token != null) await sendFcmTokenToServer(token);
    } catch (e) {
      debugPrint('[Push] APNs retry failed: $e');
      doRetry();
    }
  }
  doRetry();
}

Future<void> _showCallKitFromFcmData(Map<String, dynamic> data) async {
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase: inizializzazione unica e subito, prima di qualsiasi uso
  bool firebaseOk = false;
  debugPrint('[Firebase] initializeApp start');
  try {
    await Firebase.initializeApp();
    firebaseOk = true;
    debugPrint('[Firebase] initializeApp success');
  } catch (e, st) {
    debugPrint('[Firebase] initializeApp failed: $e');
    debugPrint('[Firebase] stack: $st');
  }

  if (firebaseOk) {
    try {
      // a) Firebase.initializeApp già fatto sopra
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
      debugPrint('[Push] FirebaseMessaging configured');

      final messaging = FirebaseMessaging.instance;

      // b) Permessi prima di qualsiasi fetch token
      await messaging.requestPermission(alert: true, badge: true, sound: true);

      await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );

      Future<void> sendFcmTokenToServer(String fcmToken) async {
        try {
          final accessToken = ApiService().accessToken;
          if (accessToken == null) return;
          final platform = Platform.isIOS ? 'ios' : (Platform.isAndroid ? 'android' : 'unknown');
          final response = await http.post(
            Uri.parse('${AppConstants.baseUrl}/auth/fcm-token/'),
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'token': fcmToken, 'platform': platform}),
          );
          debugPrint('[FCM] Token registered: ${response.statusCode}');
        } catch (e) {
          debugPrint('[FCM] Token registration error: $e');
        }
      }

      // c) APNs token (iOS) e d) FCM token: su iOS non chiamare getToken() senza APNs
      final isIos = Platform.isIOS;
      if (isIos) {
        String? apnsToken = await messaging.getAPNSToken();
        if (apnsToken == null || apnsToken.isEmpty) {
          debugPrint('[Push] APNs token not ready yet');
          debugPrint('[Push] skipping FCM token fetch until APNs is available');
          _scheduleApnsRetry(messaging, sendFcmTokenToServer);
        } else {
          debugPrint('[Push] APNs token = ${apnsToken.substring(0, apnsToken.length.clamp(0, 20))}...');
          final token = await messaging.getToken();
          debugPrint('[Push] FCM token = ${token != null ? "${token.substring(0, token.length.clamp(0, 20))}..." : "null"}');
          if (token != null) await sendFcmTokenToServer(token);
        }
      } else {
        final token = await messaging.getToken();
        debugPrint('[Push] FCM token = ${token != null ? "${token.substring(0, token.length.clamp(0, 20))}..." : "null"}');
        if (token != null) await sendFcmTokenToServer(token);
      }

      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
        sendFcmTokenToServer(newToken);
      });

      await LocalNotificationService.instance.init();

      FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
        debugPrint('[Push] foreground message received');
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getBool('notifications_enabled') == false) return;
        LocalNotificationService.instance.showFromFCM(message);
      });

      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint('[PushOpen] onMessageOpenedApp received');
        try {
          FlutterAppBadger.removeBadge();
          debugPrint('[Badge] clear badge');
          final data = message.data;
          debugPrint('[PushOpen] onMessageOpenedApp payload = $data');
          debugPrint('[PushOpen] before _handleOpenFromPush');
          _handleOpenFromPush(data is Map<String, dynamic> ? data : null);
        } catch (e, st) {
          debugPrint('[PushOpen] onMessageOpenedApp handler failed: $e');
          debugPrint('[PushOpen] stack: $st');
        }
      });
    } catch (e) {
      debugPrint('[Push] FirebaseMessaging setup failed: $e');
      debugPrint('[Push] continuing app startup without push token');
    }
  }

  // Init local notifications (independent from Firebase)
  await LocalNotificationService.instance.init();

  // VoIP / CallKit for incoming calls (iOS PushKit, Android FCM)
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

  // Apertura da notifica (app terminata): gestione dopo primo frame
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    if (!firebaseOk) return;
    debugPrint('[PushOpen] before getInitialMessage');
    RemoteMessage? message;
    try {
      message = await FirebaseMessaging.instance.getInitialMessage();
    } catch (e, st) {
      debugPrint('[PushOpen] getInitialMessage failed: $e');
      debugPrint('[PushOpen] stack: $st');
      return;
    }
    if (message != null) {
      try {
        debugPrint('[PushOpen] getInitialMessage payload = ${message.data}');
        _handleOpenFromPush(message.data is Map<String, dynamic> ? message.data : null);
      } catch (e, st) {
        debugPrint('[PushOpen] getInitialMessage handle failed: $e');
        debugPrint('[PushOpen] stack: $st');
      }
    }
  });

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
