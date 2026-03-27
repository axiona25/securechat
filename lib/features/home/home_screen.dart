import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../core/theme/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../core/models/conversation_model.dart';
import '../../core/models/user_model.dart';
import '../../core/services/api_service.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/chat_service.dart';
import '../../core/services/crypto_service.dart';
import '../../core/services/session_manager.dart';
import '../../core/services/sound_service.dart';
import '../../core/services/chat_sound_service.dart';
import '../../core/services/call_service.dart';
import '../../core/services/avatar_cache_service.dart';
import '../../core/services/conversation_cache_service.dart';
import '../../core/services/local_notification_service.dart';
import '../../core/services/securechat_notify_service.dart';
import '../../core/services/voip_service.dart';
import '../../core/services/call_kit_bridge.dart';
import '../../core/utils/call_id_utils.dart';
import '../../core/services/device_service.dart';
import '../../core/routes/app_router.dart';
import '../../core/widgets/bottom_nav_bar.dart';
import '../../core/widgets/user_avatar_widget.dart';
import '../chat/screens/chat_detail_screen.dart' show ChatDetailScreen;
import 'widgets/home_header.dart';
import 'widgets/chat_search_bar.dart';
import 'widgets/chat_tab_bar.dart';
import 'widgets/chat_list_view.dart';
import 'package:flutter_app_badger/flutter_app_badger.dart';
import '../settings/settings_screen.dart';
import '../auth/widgets/change_password_modal.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import '../calls/screens/call_screen.dart';
import '../calls/screens/calls_history_screen.dart';
import '../security/security_monitor_screen.dart';
import '../../core/l10n/app_localizations.dart';
import '../../main.dart' show navigatorKey;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin, WidgetsBindingObserver {
  final ChatService _chatService = ChatService();
  final TextEditingController _searchController = TextEditingController();

  int _currentNavIndex = 0;
  ChatFilter _chatFilter = ChatFilter.all;
  bool _isLoading = true;

  UserModel? _currentUser;
  List<ConversationModel> _conversations = [];
  int _notificationCount = 0;
  String _searchQuery = '';
  Timer? _pollingTimer;
  Timer? _locationTimer;
  bool _isFirstLoad = true;
  bool _isLockedMode = false;

  late AnimationController _lockAnimController;

  WebSocket? _homeWebSocket;
  final Map<String, bool> _typingConversations = {}; // conversationId -> isTyping
  final Map<String, bool> _recordingConversations = {}; // conversationId -> isRecording
  final Set<String> _notifiedMessageIds = {};
  StreamSubscription<CallState>? _incomingCallSub;
  bool _isCallScreenOpen = false;
  /// Evita doppio postFrameCallback per lo stesso [callId] da `call.incoming`.
  String? _scheduledIncomingPushForCallId;
  int _missedCallsCount = 0;
  final GlobalKey<CallsHistoryScreenState> _callsHistoryKey = GlobalKey<CallsHistoryScreenState>();
  bool _e2eNeedsManualRecovery = false;
  bool _hasShownRecoveryDialog = false;
  bool _isNavigating = false;

  AppLocalizations get l10n => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lockAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _loadData();
    SecureChatNotifyService.setNotificationTappedCallback((conversationId) {
      if (mounted) _loadData();
    });
    _loadMissedCallsCount();
    _connectHomeWebSocket();
    CallService().ensureConnected();
    CallService().startNetworkMonitoring();
    // Controlla chiamata pendente da CallKit (cold start)
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(milliseconds: 800));

      // 1. Controlla chiamata pendente da _pendingAcceptedCall
      final pending = VoipService.getPendingAcceptedCall();
      await ApiService().postLog('[HomeScreen.initState] pending=$pending nav=${navigatorKey.currentState != null}');
      if (pending != null && mounted) {
        await _navigateToCallScreen(pending);
        return;
      }

      // 2. Controlla chiamate attive da flutter_callkit_incoming (cold start)
      try {
        final activeCalls = await FlutterCallkitIncoming.activeCalls();
        await ApiService().postLog('[HomeScreen.initState] activeCalls=$activeCalls');
        if (activeCalls is List && activeCalls.isNotEmpty && mounted) {
          // Recupera dati chiamata da SharedPreferences
          final prefs = await SharedPreferences.getInstance();
          final callDataStr = prefs.getString('pending_call_data');
          await ApiService().postLog('[HomeScreen.initState] callDataStr=$callDataStr');
          if (callDataStr != null) {
            final callData = jsonDecode(callDataStr) as Map<String, dynamic>;
            await prefs.remove('pending_call_data');
            await _navigateToCallScreen({
              'callId': normalizeCallId(callData['callId'] as String?),
              'callType': callData['callType'] as String? ?? 'audio',
              'callerUserId': int.tryParse(callData['callerUserId']?.toString() ?? '') ?? 0,
              'conversationId': callData['conversationId'] as String? ?? '',
              'callerName': callData['callerName'] as String? ?? '',
              'avatarUrl': null,
            });
          }
        }
      } catch (e) {
        await ApiService().postLog('[HomeScreen.initState] activeCalls error: $e');
      }
    });
    _incomingCallSub = CallService().onIncomingCall.listen((CallState callState) async {
      final wsCallId = normalizeCallId(callState.callId);
      if (wsCallId.isNotEmpty && CallKitBridge.instance.wasPresented(wsCallId)) {
        await ApiService().postLog(
          '[REMOTE-DEBUG] [HomeScreen._incomingCallSub] skip incoming UI, CallKit already presented callId=$wsCallId',
        );
        return;
      }
      if (wsCallId.isNotEmpty && CallKitBridge.instance.wasAnswered(wsCallId)) {
        await ApiService().postLog(
          '[REMOTE-DEBUG] [HomeScreen._incomingCallSub] skip ringing UI, already answered by CallKit callId=$wsCallId',
        );
        return;
      }
      if (wsCallId.isNotEmpty && CallKitBridge.instance.wasNavigated(wsCallId)) {
        await ApiService().postLog(
          '[REMOTE-DEBUG] [HomeScreen._incomingCallSub] skip, bridge already navigated callId=$wsCallId',
        );
        return;
      }
      await ApiService().postLog(
        '[HomeScreen._incomingCallSub] callId=${callState.callId} isCallScreenOpen=$_isCallScreenOpen scheduled=$_scheduledIncomingPushForCallId',
      );
      if (!mounted || _isCallScreenOpen) return;
      if (callState.isIncoming && callState.status == CallStatus.ringing) {
        if (wsCallId.isNotEmpty && _scheduledIncomingPushForCallId == wsCallId) {
          return;
        }
        if (wsCallId.isNotEmpty) {
          _scheduledIncomingPushForCallId = wsCallId;
        }
        debugPrint('[Home] Incoming call received: callId=${callState.callId}, from=${callState.remoteUserName}');

        WidgetsBinding.instance.addPostFrameCallback((_) async {
          try {
            if (!mounted) return;

            final nav = navigatorKey.currentState;
            if (nav == null) {
              debugPrint('[Home] ERROR: navigatorKey.currentState is null');
              return;
            }

            final cid = normalizeCallId(callState.callId);
            if (cid.isNotEmpty &&
                CallKitBridge.instance.isCallUiHandledFor(
                  cid,
                  includeNativeAnswered: true,
                )) {
              await ApiService().postLog(
                '[REMOTE-DEBUG] [HomeScreen._incomingCallSub] abort scheduled push, call already handled by CallKit callId=$cid',
              );
              return;
            }

            // iOS: non chiamare setCallConnected — nel plugin mappa a CXAnswerCallAction (secondo accept / errori transaction).
            // Android: aggiorna stato notifica CallKit senza quel side-effect.
            try {
              if (kIsWeb || !Platform.isIOS) {
                final activeCalls = await FlutterCallkitIncoming.activeCalls();
                if (activeCalls is List && activeCalls.isNotEmpty) {
                  for (final call in activeCalls) {
                    if (call is Map) {
                      final nid = normalizeCallId(call['id']?.toString());
                      if (nid.isNotEmpty) {
                        await ApiService().postLog(
                          '[REMOTE-DEBUG] [HomeScreen] setCallConnected normalizedId=$nid (foreground Flutter call UI)',
                        );
                        await FlutterCallkitIncoming.setCallConnected(nid);
                      }
                    }
                  }
                }
              } else {
                debugPrint(
                  '[CallKit-iOS] skip setCallConnected on iOS path context=HomeScreen._incomingCallSub callId=$cid',
                );
                await ApiService().postLog(
                  '[CallKit-iOS] skip Home setCallConnected loop (incoming WS+Flutter UI; evita duplicate CXAnswerCallAction)',
                );
              }
            } catch (_) {}

            if (!mounted) return;
            if (cid.isNotEmpty &&
                CallKitBridge.instance.isCallUiHandledFor(
                  cid,
                  includeNativeAnswered: true,
                )) {
              await ApiService().postLog(
                '[REMOTE-DEBUG] [HomeScreen._incomingCallSub] abort scheduled push, call already handled by CallKit callId=$cid',
              );
              return;
            }

            _isCallScreenOpen = true;
            // Il Future di push completa al pop: non await; reset flag sul .then
            nav
                .push(
                  MaterialPageRoute(
                    builder: (_) => CallScreen(
                      conversationId: callState.conversationId ?? '',
                      callType: callState.callType ?? 'audio',
                      isIncoming: true,
                      callId: callState.callId,
                      remoteUserId: callState.remoteUserId,
                      remoteUserName: callState.remoteUserName,
                      remoteUserAvatar: callState.remoteUserAvatar,
                    ),
                  ),
                )
                .then((_) {
                  if (mounted) _isCallScreenOpen = false;
                });
          } finally {
            if (wsCallId.isNotEmpty && _scheduledIncomingPushForCallId == wsCallId) {
              _scheduledIncomingPushForCallId = null;
            }
          }
        });
      }
    });
    // E2E: warmup session storage, show recovery modal if needed, replenish prekeys (keys already inited by Splash/LoginForm)
    () async {
      try {
        await SessionManager().warmupSessionStorage();
        final needsRecovery = await CryptoService.getNeedsManualRecoveryFlag();
        debugPrint('[Home] e2e recovery flag at startup: $needsRecovery');
        if (mounted && needsRecovery && !_e2eNeedsManualRecovery) {
          // Se le chiavi non sono mai state caricate (nuova installazione / nuovo device),
          // il flag di recovery è un falso positivo — lo azzeriamo silenziosamente.
          // Le chiavi vengono rigenerate automaticamente da initializeKeys() in splash/login.
          String? keysUploaded;
          try {
            keysUploaded = await const FlutterSecureStorage().read(
              key: 'scp_keys_uploaded',
              aOptions: AndroidOptions.defaultOptions,
              iOptions: IOSOptions(
                groupId: 'com.axphone.app.shared',
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );
          } catch (e) {
            debugPrint('[Home] keysUploaded read error (debug mode?): $e');
            keysUploaded = null;
          }
          if (keysUploaded != 'true') {
            await CryptoService.clearNeedsManualRecoveryFlag();
            debugPrint('[Home] recovery flag cleared — keys never uploaded, new install');
          } else {
            setState(() => _e2eNeedsManualRecovery = true);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              if (_e2eNeedsManualRecovery && !_hasShownRecoveryDialog) {
                _hasShownRecoveryDialog = true;
                debugPrint('[Home] showing recovery modal');
                _showE2ERecoveryModalIfNeeded();
              } else if (_hasShownRecoveryDialog) {
                debugPrint('[Home] recovery modal skipped because already shown');
              }
            });
          }
        }
        await CryptoService(apiService: ApiService()).checkAndReplenishPreKeys();
      } catch (e, stack) {
        debugPrint('[Home] Crypto init error: $e');
        debugPrint('[Home] stack: $stack');
      }
    }();
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) _loadDataSilent();
    });
    // Aggiorna posizione device ogni 15 minuti
    _locationTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      DeviceService.instance.updateLocation();
    });
  }

  Future<void> _navigateToCallScreen(Map<String, dynamic> pending) async {
    final nav = navigatorKey.currentState;
    if (nav == null || !mounted) return;

    final callId = normalizeCallId(pending['callId'] as String?);
    final callType = pending['callType'] as String? ?? 'audio';
    final callerUserId = pending['callerUserId'] as int? ?? 0;
    final conversationId = pending['conversationId'] as String? ?? '';
    final callerName = pending['callerName'] as String? ?? '';
    final avatarUrl = pending['avatarUrl'] as String?;

    if (callId.isEmpty) {
      await ApiService().postLog('[HomeScreen._navigateToCallScreen] abort empty callId');
      return;
    }

    CallService().setIncomingCallContext(
      callId: callId,
      callType: callType,
      remoteUserId: callerUserId,
      remoteUserName: callerName,
      remoteUserAvatar: avatarUrl,
      conversationId: conversationId,
    );
    await CallService().onAcceptedFromNative(callId);

    if (callId.isNotEmpty &&
        CallKitBridge.instance.isCallUiHandledFor(
          callId,
          includeNativeAnswered: false,
        )) {
      await ApiService().postLog(
        '[REMOTE-DEBUG] [HomeScreen._navigateToCallScreen] skip push, call UI already handled callId=$callId',
      );
      return;
    }

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
          answeredFromCallKit: true,
        ),
      ),
    );
    if (callId.isNotEmpty) {
      CallKitBridge.instance.markNavigated(callId);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // Controlla chiamata pendente da CallKit ogni volta che l'app torna in foreground
      Future.delayed(const Duration(milliseconds: 300), () async {
        final pending = VoipService.getPendingAcceptedCall();
        await ApiService().postLog('[HomeScreen.resumed] pending=$pending nav=${navigatorKey.currentState != null}');
        if (pending != null && mounted) {
          await _navigateToCallScreen(Map<String, dynamic>.from(pending));
        }
        // Gate per-callId: avvia polling solo se c'è un callId in prefs già answered da CallKit (niente flag globale).
        final prefs = await SharedPreferences.getInstance();
        final callDataStr = prefs.getString('pending_call_data');
        if (callDataStr == null || !mounted) return;
        try {
          final callData = jsonDecode(callDataStr) as Map<String, dynamic>;
          final callId = normalizeCallId(callData['callId'] as String?);
          if (callId.isEmpty || !CallKitBridge.instance.wasAnswered(callId)) return;
          await ApiService().postLog('[HomeScreen.resumed] starting prefs-polling for callId=$callId (wasAnswered per-callId)');
          int attempts = 0;
          Timer.periodic(const Duration(milliseconds: 300), (timer) async {
            attempts++;
            if (attempts > 33) {
              timer.cancel();
              return;
            }

            final prefsLoop = await SharedPreferences.getInstance();
            final callDataStrLoop = prefsLoop.getString('pending_call_data');
            if (callDataStrLoop == null) return;

            try {
              final activeCalls = await FlutterCallkitIncoming.activeCalls();
              if (activeCalls is! List || activeCalls.isEmpty) {
                timer.cancel();
                await prefsLoop.remove('pending_call_data');
                return;
              }
            } catch (_) {}

            final status = CallService().state.status;
            if (status == CallStatus.connecting || status == CallStatus.connected) {
              timer.cancel();
              return;
            }

            timer.cancel();
            final callDataLoop = jsonDecode(callDataStrLoop) as Map<String, dynamic>;
            await prefsLoop.remove('pending_call_data');
            if (mounted) {
              await _navigateToCallScreen({
                'callId': normalizeCallId(callDataLoop['callId'] as String?),
                'callType': callDataLoop['callType'] as String? ?? 'audio',
                'callerUserId': int.tryParse(callDataLoop['callerUserId']?.toString() ?? '') ?? 0,
                'conversationId': callDataLoop['conversationId'] as String? ?? '',
                'callerName': callDataLoop['callerName'] as String? ?? '',
                'avatarUrl': null,
              });
            }
          });
        } catch (_) {}
      });
      CallService().ensureConnected();
      if (mounted) _loadData();
      _pollingTimer?.cancel();
      _pollingTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (mounted) _loadDataSilent();
      });
      final userId = _currentUser?.id;
      final token = ApiService().accessToken;
      if (token != null && userId != null) {
        http.post(
          Uri.parse('${AppConstants.notifyBaseUrl}/badge-sync'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({
            'user_id': userId,
            'total_unread': 0,
            'chat_unread': 0,
            'source': 'app_foreground',
          }),
        ).then((response) {
          debugPrint('[BadgeSync] status=${response.statusCode} body=${response.body}');
        }).catchError((e) {
          debugPrint('[BadgeSync] ERROR: $e');
        });
      }
    }
    if (state == AppLifecycleState.paused) {
      _pollingTimer?.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _incomingCallSub?.cancel();
    FlutterAppBadger.removeBadge();
    _lockAnimController.dispose();
    _pollingTimer?.cancel();
    _locationTimer?.cancel();
    _homeWebSocket?.close();
    _homeWebSocket = null;
    _searchController.dispose();
    super.dispose();
  }

  void _connectHomeWebSocket() {
    final token = ApiService().accessToken;
    if (token == null || token.isEmpty) return;
    final wsUrl = '${AppConstants.wsUrl}?token=${Uri.encodeComponent(token)}';
    WebSocket.connect(wsUrl).then((ws) {
      if (!mounted) {
        ws.close();
        return;
      }
      _homeWebSocket = ws;
      _homeWebSocket!.listen(
        (data) {
          if (!mounted) return;
          try {
            final map = jsonDecode(
              data is String ? data : String.fromCharCodes(data as List<int>),
            ) as Map<String, dynamic>?;
            if (map == null) return;
            if (map['type'] == 'typing.indicator') {
              final convId = map['conversation_id']?.toString();
              final isTyping = map['is_typing'] == true;
              final isRecording = map['is_recording'] == true;
              final userId = map['user_id'];
              final currentId = _currentUser?.id;
              final otherId = userId is int ? userId : int.tryParse(userId?.toString() ?? '');
              if (convId != null && otherId != null && otherId != currentId) {
                setState(() {
                  _typingConversations[convId] = isTyping && !isRecording;
                  _recordingConversations[convId] = isTyping && isRecording;
                });
              }
            }
            if (map['type'] == 'conversation.deleted') {
              final convId = map['conversation_id']?.toString();
              if (convId != null && mounted) {
                setState(() => _conversations.removeWhere((c) => c.id == convId));
              }
            }
            if (map['type'] == 'session.reset') {
              final resetUserId = map['reset_user_id'];
              if (resetUserId != null && mounted) {
                final uid = resetUserId is int ? resetUserId : int.tryParse(resetUserId.toString());
                if (uid != null) {
                  SessionManager().deleteSession(uid, reason: 'server_session_reset').then((_) {
                    debugPrint('[E2E] Session reset received for user $uid');
                  });
                }
              }
            }
            if (map['type'] == 'device.blocked') {
              debugPrint('[Device] device.blocked received — forcing logout');
              () async {
                try { await AuthService().logout(); } catch (_) {}
                if (mounted) {
                  await showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => AlertDialog(
                      title: const Text('Dispositivo bloccato'),
                      content: const Text(
                        'Questo dispositivo è stato bloccato dall\'amministratore. '
                        'Contatta l\'amministratore per maggiori informazioni.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  );
                  Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
                }
              }();
              return;
            }
            if (map['type'] == 'presence.update') {
              final userId = map['user_id'];
              final isOnline = map['is_online'] == true;
              final convId = map['conversation_id']?.toString();

              if (userId != null && mounted) {
                final userIdInt = userId is int ? userId : int.tryParse(userId.toString());
                if (userIdInt != null) {
                  setState(() {
                    for (int i = 0; i < _conversations.length; i++) {
                      final conv = _conversations[i];
                      bool shouldUpdate = false;
                      if (convId != null && convId.isNotEmpty) {
                        shouldUpdate = conv.id == convId;
                      } else {
                        shouldUpdate = conv.participants.any((p) => p.userId == userIdInt);
                      }

                      if (shouldUpdate) {
                        final updatedParticipants = conv.participants.map((p) {
                          if (p.userId == userIdInt) {
                            return ConversationParticipant(
                              userId: p.userId,
                              username: p.username,
                              displayName: p.displayName,
                              avatar: p.avatar,
                              isOnline: isOnline,
                            );
                          }
                          return p;
                        }).toList();

                        _conversations[i] = ConversationModel(
                          id: conv.id,
                          convType: conv.convType,
                          name: conv.name,
                          groupAvatarUrl: conv.groupAvatarUrl,
                          participants: updatedParticipants,
                          lastMessage: conv.lastMessage,
                          unreadCount: conv.unreadCount,
                          isMuted: conv.isMuted,
                          isLocked: conv.isLocked,
                          isFavorite: conv.isFavorite,
                          createdById: conv.createdById,
                          createdAt: conv.createdAt,
                        );
                      }
                    }
                  });
                }
              }
            }
          } catch (_) {}
        },
        onDone: () {
          _homeWebSocket = null;
        },
        cancelOnError: false,
      );
    }).catchError((_) {});
  }

  Future<void> _loadData() async {
    if (_isFirstLoad) {
      setState(() => _isLoading = true);
    }

    try {
      final results = await Future.wait([
        _chatService.getConversations(),
        _chatService.getCurrentUser(),
        _chatService.getNotificationBadgeCount(),
      ]);

      if (!mounted) return;

      final user = results[1] as UserModel?;
      if (user != null) {
        await AuthService.setCurrentUserId(user.id);
      }
      final conversations = results[0] as List<ConversationModel>;
      // E2E: encrypted last message preview — use home preview only if timestamp matches last message
      final prefs = await SharedPreferences.getInstance();
      for (final conv in conversations) {
        if (conv.lastMessage == null) {
          await prefs.remove('scp_home_preview_${conv.id}');
        }
        final wasCleared = prefs.getBool('scp_chat_cleared_${conv.id}') ?? false;
        if (wasCleared && conv.lastMessage != null) {
          conv.lastMessage!.content = '';
          await prefs.remove('scp_chat_cleared_${conv.id}');
        }
        final lm = conv.lastMessage;
        if (lm != null &&
            lm.contentEncryptedB64 != null &&
            lm.contentEncryptedB64!.isNotEmpty) {
          final lastMsgTs = lm.createdAt?.toIso8601String();
          final raw = prefs.getString('scp_home_preview_${conv.id}');
          if (raw != null && lastMsgTs != null) {
            try {
              final decoded = jsonDecode(raw) as Map<String, dynamic>?;
              final savedTs = decoded?['ts']?.toString();
              final content = decoded?['content']?.toString();
              final cleanContent = (content ?? '').replaceAll('🔒 ', '').replaceAll('🔒', '');
              if (savedTs == lastMsgTs && cleanContent.isNotEmpty) {
                lm.content = cleanContent;
              } else {
                lm.content = '🔒 Messaggio cifrato';
              }
            } catch (_) {
              lm.content = '🔒 Messaggio cifrato';
            }
          } else {
            lm.content = '';
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _conversations = conversations;
        _currentUser = user;
        _notificationCount = results[2] as int;
        _isLoading = false;
        _isFirstLoad = false;
      });
      ConversationCacheService.instance.update(_conversations);
      _updateAppBadge();

      // Check se deve cambiare password
      if (_currentUser != null) {
        try {
          final token = ApiService().accessToken;
          final response = await http.get(
            Uri.parse('${AppConstants.baseUrl}/auth/profile/'),
            headers: {'Authorization': 'Bearer $token'},
          );
          if (response.statusCode == 200) {
            final profileData = jsonDecode(response.body) as Map<String, dynamic>;
            if (profileData['must_change_password'] == true && mounted) {
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (ctx) => ChangePasswordModal(
                  onPasswordChanged: () {
                    Navigator.of(ctx).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Password aggiornata con successo!'),
                        backgroundColor: Color(0xFF2ABFBF),
                      ),
                    );
                  },
                ),
              );
            }
          }
        } catch (e) {
          debugPrint('Error checking must_change_password: $e');
        }
      }
    } catch (e) {
      // Network error: mantieni i dati esistenti in memoria
      debugPrint('[Home] _loadData error (keeping cached data): $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isFirstLoad = false;
        });
      }
      return;
    }
  }

  /// Polling silenzioso: aggiorna conversazioni senza mostrare loading.
  Future<void> _loadDataSilent() async {
    try {
      final results = await Future.wait([
        _chatService.getConversations(),
        _chatService.getCurrentUser(),
        _chatService.getNotificationBadgeCount(),
      ]);
      if (!mounted) return;
      final user = results[1] as UserModel?;
      if (user != null) {
        await AuthService.setCurrentUserId(user.id);
      }
      final newConversations = results[0] as List<ConversationModel>;
      if (mounted && _conversations.isNotEmpty) {
        for (final newConv in newConversations) {
          ConversationModel? oldConv;
          try {
            oldConv = _conversations.firstWhere((c) => c.id == newConv.id);
          } on StateError {
            oldConv = null;
          }
          final oldUnread = oldConv?.unreadCount ?? 0;
          final newUnread = newConv.unreadCount;
          if (newUnread > oldUnread && newUnread > 0) {
            final lastMessage = newConv.lastMessage;
            final messageId = lastMessage?.id?.toString();
            final senderId = lastMessage?.senderId;
            final currentUserId = _currentUser?.id;
            if (senderId != null && currentUserId != null && senderId == currentUserId) continue;
            final senderName = newConv.displayNameFor(_currentUser?.id);
            final lastMsg = _lastMessageToMap(lastMessage);
            final icon = _getNotificationIcon(lastMessage?.messageType ?? 'text');
            final isCurrentlyOpenChat =
                ChatDetailScreen.currentOpenConversationId == newConv.id;
            if (mounted && !isCurrentlyOpenChat) {
              debugPrint('[NotifDedup] messageId=$messageId alreadyNotified=${messageId != null && _notifiedMessageIds.contains(messageId)} notifiedCount=${_notifiedMessageIds.length}');
              if (messageId != null && _notifiedMessageIds.contains(messageId)) continue;
              if (messageId != null) _notifiedMessageIds.add(messageId);
              // Mantieni solo gli ultimi 50 per evitare memory leak
              if (_notifiedMessageIds.length > 50) {
                _notifiedMessageIds.remove(_notifiedMessageIds.first);
              }
              ChatSoundService().tryPlayIncoming(
                messageId: messageId,
                senderId: senderId,
                currentUserId: currentUserId,
              );
              final preview = lastMessage?.messageType == 'image' ? '📷 Immagine'
                  : lastMessage?.messageType == 'video' ? '🎥 Video'
                  : lastMessage?.messageType == 'audio' ? '🎵 Audio'
                  : lastMessage?.messageType == 'file' ? '📎 Documento'
                  : lastMessage?.messageType == 'location' ? '📍 Posizione'
                  : lastMessage?.content ?? '';
              // Mostra il banner solo se l'app è in background; in foreground solo il suono
              final isForeground = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
              final isOnChatTab = _currentNavIndex == 0;
              if (!isForeground || !isOnChatTab) {
                await LocalNotificationService.instance.show(
                  title: senderName,
                  body: preview.isNotEmpty ? preview : 'Nuovo messaggio',
                  payload: newConv.id,
                );
              }
            }
          }
        }
      }
      // E2E: encrypted last message preview — use home preview only if timestamp matches last message
      final prefs = await SharedPreferences.getInstance();
      for (final conv in newConversations) {
        if (conv.lastMessage == null) {
          await prefs.remove('scp_home_preview_${conv.id}');
        }
        final wasCleared = prefs.getBool('scp_chat_cleared_${conv.id}') ?? false;
        if (wasCleared && conv.lastMessage != null) {
          conv.lastMessage!.content = '';
          await prefs.remove('scp_chat_cleared_${conv.id}');
        }
        final lm = conv.lastMessage;
        if (lm != null &&
            lm.contentEncryptedB64 != null &&
            lm.contentEncryptedB64!.isNotEmpty) {
          final lastMsgTs = lm.createdAt?.toIso8601String();
          final raw = prefs.getString('scp_home_preview_${conv.id}');
          if (raw != null && lastMsgTs != null) {
            try {
              final decoded = jsonDecode(raw) as Map<String, dynamic>?;
              final savedTs = decoded?['ts']?.toString();
              final content = decoded?['content']?.toString();
              final cleanContent = (content ?? '').replaceAll('🔒 ', '').replaceAll('🔒', '');
              if (savedTs == lastMsgTs && cleanContent.isNotEmpty) {
                lm.content = cleanContent;
          } else {
              lm.content = '🔒 Messaggio cifrato';
            }
          } catch (_) {
            lm.content = '🔒 Messaggio cifrato';
          }
          } else {
            lm.content = '';
          }
        }
      }
      if (!mounted) return;
      final updatedConversations = newConversations.map((newConv) {
        final existingList = _conversations.where((c) => c.id == newConv.id).toList();
        final existing = existingList.isNotEmpty ? existingList.first : null;
        if (existing == null) return newConv;
        return ConversationModel(
          id: newConv.id,
          convType: newConv.convType,
          name: newConv.name,
          groupAvatarUrl: newConv.groupAvatarUrl,
          participants: newConv.participants,
          lastMessage: newConv.lastMessage,
          unreadCount: newConv.unreadCount,
          isMuted: newConv.isMuted || existing.isMuted,
          isLocked: newConv.isLocked,
          isFavorite: newConv.isFavorite,
          createdAt: newConv.createdAt,
          createdById: newConv.createdById,
        );
      }).toList();
      bool conversationsChanged = true;
      setState(() {
        if (conversationsChanged) _conversations = updatedConversations;
        _currentUser = user;
        _notificationCount = results[2] as int;
      });
      ConversationCacheService.instance.update(_conversations);
      _updateAppBadge();
    } catch (e) {
      debugPrint('[Home] _loadDataSilent error (keeping cached data): $e');
    }
  }

  void _updateAppBadge() {
    final totalUnread = _conversations.fold<int>(0, (sum, c) => sum + (c.unreadCount));
    if (totalUnread > 0) {
      FlutterAppBadger.updateBadgeCount(totalUnread);
      debugPrint('[Badge] sync unread count = $totalUnread');
    } else {
      FlutterAppBadger.removeBadge();
      debugPrint('[Badge] clear badge');
    }
  }

  Map<String, dynamic>? _lastMessageToMap(LastMessage? lastMessage) {
    if (lastMessage == null) return null;
    return {
      'message_type': lastMessage.messageType ?? 'text',
      'content': lastMessage.content ?? '',
      'created_at': lastMessage.createdAt?.toIso8601String() ?? '',
      'has_encrypted_attachment': lastMessage.hasEncryptedAttachment,
    };
  }

  String _getNotificationPreview(Map<String, dynamic>? lastMessage) {
    if (lastMessage == null) return l10n.t('new_message');

    final type = lastMessage['message_type']?.toString() ?? 'text';
    final content = lastMessage['content']?.toString() ?? '';
    final createdAt = lastMessage['created_at']?.toString() ?? '';

    if (lastMessage['has_encrypted_attachment'] == true) {
      return ChatDetailScreen.encryptedAttachmentPreviewText(
        lastMessage['message_type']?.toString(),
      );
    }

    String dateLabel = '';
    try {
      final dt = DateTime.parse(createdAt).toLocal();
      dateLabel = ' del ${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
    } catch (_) {}

    switch (type) {
      case 'image':
        return '📸 Foto$dateLabel';
      case 'video':
        return '▶️ Video$dateLabel';
      case 'audio':
        return '🎵 Audio$dateLabel';
      case 'voice':
        return '🎤 Vocale$dateLabel';
      case 'location':
        return '📍 Posizione';
      case 'contact':
        return '👤 Contatto';
      case 'file':
        final fileName = content.trim().isNotEmpty ? content.trim() : 'Documento';
        return '📎 $fileName';
      default:
        return content.trim().isNotEmpty ? content.trim() : l10n.t('new_message');
    }
  }

  IconData _getNotificationIcon(String messageType) {
    switch (messageType) {
      case 'image':
        return Icons.photo_rounded;
      case 'video':
        return Icons.videocam_rounded;
      case 'audio':
        return Icons.headphones_rounded;
      case 'voice':
        return Icons.mic_rounded;
      case 'file':
        return Icons.insert_drive_file_rounded;
      case 'location':
        return Icons.location_on_rounded;
      case 'contact':
        return Icons.person_rounded;
      default:
        return Icons.chat_bubble_rounded;
    }
  }

  Widget _buildNotificationPreview(Map<String, dynamic>? lastMessage) {
    if (lastMessage == null) {
      return Text(
        l10n.t('new_message'),
        style: const TextStyle(color: Colors.white70, fontSize: 13, decoration: TextDecoration.none),
      );
    }
    final type = lastMessage['message_type']?.toString() ?? 'text';
    final content = lastMessage['content']?.toString() ?? '';

    const style = TextStyle(
      color: Colors.white70,
      fontSize: 13,
      decoration: TextDecoration.none,
    );

    if (lastMessage['has_encrypted_attachment'] == true) {
      final preview = ChatDetailScreen.encryptedAttachmentPreviewText(
        lastMessage['message_type']?.toString(),
      );
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_rounded, size: 14, color: Colors.white70),
          const SizedBox(width: 4),
          Flexible(
            child: Text(preview, style: style, overflow: TextOverflow.ellipsis),
          ),
        ],
      );
    }

    switch (type) {
      case 'image':
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_rounded, size: 14, color: Colors.white70),
            SizedBox(width: 4),
            Text('Foto', style: style),
          ],
        );
      case 'video':
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.play_circle_rounded, size: 14, color: Colors.white70),
            SizedBox(width: 4),
            Text('Video', style: style),
          ],
        );
      case 'audio':
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.headphones_rounded, size: 14, color: Colors.white70),
            SizedBox(width: 4),
            Text('Audio', style: style),
          ],
        );
      case 'voice':
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mic_rounded, size: 14, color: Colors.white70),
            SizedBox(width: 4),
            Text('Vocale', style: style),
          ],
        );
      case 'location':
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.location_on_rounded, size: 14, color: Colors.white70),
            SizedBox(width: 4),
            Text('Posizione', style: style),
          ],
        );
      case 'contact':
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.person_rounded, size: 14, color: Colors.white70),
            SizedBox(width: 4),
            Text('Contatto', style: style),
          ],
        );
      case 'file': {
        final fileName = content.isNotEmpty ? content : 'Documento';
        final ext = fileName.split('.').last.toLowerCase();
        IconData icon;
        switch (ext) {
          case 'pdf':
            icon = Icons.picture_as_pdf_rounded;
            break;
          case 'doc':
          case 'docx':
            icon = Icons.description_rounded;
            break;
          case 'xls':
          case 'xlsx':
            icon = Icons.table_chart_rounded;
            break;
          case 'ppt':
          case 'pptx':
            icon = Icons.slideshow_rounded;
            break;
          default:
            icon = Icons.attach_file_rounded;
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white70),
            const SizedBox(width: 4),
            Flexible(
              child: Text(fileName, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        );
      }
      default:
        return Text(
          content.isNotEmpty ? content : l10n.t('new_message'),
          style: style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
    }
  }

  String _notificationBodyText(Map<String, dynamic>? lastMsg) {
    if (lastMsg == null) return 'Nuovo messaggio';
    final type = lastMsg['message_type'] ?? 'text';
    switch (type) {
      case 'image': return '📷 Immagine';
      case 'video': return '🎥 Video';
      case 'audio': return '🎵 Audio';
      case 'file': return '📎 File';
      case 'location': return '📍 Posizione';
      default:
        final content = lastMsg['content']?.toString() ?? '';
        return content.isNotEmpty ? content : 'Nuovo messaggio';
    }
  }

  Widget _getFilePreviewIcon(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    String? assetPath;

    switch (ext) {
      case 'pdf':
        assetPath = 'media/pdf_icon.png';
        break;
      case 'doc':
      case 'docx':
        assetPath = 'media/word_icon.png';
        break;
      case 'xls':
      case 'xlsx':
        assetPath = 'media/excel_icon.png';
        break;
      case 'ppt':
      case 'pptx':
        assetPath = 'media/ppt_icon.png';
        break;
      default:
        return const Icon(Icons.attach_file_rounded, size: 16, color: Color(0xFF9E9E9E));
    }

    return Image.asset(
      assetPath,
      width: 16,
      height: 16,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => const Icon(Icons.attach_file_rounded, size: 16, color: Color(0xFF9E9E9E)),
    );
  }

  /// Converte ConversationModel nel formato Map usato da _buildLastMessagePreview.
  Map<String, dynamic> _conversationToMap(ConversationModel c) {
    final lm = c.lastMessage;
    return {
      'id': c.id,
      'last_message': lm != null
          ? {
              'message_type': lm.messageType ?? 'text',
              'content': lm.content ?? '',
              'has_encrypted_attachment': lm.hasEncryptedAttachment,
              'content_encrypted': lm.contentEncryptedB64 != null && lm.contentEncryptedB64!.isNotEmpty,
            }
          : null,
      'unread_count': c.unreadCount,
    };
  }

  String _getLastMessagePreviewText(Map<String, dynamic> conversation) {
    final lastMessage = conversation['last_message'];
    if (lastMessage == null) return l10n.t('no_message');
    final content = (lastMessage['content']?.toString() ?? '').trim();
    final isEncrypted = lastMessage['content_encrypted'] == true || lastMessage['has_encrypted_attachment'] == true;
    if (content.isEmpty && isEncrypted) return 'Messaggio cifrato';
    if (lastMessage['has_encrypted_attachment'] == true) {
      return ChatDetailScreen.encryptedAttachmentPreviewText(
        lastMessage['message_type']?.toString(),
      );
    }
    final type = lastMessage['message_type']?.toString() ?? 'text';
    switch (type) {
      case 'image': return 'Foto';
      case 'video': return 'Video';
      case 'audio': return 'Audio';
      case 'voice': return 'Vocale';
      case 'location': return 'Posizione';
      case 'contact': return 'Contatto';
      case 'file': return content.isNotEmpty ? content : 'Documento';
      default: return content.isNotEmpty ? content : l10n.t('no_message');
    }
  }

  Widget _buildLastMessagePreview(Map<String, dynamic> conversation) {
    final convId = conversation['id']?.toString();
    final isTyping = convId != null && (_typingConversations[convId] == true);
    final isRecording = convId != null && (_recordingConversations[convId] == true);

    if (isRecording) {
      return Row(
        children: [
          Icon(Icons.mic, size: 16, color: Colors.grey[500]),
          const SizedBox(width: 4),
          Text(
            'Sta registrando...',
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey[500],
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      );
    }
    if (isTyping) {
      return Row(
        children: [
          Icon(Icons.more_horiz, size: 16, color: Colors.grey[500]),
          const SizedBox(width: 4),
          Text(
            'Sta scrivendo...',
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey[500],
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      );
    }

    final lastMessage = conversation['last_message'];
    if (lastMessage == null) {
      return Text(l10n.t('no_message'), style: const TextStyle(color: Color(0xFF9E9E9E), fontSize: 13));
    }
    final content = lastMessage['content']?.toString() ?? '';
    final isEncrypted = lastMessage['content_encrypted'] == true || lastMessage['has_encrypted_attachment'] == true;
    final trimmedContent = content.trim();
    if (content.trim().isEmpty && isEncrypted) {
      return const Row(
        children: [
          Icon(Icons.lock_rounded, size: 16, color: Color(0xFF9E9E9E)),
          SizedBox(width: 4),
          Text('Messaggio cifrato', style: TextStyle(color: Color(0xFF9E9E9E), fontSize: 13)),
        ],
      );
    }
    // Placeholder cifrato con/senza emoji: mostra sempre icona grigia come "Immagine cifrata"
    if ((trimmedContent == '🔒 Messaggio cifrato' || trimmedContent == 'Messaggio cifrato') && isEncrypted) {
      return const Row(
        children: [
          Icon(Icons.lock_rounded, size: 16, color: Color(0xFF9E9E9E)),
          SizedBox(width: 4),
          Text('Messaggio cifrato', style: TextStyle(color: Color(0xFF9E9E9E), fontSize: 13)),
        ],
      );
    }
    if (content.trim().isEmpty) {
      return Text(l10n.t('no_message'), style: TextStyle(color: Colors.grey[400], fontStyle: FontStyle.italic, fontSize: 13));
    }

    final type = lastMessage['message_type']?.toString() ?? 'text';
    final bool hasUnread = (conversation['unread_count'] ?? 0) > 0;

    final textStyle = TextStyle(
      color: hasUnread ? const Color(0xFF1A2B4A) : const Color(0xFF9E9E9E),
      fontSize: 13,
      fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w400,
    );

    if (lastMessage['has_encrypted_attachment'] == true) {
      final type = lastMessage['message_type']?.toString();
      final label = ChatDetailScreen.encryptedAttachmentPreviewLabel(type);
      final typeIcon = _getNotificationIcon(type ?? '');
      return Row(
        children: [
          const Icon(Icons.lock_rounded, size: 16, color: Color(0xFF9E9E9E)),
          const SizedBox(width: 4),
          Icon(typeIcon, size: 16, color: const Color(0xFF9E9E9E)),
          const SizedBox(width: 4),
          Flexible(
            child: Text(label, style: textStyle, overflow: TextOverflow.ellipsis),
          ),
        ],
      );
    }

    switch (type) {
      case 'image':
        return Row(
          children: [
            const Icon(Icons.photo_rounded, size: 16, color: Color(0xFF9E9E9E)),
            const SizedBox(width: 4),
            Text('Foto', style: textStyle),
          ],
        );
      case 'video':
        return Row(
          children: [
            const Icon(Icons.play_circle_rounded, size: 16, color: Color(0xFF9E9E9E)),
            const SizedBox(width: 4),
            Text('Video', style: textStyle),
          ],
        );
      case 'audio':
        return Row(
          children: [
            const Icon(Icons.headphones_rounded, size: 16, color: Color(0xFF9E9E9E)),
            const SizedBox(width: 4),
            Text('Audio', style: textStyle),
          ],
        );
      case 'voice':
        return Row(
          children: [
            const Icon(Icons.mic_rounded, size: 16, color: Color(0xFF9E9E9E)),
            const SizedBox(width: 4),
            Text('Vocale', style: textStyle),
          ],
        );
      case 'location':
        return Row(
          children: [
            const Icon(Icons.location_on_rounded, size: 16, color: Color(0xFF9E9E9E)),
            const SizedBox(width: 4),
            Text('Posizione', style: textStyle),
          ],
        );
      case 'contact':
        return Row(
          children: [
            const Icon(Icons.person_rounded, size: 16, color: Color(0xFF9E9E9E)),
            const SizedBox(width: 4),
            Text('Contatto', style: textStyle),
          ],
        );
      case 'file':
        final fileName = content.isNotEmpty ? content : 'Documento';
        return Row(
          children: [
            _getFilePreviewIcon(fileName),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                fileName,
                style: textStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        );
      default:
        return Text(
          content.isNotEmpty ? content : l10n.t('no_message'),
          style: textStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
    }
  }

  List<ConversationModel> get _filteredConversations {
    if (_isLockedMode) {
      return _conversations.where((c) => c.isLocked).toList();
    }
    final base = _conversations.where((c) => !c.isLocked).toList();
    List<ConversationModel> list;
    switch (_chatFilter) {
      case ChatFilter.all:
        list = base;
        break;
      case ChatFilter.group:
        list = base.where((c) => c.convType == 'group').toList();
        break;
      case ChatFilter.favorites:
        list = base.where((c) => c.isFavorite).toList();
        break;
    }

    if (_searchQuery.isNotEmpty) {
      list = list
          .where((c) => c.displayName
              .toLowerCase()
              .contains(_searchQuery.toLowerCase()))
          .toList();
    }

    return list;
  }

  int get _totalUnreadCount {
    return _conversations.fold(0, (sum, c) => sum + c.unreadCount);
  }

  Future<void> _tryUnlockWithPin(String pin) async {
    if (pin.length < 6 || int.tryParse(pin) == null) return;
    try {
      final response = await ApiService().put('/chat/lock-pin/', body: {'pin': pin});
      if (response['valid'] == true) {
        _searchController.clear();
        if (mounted) FocusScope.of(context).unfocus();
        setState(() {
          _searchQuery = '';
          _isLockedMode = true;
        });
      } else {
        _searchController.clear();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('PIN errato'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('PIN unlock error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Errore di rete'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _onConversationTap(ConversationModel conversation) async {
    if (_isNavigating) return;
    _isNavigating = true;
    try {
      // Naviga SUBITO senza aspettare nulla
      Navigator.of(context).pushNamed(
        AppRouter.chatDetail,
        arguments: {
          'conversationId': conversation.id,
          'conversation': conversation,
          'onMarkedAsRead': () {
            if (mounted) _loadDataSilent();
          },
        },
      ).then((_) {
        _isNavigating = false;
        if (mounted) _loadData();
      });

      // Esegui createPrivateConversation IN BACKGROUND dopo la navigazione
      final other = conversation.otherParticipant(_currentUser?.id);
      final otherUserId = other?.userId;
      final isPrivate = !conversation.isGroup && otherUserId != null;
      if (isPrivate) {
        _chatService.createPrivateConversation(otherUserId!, isNew: false)
            .then((response) async {
              if (response != null && response['session_reset'] == true) {
                await SessionManager().deleteSession(otherUserId!,
                    reason: 'session_reset_before_open_chat_reactivated_hidden');
                debugPrint('[E2E] Session reset before opening chat (re-activated hidden) for user $otherUserId');
              }
            })
            .catchError((_) {});
      }
    } catch (_) {
      _isNavigating = false;
    }
  }

  void _deleteConversation(ConversationModel conv) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l10n.t('delete_chat'), style: const TextStyle(fontWeight: FontWeight.w700)),
        content: const Text(
          'Vuoi eliminare questa conversazione? L\'azione è irreversibile.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.t('cancel')),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              setState(() => _conversations.removeWhere((c) => c.id == conv.id));

              // Reset sessione E2E con l'altro utente
              final other = conv.otherParticipant(_currentUser?.id);
              final otherUserId = other?.userId;
              if (otherUserId != null && !conv.isGroup) {
                await SessionManager().deleteSession(otherUserId, reason: 'conversation_deleted');
                debugPrint('[E2E] Session deleted on conversation delete for user $otherUserId');
              }

              try {
                await ApiService().delete('/chat/conversations/${conv.id}/leave/');
              } catch (_) {
                if (mounted) setState(() => _conversations.insert(0, conv));
              }
            },
            child: Text(l10n.t('delete')),
          ),
        ],
      ),
    );
  }

  void _showMoreActions(ConversationModel conv) {
    final displayName = conv.displayNameFor(_currentUser?.id);
    final initial = displayName.isNotEmpty ? displayName.substring(0, 1).toUpperCase() : '?';
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                children: [
                  UserAvatarWidget(
                    avatarUrl: conv.otherParticipant(_currentUser?.id)?.avatar,
                    displayName: conv.displayNameFor(_currentUser?.id),
                    size: 48,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    displayName,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, thickness: 0.5, color: Color(0xFFEEEEEE)),
            _moreActionTile(
              ctx,
              Icons.notifications_off_outlined,
              conv.isMuted ? l10n.t('unmute_notifications_short') : l10n.t('mute_short'),
              Colors.orange,
              () async {
                Navigator.pop(ctx);
                try {
                  if (conv.isMuted) {
                    await ApiService().delete('/chat/conversations/${conv.id}/mute/');
                  } else {
                    await ApiService().post('/chat/conversations/${conv.id}/mute/', body: {});
                  }
                  if (mounted) {
                    setState(() {
                      final i = _conversations.indexWhere((c) => c.id == conv.id);
                      if (i >= 0) {
                        final updated = ConversationModel(
                          id: conv.id,
                          convType: conv.convType,
                          name: conv.name,
                          participants: conv.participants,
                          lastMessage: conv.lastMessage,
                          unreadCount: conv.unreadCount,
                          isMuted: !conv.isMuted,
                          isLocked: conv.isLocked,
                          isFavorite: conv.isFavorite,
                          createdAt: conv.createdAt,
                          createdById: conv.createdById,
                        );
                        _conversations = List.from(_conversations)..[i] = updated;
                      }
                    });
                  }
                } catch (_) {}
              },
            ),
            _moreActionTile(
              ctx,
              conv.isLocked ? Icons.lock_open_outlined : Icons.lock_outline,
              conv.isLocked ? l10n.t('remove_lock') : l10n.t('enable_lock'),
              Colors.purple,
              () async {
                Navigator.pop(ctx);
                try {
                  final hasPinResp = await ApiService().get('/chat/lock-pin/');
                  if (hasPinResp['has_pin'] != true) {
                    _showSetPinModal(conv);
                  } else {
                    await _toggleLock(conv);
                  }
                } catch (_) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Errore di rete')),
                    );
                  }
                }
              },
            ),
            _moreActionTile(
              ctx,
              conv.isFavorite ? Icons.favorite : Icons.favorite_border,
              conv.isFavorite ? 'Rimuovi dai preferiti' : 'Aggiungi ai preferiti',
              Colors.pink,
              () async {
                Navigator.pop(ctx);
                await _toggleFavorite(conv);
              },
            ),
            if (conv.isGroup && conv.createdById != _currentUser?.id)
              _moreActionTile(
                ctx,
                Icons.exit_to_app_rounded,
                'Abbandona Gruppo',
                Colors.deepOrange,
                () async {
                  Navigator.pop(ctx);
                  _leaveGroup(conv);
                },
              ),
            _moreActionTile(
              ctx,
              Icons.delete_forever_outlined,
              'Elimina per tutti',
              Colors.red,
              () async {
                Navigator.pop(ctx);
                _deleteForAll(conv);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _deleteForAll(ConversationModel conv) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l10n.t('delete_for_all'), style: const TextStyle(fontWeight: FontWeight.w700)),
        content: const Text(
          'Vuoi eliminare questa conversazione per tutti i partecipanti? L\'azione è irreversibile.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.t('cancel')),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              setState(() => _conversations.removeWhere((c) => c.id == conv.id));
              try {
                await ApiService().delete('/chat/conversations/${conv.id}/delete-for-all/');
              } catch (_) {
                if (mounted) setState(() => _conversations.insert(0, conv));
              }
            },
            child: Text(l10n.t('delete')),
          ),
        ],
      ),
    );
  }

  void _leaveGroup(ConversationModel conv) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Abbandona Gruppo', style: TextStyle(fontWeight: FontWeight.w700)),
        content: const Text(
          'Vuoi abbandonare questa chat di gruppo? Non riceverai più messaggi e non potrai rientrare autonomamente.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.t('cancel')),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepOrange,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              setState(() => _conversations.removeWhere((c) => c.id == conv.id));
              try {
                await ApiService().post('/chat/conversations/${conv.id}/leave/', body: {});
              } catch (_) {
                if (mounted) {
                  setState(() => _conversations.insert(0, conv));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Errore durante l\'abbandono del gruppo')),
                  );
                }
              }
            },
            child: const Text('Abbandona'),
          ),
        ],
      ),
    );
  }

  Widget _moreActionTile(
    BuildContext ctx,
    IconData icon,
    String label,
    Color color,
    VoidCallback onTap,
  ) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: 20),
      ),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      onTap: onTap,
    );
  }

  void _showSetPinModal(ConversationModel conv) {
    final pin1Controller = TextEditingController();
    final pin2Controller = TextEditingController();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 48, color: Color(0xFF2ABFBF)),
              const SizedBox(height: 12),
              const Text(
                'Crea PIN di sblocco',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                'Il PIN verrà usato per sbloccare tutte le chat riservate.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: pin1Controller,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 10,
                decoration: InputDecoration(
                  labelText: 'PIN (min. 6 cifre)',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pin2Controller,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 10,
                decoration: InputDecoration(
                  labelText: 'Conferma PIN',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2ABFBF),
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () async {
                  if (pin1Controller.text.length < 6) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('PIN troppo corto (min. 6 cifre)')),
                    );
                    return;
                  }
                  if (pin1Controller.text != pin2Controller.text) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('I PIN non corrispondono')),
                    );
                    return;
                  }
                  try {
                    await ApiService().post('/chat/lock-pin/', body: {'pin': pin1Controller.text});
                    if (ctx.mounted) Navigator.pop(ctx);
                    await _toggleLock(conv);
                  } catch (_) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Errore nel salvataggio del PIN')),
                      );
                    }
                  }
                },
                child: const Text(
                  'Salva PIN e attiva lucchetto',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggleLock(ConversationModel conv) async {
    try {
      final response = await ApiService().post('/chat/conversations/${conv.id}/lock/', body: {});
      final isLocked = response['is_locked'] == true;
      final idx = _conversations.indexWhere((c) => c.id == conv.id);
      if (idx != -1 && mounted) {
        setState(() {
          final updated = ConversationModel(
            id: conv.id,
            convType: conv.convType,
            name: conv.name,
            participants: conv.participants,
            lastMessage: conv.lastMessage,
            unreadCount: conv.unreadCount,
            isMuted: conv.isMuted,
            isLocked: isLocked,
            isFavorite: conv.isFavorite,
            createdAt: conv.createdAt,
            createdById: conv.createdById,
          );
          _conversations = List.from(_conversations)..[idx] = updated;
        });
      }
    } catch (e) {
      debugPrint('Toggle lock error: $e');
    }
  }

  Future<void> _toggleFavorite(ConversationModel conv) async {
    try {
      final response = await ApiService().post('/chat/conversations/${conv.id}/favorite/', body: {});
      final isFavorite = response['is_favorite'] == true;
      final idx = _conversations.indexWhere((c) => c.id == conv.id);
      if (idx != -1 && mounted) {
        setState(() {
          final updated = ConversationModel(
            id: conv.id,
            convType: conv.convType,
            name: conv.name,
            participants: conv.participants,
            lastMessage: conv.lastMessage,
            unreadCount: conv.unreadCount,
            isMuted: conv.isMuted,
            isLocked: conv.isLocked,
            isFavorite: isFavorite,
            createdAt: conv.createdAt,
            createdById: conv.createdById,
          );
          _conversations = List.from(_conversations)..[idx] = updated;
        });
      }
    } catch (e) {
      debugPrint('Toggle favorite error: $e');
    }
  }

  void _showExitLockModal() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Icon(Icons.lock_rounded, size: 48, color: Color(0xFF2ABFBF)),
            const SizedBox(height: 16),
            const Text(
              'Chat riservate attive',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Vuoi tornare alle chat normali?',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 15),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2ABFBF),
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: () {
                Navigator.pop(ctx);
                setState(() => _isLockedMode = false);
              },
              child: const Text(
                'Torna alle chat normali',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.t('stay_here'), style: TextStyle(color: Colors.grey[600])),
            ),
          ],
        ),
      ),
    );
  }

  void _showNewChatMenu(BuildContext context) {
    const teal = Color(0xFF2ABFBF);
    const navy = Color(0xFF1A2B4A);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.t('new_chat'),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: navy,
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: teal,
                  child: const Icon(Icons.chat_bubble_outline, color: Colors.white, size: 22),
                ),
                title: Text(
                  l10n.t('new_chat'),
                  style: TextStyle(color: navy, fontSize: 16, fontWeight: FontWeight.w500),
                ),
                trailing: const Icon(Icons.chevron_right, color: Color(0xFF9E9E9E)),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _showSingleChatSheet(context);
                },
              ),
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: teal,
                  child: const Icon(Icons.group_outlined, color: Colors.white, size: 22),
                ),
                title: Text(
                  l10n.t('new_group'),
                  style: const TextStyle(color: navy, fontSize: 16, fontWeight: FontWeight.w500),
                ),
                trailing: const Icon(Icons.chevron_right, color: Color(0xFF9E9E9E)),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _showGroupChatSheet(context);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSingleChatSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, scrollController) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: _SingleChatSheetContent(
            scrollController: scrollController,
            chatService: _chatService,
            onConversationCreated: (conversation, [otherUser]) async {
              Navigator.of(ctx).pop();
              if (!mounted) return;
              // Chi riapre la chat (Alice) deve cancellare la propria sessione verso l'altro (Bob),
              // così il prossimo messaggio farà un nuovo X3DH.
              if (conversation['session_reset'] == true && otherUser != null) {
                final otherUserId = otherUser['id'];
                if (otherUserId != null) {
                  final uid = otherUserId is int ? otherUserId : int.tryParse(otherUserId.toString());
                  if (uid != null) {
                    await SessionManager().deleteSession(uid, reason: 'session_reset_after_chat_reopen');
                    debugPrint('[E2E] Session reset after chat re-open (cleared local session toward $uid for new X3DH)');
                  }
                }
              }
              if (!mounted) return;
              await _loadData();
              if (!mounted) return;
              Navigator.of(context).pushNamed(
                AppRouter.chatDetail,
                arguments: {
                  'conversationId': conversation['id']?.toString(),
                  if (otherUser != null) 'otherUser': otherUser,
                },
              ).then((_) {
                if (mounted) _loadData();
              });
            },
            onError: (message) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
              }
            },
          ),
        ),
      ),
    );
  }

  void _showGroupChatSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, scrollController) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: _GroupChatSheetContent(
            scrollController: scrollController,
            chatService: _chatService,
            onConversationCreated: (conversation) async {
              Navigator.of(ctx).pop();
              if (!mounted) return;
              await _loadData();
              if (!mounted) return;
              Navigator.of(context).pushNamed(
                AppRouter.chatDetail,
                arguments: {'conversationId': conversation['id']?.toString()},
              ).then((_) {
                if (mounted) _loadData();
              });
            },
            onError: (message) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
              }
            },
          ),
        ),
      ),
    );
  }

  void _showBroadcastSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, scrollController) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: _BroadcastSheetContent(
            scrollController: scrollController,
            chatService: _chatService,
            onConversationCreated: (conversation) async {
              Navigator.of(ctx).pop();
              if (!mounted) return;
              await _loadData();
              if (!mounted) return;
              Navigator.of(context).pushNamed(
                AppRouter.chatDetail,
                arguments: {'conversationId': conversation['id']?.toString()},
              ).then((_) {
                if (mounted) _loadData();
              });
            },
            onError: (message) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
              }
            },
          ),
        ),
      ),
    );
  }

  void _onNavTap(int index) {
    setState(() {
      _currentNavIndex = index;
      _isLockedMode = false;
    });
    if (index == 0) {
      CryptoService.getNeedsManualRecoveryFlag().then((needsRecovery) {
        if (mounted && !needsRecovery && _e2eNeedsManualRecovery) {
          setState(() => _e2eNeedsManualRecovery = false);
        }
      });
    }
    if (index == 1) {
      _callsHistoryKey.currentState?.refresh();
      _loadMissedCallsCount();
    }
  }

  Future<void> _loadMissedCallsCount() async {
    try {
      final data = await ApiService().get('/calls/missed-count/');
      final count = data['missed_calls'];
      if (mounted) {
        setState(() => _missedCallsCount = count is int ? count : (int.tryParse(count?.toString() ?? '0') ?? 0));
      }
    } catch (_) {}
  }

  Future<void> _performSecureSessionReset() async {
    try {
      await CryptoService.clearNeedsManualRecoveryFlag();
      await SessionManager().clearAllSessions();
      final crypto = CryptoService(apiService: ApiService());
      await crypto.wipeAllKeys();
      final publicBundle = await crypto.generateAndStoreKeyBundle();
      await crypto.uploadKeyBundle(publicBundle);
      await CryptoService.clearNeedsManualRecoveryFlag();
      if (mounted) {
        setState(() => _e2eNeedsManualRecovery = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sessione sicura reimpostata. I nuovi messaggi saranno cifrati correttamente.'),
            backgroundColor: Color(0xFF2ABFBF),
          ),
        );
      }
    } catch (e) {
      debugPrint('Secure session reset error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Errore durante il reset: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Mostra la modale E2E recovery una sola volta (controllato da _hasShownRecoveryDialog).
  void _showE2ERecoveryModalIfNeeded() {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _E2ERecoveryModal(
        onReset: () async => await _performSecureSessionReset(),
        onLater: () => Navigator.of(ctx).pop(),
        onResetDone: () => Navigator.of(ctx).pop(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ));

    return Scaffold(
      extendBody: true,
      floatingActionButton: _currentNavIndex == 0
          ? Container(
              decoration: BoxDecoration(
                gradient: AppColors.buttonGradient,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.35),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _showNewChatMenu(context),
                  customBorder: const CircleBorder(),
                  child: const SizedBox(
                    width: 56,
                    height: 56,
                    child: Center(
                      child: Icon(Icons.add, color: Colors.white, size: 28),
                    ),
                  ),
                ),
              ),
            )
          : null,
      body: _currentNavIndex == 3
                ? Stack(
              children: [
                Positioned.fill(
                  child: Image.asset(
                    AppConstants.imgSfondo,
                    fit: BoxFit.cover,
                  ),
                ),
                SafeArea(
                  bottom: false,
                  child: SettingsScreen(
                    onBack: () => setState(() => _currentNavIndex = 0),
                  ),
                ),
              ],
            )
          : _currentNavIndex == 1
              ? Stack(
                  children: [
                    Positioned.fill(
                      child: Image.asset(
                        AppConstants.imgSfondo,
                        fit: BoxFit.cover,
                      ),
                    ),
                    SafeArea(
                      bottom: false,
                      child: Column(
                        children: [
                          const SizedBox(height: 4),
                          HomeHeader(
                            userAvatarUrl: _currentUser?.avatar,
                            firstName: _currentUser?.firstName,
                            lastName: _currentUser?.lastName,
                            notificationCount: _totalUnreadCount,
                            onNotificationTap: () {},
                            onAvatarTap: () {},
                            isLockedMode: _isLockedMode,
                            lockAnimation: _lockAnimController,
                            onLockTap: _showExitLockModal,
                          ),
                          Expanded(
                            child: CallsHistoryScreen(
                              key: _callsHistoryKey,
                              onMissedCountChanged: _loadMissedCallsCount,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              : _currentNavIndex == 2
                  ? Stack(
                      children: [
                        Positioned.fill(
                          child: Image.asset(
                            AppConstants.imgSfondo,
                            fit: BoxFit.cover,
                          ),
                        ),
                        SafeArea(
                          bottom: false,
                          child: Column(
                            children: [
                              const SizedBox(height: 4),
                              HomeHeader(
                                userAvatarUrl: _currentUser?.avatar,
                                firstName: _currentUser?.firstName,
                                lastName: _currentUser?.lastName,
                                notificationCount: _totalUnreadCount,
                                onNotificationTap: () {},
                                onAvatarTap: () {},
                                isLockedMode: _isLockedMode,
                                lockAnimation: _lockAnimController,
                                onLockTap: _showExitLockModal,
                              ),
                              Expanded(child: SecurityMonitorScreen()),
                            ],
                          ),
                        ),
                      ],
                    )
                  : Stack(
              children: [
                Positioned.fill(
                  child: Image.asset(
                    AppConstants.imgSfondo,
                    fit: BoxFit.cover,
                  ),
                ),
                SafeArea(
                  bottom: false,
                  child: Column(
                    children: [
                      const SizedBox(height: 4),
                      HomeHeader(
                        userAvatarUrl: _currentUser?.avatar,
                        firstName: _currentUser?.firstName,
                        lastName: _currentUser?.lastName,
                        notificationCount: _totalUnreadCount,
                        onNotificationTap: () {},
                        onAvatarTap: () {},
                        isLockedMode: _isLockedMode,
                        lockAnimation: _lockAnimController,
                        onLockTap: _showExitLockModal,
                      ),
                      const SizedBox(height: 12),
                      ChatSearchBar(
                        controller: _searchController,
                        onChanged: (value) {
                          setState(() => _searchQuery = value);
                          if (value.length >= 6 && int.tryParse(value) != null) {
                            _tryUnlockWithPin(value);
                          }
                        },
                      ),
                      const SizedBox(height: 12),
                      if (!_isLockedMode)
                        ChatTabBar(
                          selectedFilter: _chatFilter,
                          onFilterChanged: (filter) {
                            setState(() => _chatFilter = filter);
                          },
                          allCount: _conversations.where((c) => !c.isLocked).length,
                          groupCount: _conversations.where((c) => !c.isLocked && c.convType == 'group').length,
                          favoritesCount: _conversations.where((c) => !c.isLocked && c.isFavorite).length,
                        ),
                      if (!_isLockedMode) const SizedBox(height: 4),
                      Expanded(
                        child: RefreshIndicator(
                          color: AppColors.primary,
                          onRefresh: _loadData,
                          child: CustomScrollView(
                            physics: const AlwaysScrollableScrollPhysics(
                              parent: BouncingScrollPhysics(),
                            ),
                            slivers: [
                              if (_isLockedMode && _filteredConversations.isEmpty)
                                SliverFillRemaining(
                                  child: Center(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.lock_outline_rounded,
                                          size: 72,
                                          color: const Color(0xFF2ABFBF).withOpacity(0.4),
                                        ),
                                        const SizedBox(height: 20),
                                        const Text(
                                          'No locked chats',
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFF1A2B4A),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        const Text(
                                          'Tap the 🔒 icon in the header\nto return to your chats',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: Colors.grey,
                                            height: 1.5,
                                          ),
                                        ),
                                        const SizedBox(height: 28),
                                        GestureDetector(
                                          onTap: () => setState(() => _isLockedMode = false),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF2ABFBF).withOpacity(0.1),
                                              borderRadius: BorderRadius.circular(20),
                                              border: Border.all(color: const Color(0xFF2ABFBF).withOpacity(0.4)),
                                            ),
                                            child: const Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.lock_open_rounded, color: Color(0xFF2ABFBF), size: 18),
                                                SizedBox(width: 8),
                                                Text(
                                                  'Back to chats',
                                                  style: TextStyle(
                                                    color: Color(0xFF2ABFBF),
                                                    fontWeight: FontWeight.w700,
                                                    fontSize: 15,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              else
                                ChatListView(
                                  conversations: _filteredConversations,
                                  currentUserId: _currentUser?.id,
                                  isLoading: _isLoading,
                                  onConversationTap: _onConversationTap,
                                  onConversationDelete: _deleteConversation,
                                  onConversationMore: _showMoreActions,
                                  previewBuilder: (c) => _buildLastMessagePreview(_conversationToMap(c)),
                                ),
                              const SliverPadding(
                                padding: EdgeInsets.only(bottom: 80),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(30),
            topRight: Radius.circular(30),
          ),
          boxShadow: [
            BoxShadow(
              color: Color(0x15000000),
              blurRadius: 10,
              offset: Offset(0, -2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(30),
            topRight: Radius.circular(30),
          ),
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SecureChatBottomNavBar(
              currentIndex: _currentNavIndex,
              onTap: _onNavTap,
              items: [
                BottomNavItem(
                  icon: Icons.forum_outlined,
                  activeIcon: Icons.forum,
                  label: l10n.t('chats'),
                ),
                BottomNavItem(
                  icon: Icons.call_outlined,
                  activeIcon: Icons.call,
                  label: l10n.t('calls'),
                  badgeCount: _missedCallsCount,
                ),
                BottomNavItem(
                  icon: Icons.verified_user_outlined,
                  activeIcon: Icons.verified_user,
                  label: l10n.t('security'),
                ),
                BottomNavItem(
                  icon: Icons.settings_outlined,
                  activeIcon: Icons.settings,
                  label: l10n.t('settings'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Modale centrata per recovery E2E. Stile coerente con il design dell'app (teal/navy, senza rosso aggressivo).
class _E2ERecoveryModal extends StatefulWidget {
  final Future<void> Function() onReset;
  final VoidCallback onLater;
  final VoidCallback onResetDone;

  const _E2ERecoveryModal({
    required this.onReset,
    required this.onLater,
    required this.onResetDone,
  });

  @override
  State<_E2ERecoveryModal> createState() => _E2ERecoveryModalState();
}

class _E2ERecoveryModalState extends State<_E2ERecoveryModal> {
  bool _loading = false;
  static const Color _teal = Color(0xFF2ABFBF);
  static const Color _navy = Color(0xFF1A2B4A);

  Future<void> _handleReset() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      await widget.onReset();
      if (!mounted) return;
      widget.onResetDone();
    } catch (_) {
      // Errore già mostrato da _performSecureSessionReset (snackbar)
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          Icon(Icons.security_rounded, color: _teal, size: 24),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Sessione sicura da reimpostare',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF1A2B4A)),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Text(
          'Le chiavi storiche di questo dispositivo non sono più disponibili. I messaggi precedenti non possono essere recuperati su questo device. Per continuare con i nuovi messaggi, reimposta la sessione sicura.',
          style: TextStyle(fontSize: 15, color: Colors.grey[800], height: 1.4),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => widget.onLater(),
          child: Text('Più tardi', style: TextStyle(color: Colors.grey[700])),
        ),
        ElevatedButton(
          onPressed: _loading ? null : _handleReset,
          style: ElevatedButton.styleFrom(
            backgroundColor: _teal,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Reimposta sessione sicura'),
        ),
      ],
    );
  }
}

// --- Single Chat Sheet (list users, group by letter) ---

class _SingleChatSheetContent extends StatefulWidget {
  final ScrollController scrollController;
  final ChatService chatService;
  final Future<void> Function(Map<String, dynamic> conversation, [Map<String, dynamic>? otherUser]) onConversationCreated;
  final void Function(String message) onError;

  const _SingleChatSheetContent({
    required this.scrollController,
    required this.chatService,
    required this.onConversationCreated,
    required this.onError,
  });

  @override
  State<_SingleChatSheetContent> createState() => _SingleChatSheetContentState();
}

class _SingleChatSheetContentState extends State<_SingleChatSheetContent> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _allUsers = [];
  List<Map<String, dynamic>> _filteredUsers = [];
  bool _loading = false;
  bool _creating = false;
  Timer? _debounce;

  AppLocalizations get l10n => AppLocalizations.of(context)!;
  static const Color _teal = Color(0xFF2ABFBF);
  static const Color _navy = Color(0xFF1A2B4A);
  static const Color _subtitleGray = Color(0xFF9E9E9E);
  static const Color _searchBg = Color(0xFFF5F5F5);

  @override
  void initState() {
    super.initState();
    _loadAllUsers();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadAllUsers() async {
    setState(() => _loading = true);
    final users = await widget.chatService.searchUsers('');
    if (!mounted) return;
    users.sort((a, b) {
      final na = _sortName(a);
      final nb = _sortName(b);
      return na.compareTo(nb);
    });
    setState(() {
      _allUsers = users;
      _filteredUsers = users;
      _loading = false;
    });
  }

  String _sortName(Map<String, dynamic> u) {
    final first = (u['first_name'] as String? ?? '').trim();
    final last = (u['last_name'] as String? ?? '').trim();
    final name = '$first $last'.trim();
    if (name.isNotEmpty) return name.toLowerCase();
    return (u['email'] as String? ?? '').toLowerCase();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      final q = value.trim().toLowerCase();
      setState(() {
        if (q.isEmpty) {
          _filteredUsers = List.from(_allUsers);
        } else {
          _filteredUsers = _allUsers.where((u) {
            final name = _sortName(u);
            final email = (u['email'] as String? ?? '').toLowerCase();
            return name.contains(q) || email.contains(q);
          }).toList();
        }
      });
    });
  }

  Future<void> _onUserTap(Map<String, dynamic> user) async {
    final id = user['id'] as int?;
    if (id == null) return;
    setState(() => _creating = true);
    try {
      final conv = await widget.chatService.createPrivateConversation(id, isNew: true);
      if (!mounted) return;
      if (conv != null) {
        widget.onConversationCreated(conv, user);
      } else {
        widget.onError(l10n.t('cannot_start_chat'));
      }
    } on ApiException catch (e) {
      if (mounted) widget.onError(e.message);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  String _initials(Map<String, dynamic> u) {
    final first = (u['first_name'] as String? ?? '').trim();
    final last = (u['last_name'] as String? ?? '').trim();
    if (first.isNotEmpty && last.isNotEmpty) {
      return '${first[0]}${last[0]}'.toUpperCase();
    }
    if (first.isNotEmpty) return first[0].toUpperCase();
    final email = (u['email'] as String? ?? '').trim();
    if (email.isNotEmpty) return email[0].toUpperCase();
    return '?';
  }

  String _title(Map<String, dynamic> u) {
    final name = '${u['first_name'] ?? ''} ${u['last_name'] ?? ''}'.trim();
    if (name.isNotEmpty) return name;
    return u['username'] as String? ?? u['email'] as String? ?? '';
  }

  Map<String, List<Map<String, dynamic>>> _groupByLetter(List<Map<String, dynamic>> users) {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final u in users) {
      final name = _title(u);
      final letter = name.isEmpty ? '?' : name[0].toUpperCase();
      map.putIfAbsent(letter, () => []).add(u);
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      behavior: HitTestBehavior.opaque,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
            child: Row(
              children: [
                const Expanded(child: SizedBox()),
                Text(
                  l10n.t('new_chat'),
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: _navy),
              ),
              const Expanded(child: SizedBox()),
              IconButton(
                icon: const Icon(Icons.close, color: _navy),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            decoration: BoxDecoration(
              color: _searchBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: l10n.t('search_by_name'),
                hintStyle: TextStyle(color: _subtitleGray, fontSize: 15),
                prefixIcon: Icon(Icons.search, color: _subtitleGray, size: 22),
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: _teal, strokeWidth: 2.5),
                )
              : _filteredUsers.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.person_search, size: 64, color: _subtitleGray.withValues(alpha: 0.6)),
                          const SizedBox(height: 12),
                          Text(
                            'Nessun utente trovato',
                            style: TextStyle(fontSize: 16, color: _subtitleGray),
                          ),
                        ],
                      ),
                    )
                  : _buildGroupedList(),
        ),
      ],
      ),
    );
  }

  Widget _buildGroupedList() {
    final grouped = _groupByLetter(_filteredUsers);
    final letters = grouped.keys.toList()..sort();

    return ListView.builder(
      controller: widget.scrollController,
      itemCount: letters.fold<int>(0, (sum, l) => sum + 1 + (grouped[l]!.length)),
      itemBuilder: (context, index) {
        int offset = 0;
        for (final letter in letters) {
          final list = grouped[letter]!;
          if (index == offset) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                letter,
                style: const TextStyle(
                  color: _teal,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            );
          }
          offset++;
          final idx = index - offset;
          if (idx < list.length) {
            final u = list[idx];
            final avatarUrl = u['avatar_url'] as String?;
            return _userTile(u, avatarUrl);
          }
          offset += list.length;
        }
        return const SizedBox.shrink();
      },
    );
  }

  static Color _getStatusColor(dynamic isOnline) {
    if (isOnline == true) return const Color(0xFF4CAF50); // Online - verde
    return const Color(0xFF9E9E9E); // Assente - grigio
  }

  Widget _userTile(Map<String, dynamic> u, String? avatarUrl) {
    return Column(
      children: [
        ListTile(
          onTap: _creating ? null : () => _onUserTap(u),
          leading: SizedBox(
            width: 48,
            height: 48,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: _teal,
                  backgroundImage: avatarUrl != null && avatarUrl.isNotEmpty
                      ? NetworkImage(avatarUrl)
                      : null,
                  child: avatarUrl != null && avatarUrl.isNotEmpty
                      ? null
                      : Text(
                          _initials(u),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: _getStatusColor(u['is_online']),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
              ],
            ),
          ),
          title: Text(
            _title(u),
            style: const TextStyle(color: _navy, fontSize: 15, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            u['email'] as String? ?? '',
            style: const TextStyle(color: _subtitleGray, fontSize: 13),
          ),
          trailing: _creating
              ? const SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(color: _teal, strokeWidth: 2),
                    ),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.chat_bubble_outline, color: _teal, size: 24),
                  onPressed: _creating ? null : () => _onUserTap(u),
                ),
        ),
        const Divider(height: 1, thickness: 0.5, color: Color(0xFFEEEEEE)),
      ],
    );
  }
}

// --- Group Chat Sheet (multi-select then name) ---

class _GroupChatSheetContent extends StatefulWidget {
  final ScrollController scrollController;
  final ChatService chatService;
  final Future<void> Function(Map<String, dynamic> conversation) onConversationCreated;
  final void Function(String message) onError;

  const _GroupChatSheetContent({
    required this.scrollController,
    required this.chatService,
    required this.onConversationCreated,
    required this.onError,
  });

  @override
  State<_GroupChatSheetContent> createState() => _GroupChatSheetContentState();
}

class _GroupChatSheetContentState extends State<_GroupChatSheetContent> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descController = TextEditingController();
  List<Map<String, dynamic>> _allUsers = [];
  List<Map<String, dynamic>> _filteredUsers = [];
  final Set<int> _selectedIds = {};
  bool _loading = false;
  bool _step2 = false;
  bool _creating = false;
  Timer? _debounce;
  File? _groupImage;

  AppLocalizations get l10n => AppLocalizations.of(context)!;
  static const Color _teal = Color(0xFF2ABFBF);
  static const Color _navy = Color(0xFF1A2B4A);
  static const Color _subtitleGray = Color(0xFF9E9E9E);
  static const Color _searchBg = Color(0xFFF5F5F5);

  @override
  void initState() {
    super.initState();
    _loadAllUsers();
    _nameController.addListener(() { if (mounted) setState(() {}); });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _loadAllUsers() async {
    setState(() => _loading = true);
    final users = await widget.chatService.searchUsers('');
    if (!mounted) return;
    users.sort((a, b) {
      final na = _sortName(a);
      final nb = _sortName(b);
      return na.compareTo(nb);
    });
    setState(() {
      _allUsers = users;
      _filteredUsers = users;
      _loading = false;
    });
  }

  String _sortName(Map<String, dynamic> u) {
    final first = (u['first_name'] as String? ?? '').trim();
    final last = (u['last_name'] as String? ?? '').trim();
    final name = '$first $last'.trim();
    if (name.isNotEmpty) return name.toLowerCase();
    return (u['email'] as String? ?? '').toLowerCase();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      final q = value.trim().toLowerCase();
      setState(() {
        if (q.isEmpty) {
          _filteredUsers = List.from(_allUsers);
        } else {
          _filteredUsers = _allUsers.where((u) {
            final name = _sortName(u);
            final email = (u['email'] as String? ?? '').toLowerCase();
            return name.contains(q) || email.contains(q);
          }).toList();
        }
      });
    });
  }

  String _title(Map<String, dynamic> u) {
    final name = '${u['first_name'] ?? ''} ${u['last_name'] ?? ''}'.trim();
    if (name.isNotEmpty) return name;
    return u['username'] as String? ?? u['email'] as String? ?? '';
  }

  String _initials(Map<String, dynamic> u) {
    final first = (u['first_name'] as String? ?? '').trim();
    final last = (u['last_name'] as String? ?? '').trim();
    if (first.isNotEmpty && last.isNotEmpty) return '${first[0]}${last[0]}'.toUpperCase();
    if (first.isNotEmpty) return first[0].toUpperCase();
    final email = (u['email'] as String? ?? '').trim();
    if (email.isNotEmpty) return email[0].toUpperCase();
    return '?';
  }

  Map<String, List<Map<String, dynamic>>> _groupByLetter(List<Map<String, dynamic>> users) {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final u in users) {
      final name = _title(u);
      final letter = name.isEmpty ? '?' : name[0].toUpperCase();
      map.putIfAbsent(letter, () => []).add(u);
    }
    return map;
  }

  Future<void> _pickGroupImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 80);
    if (picked != null && mounted) {
      setState(() => _groupImage = File(picked.path));
    }
  }

  Future<void> _createGroup() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      widget.onError('Inserisci il nome del gruppo');
      return;
    }
    setState(() => _creating = true);
    try {
      final conv = await widget.chatService.createGroupConversation(
        _selectedIds.toList(),
        name: name,
        description: _descController.text.trim().isEmpty ? null : _descController.text.trim(),
      );
      if (!mounted) return;
      if (conv != null) {
        // Upload foto gruppo se selezionata
        if (_groupImage != null) {
          try {
            final convId = conv['id']?.toString();
            if (convId != null) {
              final token = ApiService().accessToken;
              if (token != null) {
                final request = http.MultipartRequest(
                  'POST',
                  Uri.parse('${AppConstants.baseUrl}/chat/conversations/$convId/avatar/'),
                );
                request.headers['Authorization'] = 'Bearer $token';
                request.files.add(await http.MultipartFile.fromPath('avatar', _groupImage!.path));
                final response = await request.send();
                if (response.statusCode >= 200 && response.statusCode < 300) {
                  AvatarCacheService.instance.bust();
                }
              }
            }
          } catch (e) {
            debugPrint('Upload avatar gruppo fallito: $e');
          }
        }
        widget.onConversationCreated(conv);
      } else {
        widget.onError('Impossibile creare il gruppo');
      }
    } on ApiException catch (e) {
      if (mounted) widget.onError(e.message);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusScope.of(context).unfocus(),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
            child: Row(
              children: [
                const Expanded(child: SizedBox()),
                Text(
                  _step2 ? l10n.t('group_name_step') : l10n.t('new_group'),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: _navy),
                ),
                const Expanded(child: SizedBox()),
                IconButton(
                  icon: const Icon(Icons.close, color: _navy),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          if (!_step2) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              decoration: BoxDecoration(
                color: _searchBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: TextField(
                controller: _searchController,
                onChanged: _onSearchChanged,
                decoration: InputDecoration(
                  hintText: l10n.t('search_by_name'),
                  hintStyle: TextStyle(color: _subtitleGray, fontSize: 15),
                  prefixIcon: Icon(Icons.search, color: _subtitleGray, size: 22),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
              ),
            ),
          ),
          if (_selectedIds.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: _allUsers
                    .where((u) => _selectedIds.contains(u['id'] as int?))
                    .map((u) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Chip(
                            avatar: CircleAvatar(
                              backgroundColor: _teal,
                              child: Text(
                                _initials(u),
                                style: const TextStyle(color: Colors.white, fontSize: 12),
                              ),
                            ),
                            label: Text(_title(u), style: const TextStyle(fontSize: 13)),
                            onDeleted: () => setState(() => _selectedIds.remove(u['id'])),
                          ),
                        ))
                    .toList(),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: _teal, strokeWidth: 2.5))
                : _buildGroupedList(),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: _GradientButton(
              enabled: _selectedIds.length >= 2,
              onPressed: () => setState(() => _step2 = true),
              child: const Text('Avanti'),
            ),
          ),
        ] else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                // Avatar foto gruppo
                GestureDetector(
                  onTap: _pickGroupImage,
                  child: Center(
                    child: Stack(
                      children: [
                        CircleAvatar(
                          radius: 50,
                          backgroundColor: const Color(0xFFB0E0D4),
                          backgroundImage: _groupImage != null ? FileImage(_groupImage!) : null,
                          child: _groupImage == null
                              ? Text(
                                  _nameController.text.trim().isNotEmpty
                                      ? (_nameController.text.trim().length >= 2
                                          ? _nameController.text.trim().substring(0, 2).toUpperCase()
                                          : _nameController.text.trim().toUpperCase())
                                      : 'GR',
                                  style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700),
                                )
                              : null,
                        ),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: _teal,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                            child: const Icon(Icons.camera_alt, color: Colors.white, size: 16),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Nome del gruppo',
                    border: OutlineInputBorder(),
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _descController,
                  decoration: const InputDecoration(
                    labelText: 'Descrizione (opzionale)',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
              ],
            ),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: _GradientButton(
              enabled: !_creating,
              onPressed: _createGroup,
              loading: _creating,
              child: const Text('Crea Gruppo'),
            ),
          ),
        ],
      ],
      ),
    );
  }

  Widget _buildGroupedList() {
    final grouped = _groupByLetter(_filteredUsers);
    final letters = grouped.keys.toList()..sort();
    return ListView.builder(
      controller: widget.scrollController,
      itemCount: letters.fold<int>(0, (sum, l) => sum + 1 + (grouped[l]!.length)),
      itemBuilder: (context, index) {
        int offset = 0;
        for (final letter in letters) {
          final list = grouped[letter]!;
          if (index == offset) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                letter,
                style: const TextStyle(color: _teal, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            );
          }
          offset++;
          final idx = index - offset;
          if (idx < list.length) {
            final u = list[idx];
            final id = u['id'] as int?;
            final selected = id != null && _selectedIds.contains(id);
            final avatarUrl = u['avatar_url'] as String?;
            return Column(
              children: [
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: _teal,
                    backgroundImage: avatarUrl != null && avatarUrl.isNotEmpty
                        ? NetworkImage(avatarUrl)
                        : null,
                    child: avatarUrl != null && avatarUrl.isNotEmpty
                        ? null
                        : Text(_initials(u), style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                  title: Text(_title(u), style: const TextStyle(color: _navy, fontSize: 15, fontWeight: FontWeight.w500)),
                  subtitle: Text(u['email'] as String? ?? '', style: const TextStyle(color: _subtitleGray, fontSize: 13)),
                  trailing: Checkbox(
                    value: selected,
                    onChanged: id == null ? null : (v) => setState(() {
                          if (v == true) _selectedIds.add(id);
                          else _selectedIds.remove(id);
                        }),
                    activeColor: _teal,
                  ),
                  onTap: id == null ? null : () => setState(() {
                        if (_selectedIds.contains(id)) _selectedIds.remove(id);
                        else _selectedIds.add(id);
                      }),
                ),
                const Divider(height: 1, thickness: 0.5, color: Color(0xFFEEEEEE)),
              ],
            );
          }
          offset += list.length;
        }
        return const SizedBox.shrink();
      },
    );
  }
}

