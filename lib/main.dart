import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/constants/app_constants.dart';
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

// Handler per notifiche in background (deve essere top-level)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  // Chiamata in arrivo su Android: mostra CallKit/Full Screen
  final data = message.data;
  if (data['type'] == 'incoming_call') {
    try {
      await VoipService.instance.init();
      await _showCallKitFromFcmData(data);
    } catch (e) {
      debugPrint('[FCM] incoming_call handler error: $e');
    }
  }
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

  // Firebase init (optional: add google-services.json / GoogleService-Info.plist)
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
    // iOS: show notifications in foreground
    await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
    final token = await messaging.getToken();
    debugPrint('FCM Token: $token');

    // Registra token FCM nel backend (con platform per APNs/FCM)
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

    if (token != null) await sendFcmTokenToServer(token);

    // Refresh token: invia il nuovo token al server quando cambia
    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
      sendFcmTokenToServer(newToken);
    });

    // Inizializza notifiche locali per foreground
    await LocalNotificationService.instance.init();

    // Mostra banner di sistema anche in foreground (solo se notifiche abilitate)
    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      debugPrint('[FCM] Foreground message: ${message.notification?.title}');
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('notifications_enabled') == false) return;
      LocalNotificationService.instance.showFromFCM(message);
    });

    // Gestione tap su notifica
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('[FCM] Opened from notification: ${message.data}');
      FlutterAppBadger.removeBadge();
      // TODO: navigare alla chat corretta
    });
  } catch (e) {
    debugPrint('Firebase not configured: $e');
  }

  // Init local notifications (independent from Firebase)
  await LocalNotificationService.instance.init();

  // VoIP / CallKit for incoming calls (iOS PushKit, Android FCM)
  await VoipService.instance.init();

  // Reset badge when app starts (user is opening the app)
  FlutterAppBadger.removeBadge();

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
}
