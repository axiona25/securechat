import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/routes/app_router.dart';
import 'package:flutter_app_badger/flutter_app_badger.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'core/services/api_service.dart';
import 'core/services/auth_service.dart';
import 'core/services/local_notification_service.dart';
import 'core/services/securechat_notify_service.dart';
import 'core/services/voip_service.dart';
import 'core/utils/call_id_utils.dart';
import 'core/services/security_service.dart';

/// Global navigator key for navigation from outside the widget tree (e.g. incoming call).
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// True quando SecurityService ha rilevato una minaccia critica
/// e ha bloccato l'invio messaggi.
final ValueNotifier<bool> messagingBlockedNotifier = ValueNotifier<bool>(false);

/// True quando il monitoraggio sicurezza è attivo (default: true).
final ValueNotifier<bool> securityEnabledNotifier = ValueNotifier<bool>(false);

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
  final callId = normalizeCallId(data['callId']?.toString());
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
    // Stesso ramo incoming: niente configureAudioSession nel plugin; handoff in didActivate (AppDelegate).
    ios: const IOSParams(
      iconName: 'CallKitLogo',
      configureAudioSession: false,
      audioSessionActive: false,
    ),
    headers: <String, dynamic>{
      'callerUserId': callerUserId,
      'callId': callId,
      'conversationId': conversationId,
      'callType': callType,
    },
  );
  await FlutterCallkitIncoming.showCallkitIncoming(params);
}

/// Registra i callback globali su [SecurityService] (logout, alert, messaging block).
void registerSecurityServiceCallbacks() {
  final security = SecurityService();
  security.onForcedLogout = () async {
    debugPrint('[Security] Logout forzato per minaccia critica');
    await AuthService().logout();
    navigatorKey.currentState?.pushNamedAndRemoveUntil(
      AppRouter.login, (route) => false,
    );
  };
  security.onThreatAlert = (String message) {
    debugPrint('[Security] ALERT: $message');
    final context = navigatorKey.currentContext;
    if (context != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 6),
        ),
      );
    }
  };
  security.onMessagingBlocked = (bool blocked) {
    debugPrint('[Security] Messaggistica bloccata: $blocked');
    messagingBlockedNotifier.value = blocked;
  };
}

/// Notify + APNs + callback messaggi/chiamate — senza SecurityService.
Future<void> initNotifyOnly(int userId) async {
  await SecureChatNotifyService().init(userId: userId);
  // Registra APNs token al backend Django per push messaggi
  try {
    final apnsToken = await AuthService().getApnsToken();
    if (apnsToken != null) {
      await ApiService().post('/auth/apns-token/', body: {'apns_token': apnsToken});
      debugPrint('[Main] APNs token registrato al backend');
    }
  } catch (e) {
    debugPrint('[Main] APNs token registration at startup failed: $e');
  }
  SecureChatNotifyService().onMessage = (data) {
    ApiService().postLog('[Main.onMessage] received: title=${data['title']} body=${data['body']} type=${data['type']} keys=${data.keys.toList()}');
    final messageId = data['message_id']?.toString();
    if (messageId != null && _shownMessageIds.contains(messageId)) return;
    if (messageId != null) _shownMessageIds.add(messageId);
    // Banner gestito da APNs push di sistema — no LocalNotificationService
  };
  SecureChatNotifyService().onCall = (data) {
    debugPrint(
      '[NotifyService] onCall callback triggered (should only happen on Android): ${data['call_id'] ?? 'unknown'}',
    );
    _showCallKitFromPushData(data);
  };
}

Future<void> initNotifyService(int userId) async {
  await initNotifyOnly(userId);
  registerSecurityServiceCallbacks();
  securityEnabledNotifier.value = true;
  await SecurityService().startMonitoring();
}

/// Avvio dopo login o cold start: rispetta [security_monitoring_enabled] (default off).
Future<void> initNotifyForLoggedInUser(int userId) async {
  final prefs = await SharedPreferences.getInstance();
  final secEnabled = prefs.getBool('security_monitoring_enabled') ?? false;
  securityEnabledNotifier.value = secEnabled;
  if (!secEnabled) {
    await initNotifyOnly(userId);
    debugPrint('[Notify] Security OFF — solo notify (user $userId)');
  } else {
    await initNotifyService(userId);
    debugPrint('[Notify] Security ON — notify + security (user $userId)');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Init local notifications
  await LocalNotificationService.instance.init();

  // VoIP / CallKit for incoming calls (iOS PushKit, Android)
  await VoipService.instance.init();

  // Init SecureChatNotifyService se utente già loggato
  try {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getInt('current_user_id');
    if (userId != null) {
      await initNotifyForLoggedInUser(userId);
    }
  } catch (e) {
    debugPrint('[Main] NotifyService init failed: $e');
  }

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