// --- Gradient button (same as login) ---
class _GradientButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onPressed;
  final bool loading;
  final Widget child;

  const _GradientButton({
    required this.enabled,
    required this.onPressed,
    this.loading = false,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          gradient: enabled ? AppColors.buttonGradient : null,
          color: enabled ? null : AppColors.textDisabled,
          borderRadius: BorderRadius.circular(16),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.35),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled && !loading ? onPressed : null,
            borderRadius: BorderRadius.circular(16),
            child: Center(
              child: loading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : DefaultTextStyle(
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                      child: child,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- Broadcast Sheet (same as group, conv_type broadcast) ---

class _BroadcastSheetContent extends StatefulWidget {
  final ScrollController scrollController;
  final ChatService chatService;
  final Future<void> Function(Map<String, dynamic> conversation) onConversationCreated;
  final void Function(String message) onError;

  const _BroadcastSheetContent({
    required this.scrollController,
    required this.chatService,
    required this.onConversationCreated,
    required this.onError,
  });

  @override
  State<_BroadcastSheetContent> createState() => _BroadcastSheetContentState();
}

class _BroadcastSheetContentState extends State<_BroadcastSheetContent> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  List<Map<String, dynamic>> _allUsers = [];
  List<Map<String, dynamic>> _filteredUsers = [];
  final Set<int> _selectedIds = {};
  bool _loading = false;
  bool _step2 = false;
  bool _creating = false;
  Timer? _debounce;

  AppLocalizations get l10n => AppLocalizations.of(context)!;
  static const Color _teal = Color(0xFF2ABFBF);
  static const Color _navy = Color(0xFF1A2B4A);
  static const Color _subtitleGray = Color(0xFF9E9E9E);
  static const Color _searchBg = Color(0xFFF5F5F5);

  @override
  void initState() {
    super.initState();
    _loadAllUsers();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadAllUsers() async {
    setState(() => _loading = true);
    final users = await widget.chatService.searchUsers('');
    if (!mounted) return;
    users.sort((a, b) {
      final na = _sortName(a);
      final nb = _sortName(b);
      return na.compareTo(nb);
    });
    setState(() {
      _allUsers = users;
      _filteredUsers = users;
      _loading = false;
    });
  }

  String _sortName(Map<String, dynamic> u) {
    final first = (u['first_name'] as String? ?? '').trim();
    final last = (u['last_name'] as String? ?? '').trim();
    final name = '$first $last'.trim();
    if (name.isNotEmpty) return name.toLowerCase();
    return (u['email'] as String? ?? '').toLowerCase();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      final q = value.trim().toLowerCase();
      setState(() {
        if (q.isEmpty) {
          _filteredUsers = List.from(_allUsers);
        } else {
          _filteredUsers = _allUsers.where((u) {
            final name = _sortName(u);
            final email = (u['email'] as String? ?? '').toLowerCase();
            return name.contains(q) || email.contains(q);
          }).toList();
        }
      });
    });
  }

  String _title(Map<String, dynamic> u) {
    final name = '${u['first_name'] ?? ''} ${u['last_name'] ?? ''}'.trim();
    if (name.isNotEmpty) return name;
    return u['username'] as String? ?? u['email'] as String? ?? '';
  }

  String _initials(Map<String, dynamic> u) {
    final first = (u['first_name'] as String? ?? '').trim();
    final last = (u['last_name'] as String? ?? '').trim();
    if (first.isNotEmpty && last.isNotEmpty) return '${first[0]}${last[0]}'.toUpperCase();
    if (first.isNotEmpty) return first[0].toUpperCase();
    final email = (u['email'] as String? ?? '').trim();
    if (email.isNotEmpty) return email[0].toUpperCase();
    return '?';
  }

  Map<String, List<Map<String, dynamic>>> _groupByLetter(List<Map<String, dynamic>> users) {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final u in users) {
      final name = _title(u);
      final letter = name.isEmpty ? '?' : name[0].toUpperCase();
      map.putIfAbsent(letter, () => []).add(u);
    }
    return map;
  }

  Future<void> _createBroadcast() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      widget.onError('Inserisci il nome della lista');
      return;
    }
    setState(() => _creating = true);
    try {
      final conv = await widget.chatService.createBroadcastConversation(
        _selectedIds.toList(),
        name: name,
      );
      if (!mounted) return;
      if (conv != null) {
        widget.onConversationCreated(conv);
      } else {
        widget.onError('Impossibile creare la lista broadcast');
      }
    } on ApiException catch (e) {
      if (mounted) widget.onError(e.message);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
          child: Row(
            children: [
              const Expanded(child: SizedBox()),
              Text(
                _step2 ? l10n.t('broadcast_list_name') : l10n.t('new_broadcast_list'),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: _navy),
              ),
              const Expanded(child: SizedBox()),
              IconButton(
                icon: const Icon(Icons.close, color: _navy),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        if (!_step2) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              decoration: BoxDecoration(
                color: _searchBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: TextField(
                controller: _searchController,
                onChanged: _onSearchChanged,
                decoration: InputDecoration(
                  hintText: l10n.t('search_by_name'),
                  hintStyle: TextStyle(color: _subtitleGray, fontSize: 15),
                  prefixIcon: Icon(Icons.search, color: _subtitleGray, size: 22),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
              ),
            ),
          ),
          if (_selectedIds.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: _allUsers
                    .where((u) => _selectedIds.contains(u['id'] as int?))
                    .map((u) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Chip(
                            avatar: CircleAvatar(
                              backgroundColor: _teal,
                              child: Text(
                                _initials(u),
                                style: const TextStyle(color: Colors.white, fontSize: 12),
                              ),
                            ),
                            label: Text(_title(u), style: const TextStyle(fontSize: 13)),
                            onDeleted: () => setState(() => _selectedIds.remove(u['id'])),
                          ),
                        ))
                    .toList(),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: _teal, strokeWidth: 2.5))
                : _buildGroupedList(),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: _GradientButton(
              enabled: _selectedIds.length >= 2,
              onPressed: () => setState(() => _step2 = true),
              child: const Text('Avanti'),
            ),
          ),
        ] else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Nome Lista Broadcast',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: _GradientButton(
              enabled: !_creating,
              onPressed: _createBroadcast,
              loading: _creating,
              child: const Text('Crea Lista Broadcast'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildGroupedList() {
    final grouped = _groupByLetter(_filteredUsers);
    final letters = grouped.keys.toList()..sort();
    return ListView.builder(
      controller: widget.scrollController,
      itemCount: letters.fold<int>(0, (sum, l) => sum + 1 + (grouped[l]!.length)),
      itemBuilder: (context, index) {
        int offset = 0;
        for (final letter in letters) {
          final list = grouped[letter]!;
          if (index == offset) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                letter,
                style: const TextStyle(color: _teal, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            );
          }
          offset++;
          final idx = index - offset;
          if (idx < list.length) {
            final u = list[idx];
            final id = u['id'] as int?;
            final selected = id != null && _selectedIds.contains(id);
            final avatarUrl = u['avatar_url'] as String?;
            return Column(
              children: [
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: _teal,
                    backgroundImage: avatarUrl != null && avatarUrl.isNotEmpty
                        ? NetworkImage(avatarUrl)
                        : null,
                    child: avatarUrl != null && avatarUrl.isNotEmpty
                        ? null
                        : Text(_initials(u), style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                  title: Text(_title(u), style: const TextStyle(color: _navy, fontSize: 15, fontWeight: FontWeight.w500)),
                  subtitle: Text(u['email'] as String? ?? '', style: const TextStyle(color: _subtitleGray, fontSize: 13)),
                  trailing: Checkbox(
                    value: selected,
                    onChanged: id == null ? null : (v) => setState(() {
                          if (v == true) _selectedIds.add(id);
                          else _selectedIds.remove(id);
                        }),
                    activeColor: _teal,
                  ),
                  onTap: id == null ? null : () => setState(() {
                        if (_selectedIds.contains(id)) _selectedIds.remove(id);
                        else _selectedIds.add(id);
                      }),
                ),
                const Divider(height: 1, thickness: 0.5, color: Color(0xFFEEEEEE)),
              ],
            );
          }
          offset += list.length;
        }
        return const SizedBox.shrink();
      },
    );
  }
}
