import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart' as record;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:url_launcher/url_launcher.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/models/conversation_model.dart';
import '../../../core/models/user_model.dart';
import '../../../core/widgets/user_avatar_widget.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/chat_service.dart';
import '../../../core/services/crypto_service.dart';
import '../../../core/services/media_encryption_service.dart';
import '../../../core/services/session_manager.dart';
import '../../../core/services/sound_service.dart';
import '../widgets/audio_player_widget.dart';
import 'document_viewer_screen.dart';
import 'group_info_screen.dart';

class ChatDetailScreen extends StatefulWidget {
  const ChatDetailScreen({super.key});

  /// ID of the conversation currently open in this screen (null if none or disposed).
  /// Used by home to avoid showing in-app notification for the open chat.
  static String? currentOpenConversationId;

  /// Testo preview per allegato E2E in base al message_type (usato in home e _saveHomePreview).
  static String encryptedAttachmentPreviewText(String? messageType) {
    switch (messageType) {
      case 'image':
        return '📷 Immagine cifrata';
      case 'video':
        return '🎥 Video cifrato';
      case 'audio':
      case 'voice':
        return '🎵 Audio cifrato';
      case 'file':
        return '📄 Documento cifrato';
      case 'location':
      case 'location_live':
        return '📍 Posizione cifrata';
      case 'contact':
        return '👤 Contatto cifrato';
      default:
        return '🔒 Allegato cifrato';
    }
  }

  /// Etichetta senza emoji per preview in lista (icone grigie separate).
  static String encryptedAttachmentPreviewLabel(String? messageType) {
    switch (messageType) {
      case 'image':
        return 'Immagine cifrata';
      case 'video':
        return 'Video cifrato';
      case 'audio':
      case 'voice':
        return 'Audio cifrato';
      case 'file':
        return 'Documento cifrato';
      case 'location':
      case 'location_live':
        return 'Posizione cifrata';
      case 'contact':
        return 'Contatto cifrato';
      default:
        return 'Allegato cifrato';
    }
  }

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
  final ChatService _chatService = ChatService();
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _messageFocusNode = FocusNode();

  Map<String, dynamic>? _replyToMessage;
  String? _editingMessageId;

  static const Color _teal = Color(0xFF2ABFBF);
  static const Color _navy = Color(0xFF1A2B4A);
  static const Color _inputBg = Color(0xFFF5F5F5);
  static const Color _bodyBg = Color(0xFFF5F8FA);
  static const Color _footerBorder = Color(0xFFE0E0E0);
  static const Color _statusGray = Color(0xFF9E9E9E);

  String? _conversationId;
  VoidCallback? _onMarkedAsRead;
  ConversationModel? _conversation;
  UserModel? _currentUser;
  int? _currentUserId;
  Map<String, dynamic>? _otherUserFromArgs;
  List<Map<String, dynamic>> _messages = [];
  late final SessionManager _sessionManager;
  final Set<String> _decryptedMessageIds = {};
  final Set<String> _failedDecryptIds = {};
  bool _loading = true;
  bool _isLoadingMessages = false;
  bool _sending = false;
  bool _isUploading = false;
  bool _isMuted = false;
  bool _isPlayingMedia = false;
  Timer? _pollingTimer;
  final ImagePicker _imagePicker = ImagePicker();

  ap.AudioPlayer? _audioPlayer;
  final ValueNotifier<String?> _playingAudioIdNotifier = ValueNotifier<String?>(null);
  final ValueNotifier<Duration> _audioDurationNotifier = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _audioPositionNotifier = ValueNotifier(Duration.zero);
  double _audioPlaybackSpeed = 1.0;
  final Set<String> _downloadingAudioIds = {};

  final Map<String, VideoPlayerController> _videoControllers = {};
  final Map<String, ChewieController> _chewieControllers = {};
  final Map<String, String?> _videoThumbnailCache = {};
  /// Cache dei file decifrati per allegati E2E (attachmentId -> File).
  final Map<String, File> _decryptedFileCache = {};
  /// Chiave file E2E inlined nel messaggio (attachmentId -> file_key_b64).
  final Map<String, String> _attachmentKeyCache = {};
  /// Caption/nome file originale per allegati E2E (attachmentId -> fileName con estensione).
  final Map<String, String> _attachmentCaptionCache = {};

  // WebSocket typing/recording
  WebSocket? _webSocket;
  bool _isTyping = false;
  bool _otherUserIsTyping = false;
  bool _otherUserIsRecording = false;
  bool _isRecordingAudio = false;
  Timer? _typingTimer;
  final ValueNotifier<int> _typingDotsPhase = ValueNotifier<int>(0);
  Timer? _typingDotsTimer;

  @override
  void initState() {
    super.initState();
    _sessionManager = SessionManager();
    _textController.addListener(_onTextChanged);
    _audioPlayer = ap.AudioPlayer();
    _audioPlayer!.onDurationChanged.listen((d) {
      _audioDurationNotifier.value = d;
    });
    _audioPlayer!.onPositionChanged.listen((p) {
      _audioPositionNotifier.value = p;
    });
    _audioPlayer!.onPlayerComplete.listen((_) {
      if (mounted) {
        _playingAudioIdNotifier.value = null;
        _isPlayingMedia = false;
        _audioPositionNotifier.value = Duration.zero;
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_conversationId == null) {
      final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
      _conversationId = args?['conversationId']?.toString();
      _otherUserFromArgs = args?['otherUser'] as Map<String, dynamic>?;
      final onMarked = args?['onMarkedAsRead'];
      _onMarkedAsRead = onMarked is VoidCallback ? onMarked : null;
      if (_conversationId != null) {
        ChatDetailScreen.currentOpenConversationId = _conversationId;
        _loadConversationAndMessages();
      } else {
        setState(() => _loading = false);
      }
    }
  }

  int? get _effectiveCurrentUserId => _currentUser?.id ?? _currentUserId;

  /// Other user's ID in 1:1 chat (for E2E session).
  int? _getOtherUserId() {
    // Nei gruppi non c'è un singolo "altro utente" per E2E
    if (_conversation != null && _conversation!.isGroup) return null;
    final other = _otherParticipant;
    if (other != null) return other.userId;
    for (final msg in _messages) {
      final sender = msg['sender'];
      if (sender is Map) {
        final senderId = sender['id'];
        if (senderId != null && senderId != _effectiveCurrentUserId) {
          return senderId is int ? senderId : int.tryParse(senderId.toString());
        }
      }
    }
    return null;
  }

  ConversationParticipant? get _otherParticipant {
    if (_conversation == null || _conversation!.isGroup) return null;
    final currentId = _effectiveCurrentUserId;
    if (currentId == null) return _conversation!.participants.isNotEmpty ? _conversation!.participants.first : null;
    for (final p in _conversation!.participants) {
      if (p.userId != currentId) return p;
    }
    return _conversation!.participants.isNotEmpty ? _conversation!.participants.first : null;
  }

  String? get _otherUserAvatarUrl {
    final avatar = _otherParticipant?.avatar;
    if (avatar == null || avatar.isEmpty) return null;
    if (avatar.startsWith('http')) return avatar;
    return '${AppConstants.mediaBaseUrl}$avatar';
  }

  String get _displayName {
    if (_conversation != null && _conversation!.isGroup) {
      return _conversation!.displayName;
    }
    final other = _otherParticipant;
    if (other != null) return other.displayName;
    if (_otherUserFromArgs != null) {
      final first = _otherUserFromArgs!['first_name'] as String? ?? '';
      final last = _otherUserFromArgs!['last_name'] as String? ?? '';
      final name = '$first $last'.trim();
      if (name.isNotEmpty) return name;
      return _otherUserFromArgs!['email'] as String? ?? _otherUserFromArgs!['username'] as String? ?? 'Chat';
    }
    return 'Chat';
  }

  String? get _otherAvatarUrl => _otherParticipant?.avatar;

  String get _otherInitials {
    final other = _otherParticipant;
    if (other != null) {
      final parts = other.displayName.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
      if (parts.isNotEmpty && parts.first.isNotEmpty) return parts.first[0].toUpperCase();
    }
    if (_otherUserFromArgs != null) {
      final first = (_otherUserFromArgs!['first_name'] as String? ?? '').trim();
      final last = (_otherUserFromArgs!['last_name'] as String? ?? '').trim();
      if (first.isNotEmpty && last.isNotEmpty) return '${first[0]}${last[0]}'.toUpperCase();
      if (first.isNotEmpty) return first[0].toUpperCase();
    }
    return '?';
  }

  bool get _isOtherOnline => _otherParticipant?.isOnline ?? false;

  Future<void> _persistFailedDecryptIds() async {
    if (_conversationId == null || _conversationId!.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'failed_decrypt_ids_$_conversationId',
      _failedDecryptIds.toList(),
    );
  }

  /// Salva il contenuto dell'ultimo messaggio (più recente) per la preview in home.
  /// Salva anche il timestamp così la home può verificare che il preview sia per l'ultimo messaggio reale.
  /// Chiamato dopo setState con newMessages già reversed (indice 0 = più recente).
  Future<void> _saveHomePreview(List<Map<String, dynamic>> newMessages) async {
    if (_conversationId == null || _conversationId!.isEmpty || newMessages.isEmpty) return;
    final lastMsg = newMessages.first;
    final attachments = lastMsg['attachments'] as List? ?? [];
    final hasEncrypted = attachments.isNotEmpty &&
        (attachments[0] is Map) &&
        (attachments[0] as Map)['is_encrypted'] == true;
    String content = lastMsg['content']?.toString()?.trim() ?? '';
    if (content.startsWith('{"type":"location"')) {
      content = '📍 Posizione';
    }
    if (hasEncrypted) {
      content = ChatDetailScreen.encryptedAttachmentPreviewText(lastMsg['message_type']?.toString());
    }
    if (content.isEmpty ||
        content == '🔒 Messaggio cifrato' ||
        content == '🔒 Messaggio non disponibile' ||
        content == '🔒 Messaggio inviato (non disponibile)') return;
    final createdAt = lastMsg['created_at']?.toString();
    if (createdAt == null || createdAt.isEmpty) return;
    final ts = DateTime.tryParse(createdAt)?.toIso8601String() ?? createdAt;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'scp_home_preview_$_conversationId',
      jsonEncode({'content': content, 'ts': ts}),
    );
  }

  static Color _getStatusColor(bool isOnline) {
    if (isOnline) return const Color(0xFF4CAF50); // Online - verde
    return const Color(0xFF9E9E9E); // Assente - grigio
  }

  static String _getStatusText(bool isOnline) {
    if (isOnline) return 'Online';
    return 'Assente';
  }

  Future<void> _loadConversationAndMessages() async {
    if (_conversationId == null || _conversationId!.isEmpty) return;
    // Load persisted failed-decrypt IDs so we never retry after hot restart
    final prefs = await SharedPreferences.getInstance();
    final failedList = prefs.getStringList('failed_decrypt_ids_$_conversationId') ?? [];
    _failedDecryptIds.clear();
    _failedDecryptIds.addAll(failedList);
    final convFuture = _chatService.getConversation(_conversationId!);
    final userFuture = _chatService.getCurrentUser();
    final uidFuture = AuthService.getCurrentUserId();
    final conv = await convFuture;
    final user = await userFuture;
    final currentUserId = await uidFuture;
    if (!mounted) return;
    await _loadMessages(silent: false);
    if (!mounted) return;
    setState(() {
      _conversation = conv;
      _currentUser = user;
      _currentUserId = currentUserId;
    });
    if (_messages.isNotEmpty) _scrollToBottom();
    await _markAsRead();
    if (mounted) _onMarkedAsRead?.call();
    // Avvia polling DOPO il primo load
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (mounted) _loadMessagesSilent();
    });
    _connectWebSocket();
    _loadMuteStatus();
  }

  Future<void> _loadMuteStatus() async {
    if (_conversationId == null || _conversationId!.isEmpty) return;
    try {
      final response = await ApiService().get('/chat/conversations/$_conversationId/');
      final participants = response['participants_info'] as List? ?? response['participants'] as List? ?? [];
      final currentId = _effectiveCurrentUserId;
      for (final p in participants) {
        final pm = p is Map<String, dynamic> ? p : Map<String, dynamic>.from(p as Map);
        final user = pm['user'];
        final uid = user is Map ? (user as Map)['id'] : pm['user_id'];
        final id = uid is int ? uid : int.tryParse(uid?.toString() ?? '');
        if (id == currentId) {
          final mutedUntil = pm['muted_until']?.toString();
          if (mutedUntil != null && mutedUntil.isNotEmpty) {
            final until = DateTime.tryParse(mutedUntil);
            if (mounted) setState(() => _isMuted = until != null && until.isAfter(DateTime.now()));
          }
          break;
        }
      }
    } catch (_) {}
  }

  Future<void> _downloadAndPlayAudio(String messageId, String audioUrl, String? token) async {
    if (_downloadingAudioIds.contains(messageId)) return;
    if (_audioPlayer == null || token == null) return;
    _downloadingAudioIds.add(messageId);
    try {
      final response = await http.get(
        Uri.parse(audioUrl),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200 && mounted) {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/securechat_${messageId}_audio.m4a');
        await file.writeAsBytes(response.bodyBytes);
        if (mounted) {
          await _audioPlayer?.play(ap.DeviceFileSource(file.path));
          await _audioPlayer?.setPlaybackRate(_audioPlaybackSpeed);
        }
      }
    } catch (e) {
      if (mounted) {
        _playingAudioIdNotifier.value = null;
        _isPlayingMedia = false;
      }
    } finally {
      _downloadingAudioIds.remove(messageId);
    }
  }

  void _connectWebSocket() {
    final at = ApiService().accessToken;
    if (_conversationId == null || _conversationId!.isEmpty) return;
    if (at == null || at.isEmpty) return;
    final wsUrl = '${AppConstants.wsUrl}?token=${Uri.encodeComponent(at)}';
    WebSocket.connect(wsUrl).then((ws) {
      if (!mounted || _conversationId == null) {
        ws.close();
        return;
      }
      _webSocket = ws;
      _webSocket!.listen(
        (data) {
          if (!mounted) return;
          try {
            final map = jsonDecode(data is String ? data : String.fromCharCodes(data as List<int>)) as Map<String, dynamic>?;
            if (map == null) return;
            final type = map['type']?.toString();
            if (type == 'typing.indicator') {
              final userId = map['user_id'];
              final currentId = _effectiveCurrentUserId;
              final otherId = userId is int ? userId : int.tryParse(userId?.toString() ?? '');
              if (otherId != null && otherId != currentId) {
                debugPrint('[WS] Received typing indicator: is_typing=${map['is_typing']}, is_recording=${map['is_recording']}');
                setState(() {
                  _otherUserIsTyping = map['is_typing'] == true;
                  _otherUserIsRecording = map['is_typing'] == true && map['is_recording'] == true;
                });
                if (_otherUserIsTyping || _otherUserIsRecording) {
                  _startTypingDotsAnimation();
                } else {
                  _stopTypingDotsAnimation();
                }
              }
            }
            if (type == 'presence.update') {
              final convId = map['conversation_id']?.toString();
              if (convId != _conversationId) return;
              final userId = map['user_id'];
              final isOnline = map['is_online'] == true;
              final otherId = userId is int ? userId : int.tryParse(userId?.toString() ?? '');
              final currentId = _effectiveCurrentUserId;
              if (otherId != null && otherId != currentId && _conversation != null) {
                final updatedParticipants = _conversation!.participants.map((p) {
                  if (p.userId == otherId) {
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
                setState(() {
                  _conversation = ConversationModel(
                    id: _conversation!.id,
                    convType: _conversation!.convType,
                    name: _conversation!.name,
                    participants: updatedParticipants,
                    lastMessage: _conversation!.lastMessage,
                    unreadCount: _conversation!.unreadCount,
                    isMuted: _conversation!.isMuted,
                    isLocked: _conversation!.isLocked,
                    isFavorite: _conversation!.isFavorite,
                    createdAt: _conversation!.createdAt,
                  );
                });
              }
            }
            if (type == 'conversation.deleted') {
              final convId = map['conversation_id']?.toString();
              if (convId == _conversationId && mounted) {
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (ctx) => AlertDialog(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    title: const Text('Chat eliminata', style: TextStyle(fontWeight: FontWeight.w700)),
                    content: const Text('Questa conversazione è stata eliminata da tutti i partecipanti.'),
                    actions: [
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2ABFBF),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          Navigator.pop(context);
                        },
                        child: const Text('OK'),
                      ),
                    ],
                  ),
                );
              }
            }
            if (type == 'message.deleted') {
              final deletedMsgId = map['message_id']?.toString();
              if (deletedMsgId != null && deletedMsgId.isNotEmpty && mounted) {
                final existingIdx = _messages.indexWhere((m) => m['id']?.toString() == deletedMsgId);
                if (existingIdx >= 0) {
                  showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (ctx) => AlertDialog(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      title: const Text('Messaggio eliminato', style: TextStyle(fontWeight: FontWeight.w700)),
                      content: const Text('Un messaggio è stato eliminato per tutti.'),
                      actions: [
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF2ABFBF),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () {
                            Navigator.pop(ctx);
                          },
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  );
                  setState(() {
                    _messages.removeAt(existingIdx);
                  });
                }
              }
            }
            if (type == 'chat.message') {
              final msgData = map['message'] as Map<String, dynamic>?;
              if (msgData != null && mounted) {
                final msgId = msgData['id']?.toString() ?? '';
                final existingIdx = _messages.indexWhere((m) => m['id']?.toString() == msgId);
                final alreadyExists = existingIdx >= 0;

                // Se il messaggio esiste già ma ora ha allegati (broadcast post-upload), aggiornalo
                if (alreadyExists) {
                  final existingMsg = _messages[existingIdx];
                  final existingAtts = existingMsg['attachments'] as List? ?? [];
                  final newAtts = msgData['attachments'] as List? ?? [];
                  if (existingAtts.isEmpty && newAtts.isNotEmpty) {
                    final updatedMsg = Map<String, dynamic>.from(msgData);
                    if (existingMsg['content'] != null && existingMsg['content'].toString().isNotEmpty) {
                      updatedMsg['content'] = existingMsg['content'];
                    }
                    setState(() {
                      _messages[existingIdx] = updatedMsg;
                    });
                  }
                  return;
                }
                if (true) {
                  setState(() {
                    _messages.insert(0, msgData);
                  });
                  _webSocket?.add(jsonEncode({
                    'action': 'read_receipt',
                    'message_ids': [msgId],
                    'conversation_id': _conversationId,
                  }));
                  _saveHomePreview(_messages);
                }
              }
            }
          } catch (_) {}
        },
        onError: (e) => debugPrint('WebSocket error: $e'),
        onDone: () {
          _webSocket = null;
          if (mounted) setState(() {
            _otherUserIsTyping = false;
            _otherUserIsRecording = false;
          });
          _stopTypingDotsAnimation();
        },
        cancelOnError: false,
      );
    }).catchError((e) => debugPrint('WebSocket connect error: $e'));
  }

  void _startTypingDotsAnimation() {
    _typingDotsTimer?.cancel();
    _typingDotsPhase.value = 0;
    _typingDotsTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _typingDotsPhase.value = (_typingDotsPhase.value + 1) % 3;
    });
  }

  void _stopTypingDotsAnimation() {
    _typingDotsTimer?.cancel();
    _typingDotsTimer = null;
  }

  void _onTextChanged() {
    final text = _textController.text;
    if (text.isNotEmpty && !_isTyping) {
      _isTyping = true;
      _sendTypingIndicator(true);
    } else if (text.isEmpty && _isTyping) {
      _isTyping = false;
      _sendTypingIndicator(false);
    }
    _typingTimer?.cancel();
    if (text.isNotEmpty) {
      _typingTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && _isTyping) {
          _isTyping = false;
          _sendTypingIndicator(false);
          setState(() {});
        }
      });
    }
  }

  void _sendTypingIndicator(bool typing) {
    if (_conversationId == null || _conversationId!.isEmpty) return;
    _webSocket?.add(jsonEncode({
      'action': typing ? 'typing' : 'stop_typing',
      'conversation_id': _conversationId,
    }));
  }

  void _sendRecordingIndicator(bool recording) {
    if (_conversationId == null || _conversationId!.isEmpty) return;
    _sendTypingIndicator(false);
    _webSocket?.add(jsonEncode({
      'action': recording ? 'typing' : 'stop_typing',
      'conversation_id': _conversationId,
      'is_recording': recording,
    }));
  }

  Widget _buildTypingDots() {
    return ValueListenableBuilder<int>(
      valueListenable: _typingDotsPhase,
      builder: (context, phase, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final visible = phase == i;
            return Container(
              margin: EdgeInsets.only(right: i < 2 ? 3 : 0),
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: visible ? Colors.grey[600] : Colors.grey[300],
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }

  /// Carica da SharedPreferences le caption degli allegati E2E per mostrare il nome file corretto (es. dopo riavvio).
  Future<void> _preloadAttachmentCaptionsFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    bool updated = false;
    for (final msg in _messages) {
      final atts = msg['attachments'] as List? ?? [];
      for (final a in atts) {
        if (a is! Map) continue;
        if (a['is_encrypted'] != true) continue;
        final attId = a['id']?.toString();
        if (attId == null || attId.isEmpty) continue;
        if (_attachmentCaptionCache.containsKey(attId)) continue;
        final caption = prefs.getString('scp_att_caption_$attId');
        if (caption != null && caption.isNotEmpty) {
          _attachmentCaptionCache[attId] = caption;
          updated = true;
        }
      }
    }
    if (updated && mounted) setState(() {});
  }

  Future<void> _markAsRead() async {
    if (_conversationId == null || _conversationId!.isEmpty) return;
    try {
      await ApiService().post(
        '/chat/conversations/$_conversationId/read/',
        body: {},
      );
    } catch (_) {}
  }

  void _showChatActions() {
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
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _isMuted ? Icons.notifications : Icons.notifications_off,
                  color: Colors.orange,
                ),
              ),
              title: Text(
                _isMuted ? 'Riattiva notifiche' : 'Silenzia',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
              ),
              subtitle: Text(
                _isMuted ? 'Riceverai di nuovo le notifiche' : 'Non riceverai notifiche da questa chat',
                style: TextStyle(color: Colors.grey[500], fontSize: 13),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _toggleMute();
              },
            ),
            Divider(height: 1, indent: 16, endIndent: 16, color: Colors.grey[100]),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.delete_sweep_outlined, color: Colors.red),
              ),
              title: const Text(
                'Svuota chat',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: Colors.red),
              ),
              subtitle: Text(
                'Elimina tutti i messaggi per te',
                style: TextStyle(color: Colors.grey[500], fontSize: 13),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _confirmClearChat();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleMute() async {
    if (_conversationId == null || _conversationId!.isEmpty) return;
    try {
      if (_isMuted) {
        await ApiService().delete('/chat/conversations/$_conversationId/mute/');
      } else {
        await ApiService().post('/chat/conversations/$_conversationId/mute/', body: {});
      }
      if (mounted) {
        setState(() => _isMuted = !_isMuted);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isMuted ? 'Chat silenziata' : 'Notifiche riattivate'),
            backgroundColor: const Color(0xFF2ABFBF),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Errore, riprova')),
        );
      }
    }
  }

  void _confirmClearChat() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Svuota chat', style: TextStyle(fontWeight: FontWeight.w700)),
        content: const Text(
          'Vuoi eliminare tutti i messaggi? Questa azione è irreversibile.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annulla'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _clearChat();
            },
            child: const Text('Elimina'),
          ),
        ],
      ),
    );
  }

  Future<void> _clearChat() async {
    if (_conversationId == null || _conversationId!.isEmpty) return;
    try {
      await ApiService().post('/chat/conversations/$_conversationId/clear/', body: {});
      if (mounted) {
        _pollingTimer?.cancel();
        setState(() => _messages.clear());
        // Pulisci preview home e notifica la home per il prossimo polling
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('scp_home_preview_$_conversationId');
        await prefs.setBool('scp_chat_cleared_$_conversationId', true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Chat svuotata'), backgroundColor: Colors.red),
        );
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            _pollingTimer = Timer.periodic(const Duration(seconds: 8), (_) {
              if (mounted) _loadMessagesSilent();
            });
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Errore, riprova')),
        );
      }
    }
  }

  /// Polling silenzioso: aggiorna i messaggi senza toccare _loading.
  /// Rileva qualsiasi cambiamento (nuovi messaggi, reactions, edit, delete) tramite _hasChanges.
  Future<void> _loadMessagesSilent() async {
    if (_playingAudioIdNotifier.value != null) return;
    if (_isRecordingAudio) return;
    if (!mounted || _conversationId == null || _conversationId!.isEmpty) return;
    try {
      final response = await ApiService().get(
        '/chat/conversations/$_conversationId/messages/',
      );
      List<Map<String, dynamic>> newMessages = [];
      if (response is Map) {
        final results = response['results'];
        if (results is List) {
          for (final e in results) {
            if (e is Map<String, dynamic>) {
              newMessages.add(e);
            } else if (e is Map) {
              newMessages.add(Map<String, dynamic>.from(e));
            }
          }
        }
      } else if (response is List) {
        for (final e in (response as List)) {
          if (e is Map<String, dynamic>) {
            newMessages.add(e);
          } else if (e is Map) {
            newMessages.add(Map<String, dynamic>.from(e));
          }
        }
      }
      // 1. Sort and 2. E2E decrypt always (so _hasChanges sees decrypted content)
      int? currentUserId = _effectiveCurrentUserId;
      if (currentUserId == null) {
        final prefs = await SharedPreferences.getInstance();
        currentUserId = prefs.getInt('current_user_id') ??
            int.tryParse(prefs.getString('current_user_id') ?? '');
      }
      newMessages.sort((a, b) =>
          (a['created_at']?.toString() ?? '').compareTo(b['created_at']?.toString() ?? ''));
      // Aggiorna messaggi esistenti con allegati (per upload asincroni nei gruppi)
      for (final newMsg in newMessages) {
        final newMsgId = newMsg['id']?.toString() ?? '';
        if (newMsgId.isEmpty) continue;
        final existingIdx = _messages.indexWhere((m) => m['id']?.toString() == newMsgId);
        if (existingIdx >= 0) {
          final existingAtts = _messages[existingIdx]['attachments'] as List? ?? [];
          final newAtts = newMsg['attachments'] as List? ?? [];
          if (existingAtts.isEmpty && newAtts.isNotEmpty) {
            final existingContent = _messages[existingIdx]['content']?.toString() ?? '';
            if (existingContent.isNotEmpty) {
              newMsg['content'] = existingContent;
            }
            setState(() {
              _messages[existingIdx] = newMsg;
            });
          }
        }
      }

      // Non aggiungere messaggi di tipo allegato senza allegati effettivi (upload in corso)
      newMessages.removeWhere((msg) {
        final msgType = msg['message_type']?.toString() ?? 'text';
        final atts = msg['attachments'] as List? ?? [];
        final msgId = msg['id']?.toString() ?? '';
        final alreadyInList = _messages.any((m) => m['id']?.toString() == msgId);
        if (!alreadyInList && ['image', 'video', 'audio', 'voice', 'file'].contains(msgType) && atts.isEmpty) {
          return true;
        }
        return false;
      });

      // Controllo veloce prima della decifratura: salta decifratura e setState se nulla è cambiato
      final quickNewCount = newMessages.length;
      final quickLastId = newMessages.isNotEmpty ? newMessages.last['id']?.toString() : null;
      final quickOldLastId = _messages.isNotEmpty ? _messages.first['id']?.toString() : null;
      final hasNewMessages = quickNewCount != _messages.length || quickLastId != quickOldLastId;
      bool statusesChanged = false;
      if (!hasNewMessages && newMessages.isNotEmpty) {
        final newLastStatuses = jsonEncode(newMessages.last['statuses'] ?? []);
        final oldLastStatuses = jsonEncode(_messages.isNotEmpty ? (_messages.first['statuses'] ?? []) : []);
        statusesChanged = newLastStatuses != oldLastStatuses;
      }
      debugPrint('[POLL] hasNew=$hasNewMessages, statusChanged=$statusesChanged, newCount=$quickNewCount, oldCount=${_messages.length}, newLastId=$quickLastId, oldLastId=$quickOldLastId');
      if (!hasNewMessages && !statusesChanged) return;
      if (!hasNewMessages && statusesChanged) {
        if (mounted) {
          setState(() {
            for (int i = 0; i < newMessages.length; i++) {
              final idx = _messages.length - 1 - i;
              if (idx >= 0 && idx < _messages.length) {
                _messages[idx]['statuses'] = newMessages[i]['statuses'];
              }
            }
          });
        }
        return;
      }
      final prefsForCacheSilent = await SharedPreferences.getInstance();
      bool contentDecrypted = false;
      for (final msg in newMessages) {
        final plainContent = msg['content']?.toString() ?? '';
        final encryptedB64 = msg['content_encrypted_b64']?.toString() ?? '';
        final messageId = msg['id']?.toString() ?? '';
        // Non saltare se è solo il placeholder E2E (gruppi): dobbiamo decifrare
        final isPlaceholderOnly = plainContent == '🔒 Messaggio cifrato';
        if (plainContent.isNotEmpty && !isPlaceholderOnly) continue;
        if (encryptedB64.isEmpty) continue;

        final senderIdRaw = msg['sender']?['id'] ?? msg['sender_id'];
        final senderIdInt = senderIdRaw is int
            ? senderIdRaw
            : (int.tryParse(senderIdRaw?.toString() ?? '') ?? 0);

        if (currentUserId != null &&
            senderIdInt != 0 &&
            senderIdInt.toString() == currentUserId.toString()) {
          if (_failedDecryptIds.contains(messageId)) {
            msg['content'] = '🔒 Messaggio non disponibile';
            continue;
          }
          final cached = await _sessionManager.getCachedPlaintext(messageId);
          if (cached != null) {
            msg['content'] = cached;
          } else {
            msg['content'] = '🔒 Messaggio inviato (non disponibile)';
          }
          continue;
        }

        if (currentUserId == null) {
          msg['content'] = '🔒 Messaggio cifrato';
          continue;
        }
        if (_failedDecryptIds.contains(messageId)) {
          msg['content'] = '🔒 Messaggio non disponibile';
          continue;
        }
        final diskCachedSilent = prefsForCacheSilent.getString('scp_msg_cache_$messageId');
        if (diskCachedSilent != null) {
          msg['content'] = diskCachedSilent;
          _decryptedMessageIds.add(messageId);
          continue;
        }
        if (_decryptedMessageIds.contains(messageId)) {
          final cached = await _sessionManager.getCachedPlaintext(messageId);
          if (cached != null) {
            msg['content'] = cached;
            continue;
          }
          _decryptedMessageIds.remove(messageId);
        }
        final alreadyFailed = await _sessionManager.isDecryptFailed(messageId);
        if (alreadyFailed) {
          msg['content'] = '🔒 Messaggio non disponibile';
          _failedDecryptIds.add(messageId);
          await _persistFailedDecryptIds();
          continue;
        }
        try {
          final combined = base64Decode(encryptedB64);
          final decrypted = await _sessionManager.decryptMessage(
            senderIdInt,
            Uint8List.fromList(combined),
            messageId: messageId,
          );
          final attachmentPayload = SessionManager.parseAttachmentPayload(decrypted);
          if (attachmentPayload != null) {
            final caption = attachmentPayload['caption']?.toString() ?? '';
            msg['content'] = caption;
            final atts = msg['attachments'] as List? ?? [];
            if (atts.isNotEmpty && atts[0] is Map) {
              final attId = (atts[0] as Map)['id']?.toString();
              final fk = attachmentPayload['file_key_b64'] as String?;
              if (attId != null && fk != null) {
                _attachmentKeyCache[attId] = fk;
                _attachmentCaptionCache[attId] = caption;
                await prefsForCacheSilent.setString('scp_att_key_$attId', fk);
                await prefsForCacheSilent.setString('scp_att_caption_$attId', caption);
              }
            }
            await _sessionManager.cacheSentMessage(messageId, msg['content'] as String);
          } else {
            msg['content'] = decrypted;
            if (SessionManager.parseContactPayload(decrypted) != null) {
              msg['message_type'] = 'contact';
            } else if (SessionManager.parseLocationPayload(decrypted) != null) {
              msg['message_type'] = 'location';
            }
            await _sessionManager.cacheSentMessage(messageId, decrypted);
          }
          _decryptedMessageIds.add(messageId);
          contentDecrypted = true;
        } catch (e) {
          msg['content'] = '🔒 Messaggio non disponibile';
          _failedDecryptIds.add(messageId);
          await _sessionManager.markDecryptFailed(messageId);
          await _persistFailedDecryptIds();
        }
      }
      // 3. Only now compare (decrypted) newMessages with _messages; aggiorna anche se solo il content è cambiato (decifratura)
      if (mounted && (_hasChanges(newMessages) || contentDecrypted)) {
        if (newMessages.length > _messages.length && newMessages.isNotEmpty) {
          final lastMsg = newMessages.first;
          final sender = lastMsg['sender'];
          final senderId = sender is Map ? (sender as Map)['id'] : null;
          final currentId = _effectiveCurrentUserId;
          if (senderId != null && currentId != null) {
            final sid = senderId is int ? senderId : int.tryParse(senderId.toString());
            if (sid != currentId && !_isMuted) {
              SoundService().playMessageReceived();
            }
          }
        }
        newMessages = newMessages.reversed.toList();
        final prevCount = _messages.length;
        setState(() {
          // Aggiorna messaggi nuovi, statuses, e content (es. dopo decifratura E2E gruppi)
          final existingIds = {for (final m in _messages) m['id']?.toString(): m};
          _messages = newMessages.map((newMsg) {
            final id = newMsg['id']?.toString();
            final existing = existingIds[id];
            if (existing == null) return newMsg; // messaggio nuovo
            existing['statuses'] = newMsg['statuses'];
            existing['is_deleted'] = newMsg['is_deleted'];
            existing['is_edited'] = newMsg['is_edited'];
            if (newMsg['content'] != null) existing['content'] = newMsg['content'];
            return existing;
          }).toList();
        });
        _preloadAttachmentCaptionsFromPrefs();
        if (newMessages.length > prevCount) {
          _scrollToBottom();
        }
        _markAsRead();
        _saveHomePreview(newMessages);
      }
    } catch (_) {
      // Ignora errori nel polling silenzioso
    }
  }

  /// Confronta messaggi: count, ultimo ID, poi statuses (per spunte) — evita confronto profondo.
  bool _hasChanges(List<Map<String, dynamic>> newMessages) {
    if (newMessages.length != _messages.length) return true;
    if (newMessages.isEmpty) return false;
    final newLast = newMessages.last['id']?.toString();
    final oldLast = _messages.isNotEmpty ? _messages.first['id']?.toString() : null;
    if (newLast != oldLast) return true;
    for (int i = 0; i < newMessages.length; i++) {
      final newS = jsonEncode(newMessages[i]['statuses'] ?? []);
      final oldS = jsonEncode(_messages[newMessages.length - 1 - i]['statuses'] ?? []);
      if (newS != oldS) return true;
    }
    return false;
  }

  /// Forza il reload completo dei messaggi (ignora _hasChanges). Usato dopo upload allegato.
  Future<void> _forceReloadMessages() async {
    if (!mounted || _conversationId == null || _conversationId!.isEmpty) return;
    try {
      final response = await ApiService().get(
        '/chat/conversations/$_conversationId/messages/',
      );
      List<Map<String, dynamic>> newMessages = [];
      if (response is Map) {
        final results = response['results'];
        if (results is List) {
          for (final e in results) {
            if (e is Map<String, dynamic>) {
              newMessages.add(e);
            } else if (e is Map) {
              newMessages.add(Map<String, dynamic>.from(e));
            }
          }
        }
      } else if (response is List) {
        for (final e in (response as List)) {
          if (e is Map<String, dynamic>) {
            newMessages.add(e);
          } else if (e is Map) {
            newMessages.add(Map<String, dynamic>.from(e));
          }
        }
      }
      // E2E: decrypt inline before setState (same logic as _loadMessages)
      int? currentUserId = _effectiveCurrentUserId;
      if (currentUserId == null) {
        final prefs = await SharedPreferences.getInstance();
        currentUserId = prefs.getInt('current_user_id') ??
            int.tryParse(prefs.getString('current_user_id') ?? '');
      }
      newMessages.sort((a, b) =>
          (a['created_at']?.toString() ?? '').compareTo(b['created_at']?.toString() ?? ''));
      // Non aggiungere messaggi di tipo allegato senza allegati effettivi (upload in corso)
      newMessages.removeWhere((msg) {
        final msgType = msg['message_type']?.toString() ?? 'text';
        final atts = msg['attachments'] as List? ?? [];
        final msgId = msg['id']?.toString() ?? '';
        final alreadyInList = _messages.any((m) => m['id']?.toString() == msgId);
        if (!alreadyInList && ['image', 'video', 'audio', 'voice', 'file'].contains(msgType) && atts.isEmpty) {
          return true;
        }
        return false;
      });
      final prefsForCacheForce = await SharedPreferences.getInstance();
      for (final msg in newMessages) {
        final plainContent = msg['content']?.toString() ?? '';
        final encryptedB64 = msg['content_encrypted_b64']?.toString() ?? '';
        final messageId = msg['id']?.toString() ?? '';
        final isPlaceholderOnly = plainContent == '🔒 Messaggio cifrato';
        if (plainContent.isNotEmpty && !isPlaceholderOnly) continue;
        if (encryptedB64.isEmpty) continue;

        final senderIdRaw = msg['sender']?['id'] ?? msg['sender_id'];
        final senderIdInt = senderIdRaw is int
            ? senderIdRaw
            : (int.tryParse(senderIdRaw?.toString() ?? '') ?? 0);

        if (currentUserId != null &&
            senderIdInt != 0 &&
            senderIdInt.toString() == currentUserId.toString()) {
          if (_failedDecryptIds.contains(messageId)) {
            msg['content'] = '🔒 Messaggio non disponibile';
            continue;
          }
          final cached = await _sessionManager.getCachedPlaintext(messageId);
          msg['content'] = cached ?? '🔒 Messaggio inviato (non disponibile)';
          continue;
        }
        if (currentUserId == null) {
          msg['content'] = '🔒 Messaggio cifrato';
          continue;
        }
        if (_failedDecryptIds.contains(messageId)) {
          msg['content'] = '🔒 Messaggio non disponibile';
          continue;
        }
        final diskCachedForce = prefsForCacheForce.getString('scp_msg_cache_$messageId');
        if (diskCachedForce != null) {
          msg['content'] = diskCachedForce;
          _decryptedMessageIds.add(messageId);
          continue;
        }
        if (_decryptedMessageIds.contains(messageId)) {
          final cached = await _sessionManager.getCachedPlaintext(messageId);
          if (cached != null) {
            msg['content'] = cached;
            continue;
          }
          _decryptedMessageIds.remove(messageId);
          // Fall through to decrypt (e.g. cache lost after hot restart)
        }
        final alreadyFailed = await _sessionManager.isDecryptFailed(messageId);
        if (alreadyFailed) {
          msg['content'] = '🔒 Messaggio non disponibile';
          _failedDecryptIds.add(messageId);
          await _persistFailedDecryptIds();
          continue;
        }
        try {
          final combined = base64Decode(encryptedB64);
          final decrypted = await _sessionManager.decryptMessage(
            senderIdInt,
            Uint8List.fromList(combined),
            messageId: messageId,
          );
          final attachmentPayload = SessionManager.parseAttachmentPayload(decrypted);
          if (attachmentPayload != null) {
            final caption = attachmentPayload['caption']?.toString() ?? '';
            msg['content'] = caption;
            final atts = msg['attachments'] as List? ?? [];
            if (atts.isNotEmpty && atts[0] is Map) {
              final attId = (atts[0] as Map)['id']?.toString();
              final fk = attachmentPayload['file_key_b64'] as String?;
              if (attId != null && fk != null) {
                _attachmentKeyCache[attId] = fk;
                _attachmentCaptionCache[attId] = caption;
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString('scp_att_key_$attId', fk);
                await prefs.setString('scp_att_caption_$attId', caption);
              }
            }
            await _sessionManager.cacheSentMessage(messageId, msg['content'] as String);
          } else {
            msg['content'] = decrypted;
            if (SessionManager.parseContactPayload(decrypted) != null) {
              msg['message_type'] = 'contact';
            } else if (SessionManager.parseLocationPayload(decrypted) != null) {
              msg['message_type'] = 'location';
            }
            await _sessionManager.cacheSentMessage(messageId, decrypted);
          }
          _decryptedMessageIds.add(messageId);
        } catch (e) {
          msg['content'] = '🔒 Messaggio non disponibile';
          _failedDecryptIds.add(messageId);
          await _sessionManager.markDecryptFailed(messageId);
          await _persistFailedDecryptIds();
        }
      }
      if (mounted) {
        newMessages = newMessages.reversed.toList();
        setState(() {
          _messages = newMessages;
        });
        _preloadAttachmentCaptionsFromPrefs();
        _markAsRead();
        _saveHomePreview(newMessages);
      }
    } catch (_) {}
  }

  /// Carica messaggi da GET /api/chat/conversations/{id}/messages/ (response paginata: results).
  /// [silent]: se true non mostra lo spinner e aggiorna solo se i messaggi sono cambiati.
  Future<void> _loadMessages({bool silent = false}) async {
    if (_conversationId == null || _conversationId!.isEmpty) return;
    if (_isLoadingMessages) return; // Prevent concurrent loads
    _isLoadingMessages = true;
    if (!silent) {
      setState(() => _loading = true);
    }
    try {
      if (!silent) {
        debugPrint('=== LOADING MESSAGES for conversation: $_conversationId ===');
      }
      final response = await ApiService().get(
        '/chat/conversations/$_conversationId/messages/',
      );
      if (!silent) {
        debugPrint('=== MESSAGES RESPONSE TYPE: ${response.runtimeType} ===');
      }

      List<Map<String, dynamic>> newMessages = [];
      if (response is Map) {
        final results = response['results'];
        if (results is List) {
          for (final e in results) {
            if (e is Map<String, dynamic>) {
              newMessages.add(e);
            } else if (e is Map) {
              newMessages.add(Map<String, dynamic>.from(e));
            }
          }
        }
      } else if (response is List) {
        for (final e in (response as List)) {
          if (e is Map<String, dynamic>) {
            newMessages.add(e);
          } else if (e is Map) {
            newMessages.add(Map<String, dynamic>.from(e));
          }
        }
      }

      // Decrypt E2E encrypted messages (once per message; use cache for re-loads)
      int? currentUserId = _effectiveCurrentUserId;
      if (currentUserId == null) {
        final prefs = await SharedPreferences.getInstance();
        currentUserId = prefs.getInt('current_user_id') ??
            int.tryParse(prefs.getString('current_user_id') ?? '');
        debugPrint('[E2E] WARNING: _effectiveCurrentUserId is null, fallback to prefs: $currentUserId');
      }
      debugPrint('[E2E] currentUserId for E2E loop: $currentUserId');

      // Process in chronological order (oldest first) for Double Ratchet
      newMessages.sort((a, b) =>
          (a['created_at']?.toString() ?? '').compareTo(b['created_at']?.toString() ?? ''));

      // Non aggiungere messaggi di tipo allegato senza allegati effettivi (upload in corso)
      newMessages.removeWhere((msg) {
        final msgType = msg['message_type']?.toString() ?? 'text';
        final atts = msg['attachments'] as List? ?? [];
        final msgId = msg['id']?.toString() ?? '';
        final alreadyInList = _messages.any((m) => m['id']?.toString() == msgId);
        if (!alreadyInList && ['image', 'video', 'audio', 'voice', 'file'].contains(msgType) && atts.isEmpty) {
          return true;
        }
        return false;
      });

      final prefsForCache = await SharedPreferences.getInstance();

      for (final msg in newMessages) {
        final plainContent = msg['content']?.toString() ?? '';
        final encryptedB64 = msg['content_encrypted_b64']?.toString() ?? '';
        final messageId = msg['id']?.toString() ?? '';

        final isPlaceholderOnly = plainContent == '🔒 Messaggio cifrato';
        if (plainContent.isNotEmpty && !isPlaceholderOnly) continue;
        if (encryptedB64.isEmpty) continue;

        final senderIdRaw = msg['sender']?['id'] ?? msg['sender_id'];
        final senderIdInt = senderIdRaw is int
            ? senderIdRaw
            : (int.tryParse(senderIdRaw?.toString() ?? '') ?? 0);

        // CRITICAL: Own messages — use cache only, NEVER decrypt (sender == me)
        if (currentUserId != null &&
            senderIdInt != 0 &&
            senderIdInt.toString() == currentUserId.toString()) {
          if (_failedDecryptIds.contains(messageId)) {
            msg['content'] = '🔒 Messaggio non disponibile';
            continue;
          }
          final cached = await _sessionManager.getCachedPlaintext(messageId);
          msg['content'] = cached ?? '🔒 Messaggio inviato (non disponibile)';
          continue;
        }

        if (currentUserId == null) {
          msg['content'] = '🔒 Messaggio cifrato';
          continue;
        }

        if (_failedDecryptIds.contains(messageId)) {
          msg['content'] = '🔒 Messaggio non disponibile';
          continue;
        }

        // BUG A: Check disk cache first — avoid re-decrypt and ratchet corruption
        final diskCached = prefsForCache.getString('scp_msg_cache_$messageId');
        if (diskCached != null) {
          msg['content'] = diskCached;
          _decryptedMessageIds.add(messageId);
          continue;
        }

        if (_decryptedMessageIds.contains(messageId)) {
          final cached = await _sessionManager.getCachedPlaintext(messageId);
          if (cached != null) {
            msg['content'] = cached;
            continue;
          }
          _decryptedMessageIds.remove(messageId);
          // Fall through to decrypt (e.g. cache lost after hot restart)
        }

        final alreadyFailed = await _sessionManager.isDecryptFailed(messageId);
        if (alreadyFailed) {
          msg['content'] = '🔒 Messaggio non disponibile';
          _failedDecryptIds.add(messageId);
          await _persistFailedDecryptIds();
          continue;
        }

        // Try decrypt only when not in disk cache (re-decrypt corrupts Double Ratchet)
        try {
          final combined = base64Decode(encryptedB64);
          final decrypted = await _sessionManager.decryptMessage(
            senderIdInt,
            Uint8List.fromList(combined),
            messageId: messageId,
          );
          final attachmentPayload = SessionManager.parseAttachmentPayload(decrypted);
          if (attachmentPayload != null) {
            final caption = attachmentPayload['caption']?.toString() ?? '';
            msg['content'] = caption;
            final atts = msg['attachments'] as List? ?? [];
            if (atts.isNotEmpty && atts[0] is Map) {
              final attId = (atts[0] as Map)['id']?.toString();
              final fk = attachmentPayload['file_key_b64'] as String?;
              if (attId != null && fk != null) {
                _attachmentKeyCache[attId] = fk;
                _attachmentCaptionCache[attId] = caption;
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString('scp_att_key_$attId', fk);
                await prefs.setString('scp_att_caption_$attId', caption);
              }
            }
            await _sessionManager.cacheSentMessage(messageId, msg['content'] as String);
          } else {
            msg['content'] = decrypted;
            if (SessionManager.parseContactPayload(decrypted) != null) {
              msg['message_type'] = 'contact';
            } else if (SessionManager.parseLocationPayload(decrypted) != null) {
              msg['message_type'] = 'location';
            }
            await _sessionManager.cacheSentMessage(messageId, decrypted);
          }
          _decryptedMessageIds.add(messageId);
        } catch (e) {
          msg['content'] = '🔒 Messaggio non disponibile';
          _failedDecryptIds.add(messageId);
          await _sessionManager.markDecryptFailed(messageId);
          await _persistFailedDecryptIds();
          debugPrint('[E2E] Decrypt failed for message $messageId from user $senderIdInt: $e');
        }
      }

      final prevCount = _messages.length;
      if (newMessages.length != prevCount || !silent) {
        if (mounted) {
          newMessages = newMessages.reversed.toList();
          setState(() {
            _messages = newMessages;
            if (!silent) _loading = false;
          });
          _preloadAttachmentCaptionsFromPrefs();
          if (newMessages.length > prevCount) {
            _scrollToBottom();
          }
          _saveHomePreview(newMessages);
        }
      }
      if (!silent) {
        debugPrint('=== PARSED ${newMessages.length} MESSAGES ===');
      }
    } catch (e, stackTrace) {
      debugPrint('Error loading messages: $e');
      if (!silent && mounted) {
        setState(() => _loading = false);
      }
    } finally {
      _isLoadingMessages = false;
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        // Con reverse: true, i messaggi nuovi sono in basso → minScrollExtent
        final pos = _scrollController.position;
        _scrollController.animateTo(
          pos.minScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _scrollToMessage(String? messageId) {
    if (messageId == null) return;
    final index = _messages.indexWhere((m) => m['id']?.toString() == messageId);
    if (index == -1 || !_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final offset = (index * 80.0).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    _scrollController.animateTo(
      offset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  String _getReplyText(Map<String, dynamic> message) {
    final replyToId = message['reply_to']?.toString();
    if (replyToId == null) return '';

    Map<String, dynamic>? original;
    for (final m in _messages) {
      if (m['id']?.toString() == replyToId) {
        original = m;
        break;
      }
    }
    if (original != null && original.containsKey('content')) {
      return original['content']?.toString() ?? '';
    }

    final preview = message['reply_to_preview'];
    final type = preview is Map ? (preview as Map)['message_type']?.toString() ?? '' : '';
    switch (type) {
      case 'image':
        return '📷 Foto';
      case 'video':
        return '🎥 Video';
      case 'audio':
        return '🎵 Audio';
      case 'voice':
        return '🎤 Vocale';
      case 'file':
        return '📄 Documento';
      default:
        return 'Messaggio';
    }
  }

  void _setReplyMessage(Map<String, dynamic> message) {
    setState(() {
      _replyToMessage = message;
    });
    FocusScope.of(context).requestFocus(_messageFocusNode);
  }

  void _editMessage(Map<String, dynamic> message) {
    setState(() {
      _editingMessageId = message['id']?.toString();
      _textController.text = message['content']?.toString() ?? '';
    });
    FocusScope.of(context).requestFocus(_messageFocusNode);
  }

  Future<void> _deleteMessage(Map<String, dynamic> message, {required bool forAll}) async {
    final messageId = message['id']?.toString();
    if (messageId == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Elimina messaggio'),
        content: Text(
          forAll ? 'Vuoi eliminare questo messaggio per tutti?' : 'Vuoi eliminare questo messaggio per te?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annulla'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Elimina', style: TextStyle(color: Color(0xFFF44336))),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      setState(() {
        _messages.removeWhere((m) => m['id']?.toString() == messageId);
      });
    } catch (e) {
      debugPrint('Error deleting message: $e');
    }
  }

  void _forwardMessage(Map<String, dynamic> message) {
    if (mounted) Navigator.pop(context);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _ForwardSheet(
        message: message,
        currentUserId: _effectiveCurrentUserId,
        onForwardToUsers: (List<int> userIds) async {
          await _sendForwardToUsers(message, userIds);
        },
        onShareExternal: () async {
          await _shareExternal(message);
        },
      ),
    );
  }

  Future<void> _sendForwardToUsers(Map<String, dynamic> message, List<int> userIds) async {
    final content = message['content']?.toString() ?? '';
    int successCount = 0;

    for (final userId in userIds) {
      try {
        final convResponse = await ApiService().post(
          '/chat/conversations/',
          body: {
            'participants': [userId],
            'conversation_type': 'direct',
          },
        );
        final convId = convResponse['id'];
        if (convId == null) continue;

        await ApiService().post(
          '/chat/conversations/$convId/messages/',
          body: {
            'content': '↪️ Inoltrato:\n$content',
            'message_type': 'text',
          },
        );
        successCount++;
      } catch (e) {
        debugPrint('Errore inoltro a utente $userId: $e');
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Inoltrato a $successCount ${successCount == 1 ? "utente" : "utenti"}'),
          backgroundColor: const Color(0xFF2ABFBF),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _shareExternal(Map<String, dynamic> message) async {
    final content = message['content']?.toString() ?? '';
    final messageType = message['message_type']?.toString() ?? 'text';

    // Per messaggi di testo, posizione, contatti: condividi come testo
    if (messageType == 'text' || messageType == 'location' || messageType == 'contact') {
      await SharePlus.instance.share(
        ShareParams(text: content, subject: 'SecureChat'),
      );
      return;
    }

    // Per allegati (image, video, audio, voice, file): scarica e condividi il file
    final attachments = message['attachments'] as List? ?? [];
    if (attachments.isEmpty) {
      await SharePlus.instance.share(
        ShareParams(text: content, subject: 'SecureChat'),
      );
      return;
    }

    try {
      final att = attachments[0] is Map ? attachments[0] as Map<String, dynamic> : null;
      if (att == null) return;

      final isEncrypted = att['is_encrypted'] == true;
      File? fileToShare;

      if (isEncrypted) {
        // File cifrato: usa il metodo di decifratura esistente
        fileToShare = await _decryptAttachmentToFile(att, message);
      } else {
        // File in chiaro: scarica direttamente
        final fileUrl = att['file']?.toString() ?? '';
        if (fileUrl.isEmpty) return;

        final token = ApiService().accessToken;
        final uri = fileUrl.startsWith('http') ? fileUrl : '${AppConstants.baseUrl}$fileUrl';
        final response = await http.get(
          Uri.parse(uri),
          headers: token != null ? {'Authorization': 'Bearer $token'} : {},
        );

        if (response.statusCode == 200) {
          final fileName = att['file_name']?.toString() ?? att['original_filename']?.toString() ?? 'file';
          final tempDir = await getTemporaryDirectory();
          fileToShare = File('${tempDir.path}/share_$fileName');
          await fileToShare.writeAsBytes(response.bodyBytes);
        }
      }

      if (fileToShare != null && await fileToShare.exists()) {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(fileToShare.path)],
            text: content.isNotEmpty && content != '🔒 Messaggio cifrato' ? content : null,
            subject: 'SecureChat',
          ),
        );
      } else {
        // Fallback: condividi come testo
        await SharePlus.instance.share(
          ShareParams(text: content, subject: 'SecureChat'),
        );
      }
    } catch (e) {
      debugPrint('Share external error: $e');
      await SharePlus.instance.share(
        ShareParams(text: content, subject: 'SecureChat'),
      );
    }
  }

  Future<void> _addReaction(Map<String, dynamic> message, String emoji) async {
    final messageId = message['id'];
    if (messageId == null) return;
    final messageIdStr = messageId.toString();
    final currentUserId = _effectiveCurrentUserId;

    // 1. Chiudi il bottom sheet PRIMA
    if (mounted) Navigator.pop(context);

    // 2. Haptic
    SoundService().playTap();

    // 3. Optimistic update locale
    setState(() {
      final index = _messages.indexWhere((m) => m['id']?.toString() == messageIdStr);
      if (index != -1) {
        final msg = Map<String, dynamic>.from(_messages[index]);
        final reactionsRaw = msg['reactions'];
        final reactions = reactionsRaw is List
            ? List<Map<String, dynamic>>.from(
                reactionsRaw.map((r) => r is Map ? Map<String, dynamic>.from(r) : <String, dynamic>{}),
              )
            : <Map<String, dynamic>>[];

        final existingIndex = reactions.indexWhere((r) {
          final rEmoji = r['emoji']?.toString();
          final rUserId = r['user'] is Map ? (r['user'] as Map)['id'] : null;
          final rUserIdStr = rUserId?.toString();
          final curIdStr = currentUserId?.toString();
          return rEmoji == emoji && rUserIdStr != null && rUserIdStr == curIdStr;
        });

        if (existingIndex != -1) {
          reactions.removeAt(existingIndex);
        } else {
          reactions.add({
            'emoji': emoji,
            'user': {'id': currentUserId},
          });
        }

        msg['reactions'] = reactions;
        _messages[index] = msg;
      }
    });

    // 4. Chiama API in background
    try {
      await ApiService().post('/chat/messages/$messageIdStr/react/', body: {'emoji': emoji});
    } catch (e) {
      debugPrint('Error adding reaction: $e');
      if (mounted) _loadMessagesSilent();
    }
  }

  Map<String, int> _groupReactions(List<dynamic> reactions) {
    final map = <String, int>{};
    for (final r in reactions) {
      final emoji = (r is Map ? r['emoji'] : null)?.toString() ?? '';
      map[emoji] = (map[emoji] ?? 0) + 1;
    }
    return map;
  }

  void _showMessageActions(BuildContext context, Map<String, dynamic> message, bool isMe) {
    final messageText = message['content']?.toString() ?? '';

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE0E0E0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: ['👍', '❤️', '😂', '😮', '😢', '🙏', '🔥'].map((emoji) {
                    return GestureDetector(
                      onTap: () => _addReaction(message, emoji),
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF5F5F5),
                          borderRadius: BorderRadius.circular(21),
                        ),
                        child: Center(
                          child: Text(emoji, style: const TextStyle(fontSize: 22)),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const Divider(height: 1),
              _actionTile(
                icon: Icons.reply_rounded,
                color: const Color(0xFF2ABFBF),
                label: 'Rispondi',
                onTap: () {
                  Navigator.pop(context);
                  _setReplyMessage(message);
                },
              ),
              if (messageText.isNotEmpty)
                _actionTile(
                  icon: Icons.copy_rounded,
                  color: const Color(0xFF3A6AB0),
                  label: 'Copia',
                  onTap: () {
                    Navigator.pop(context);
                    Clipboard.setData(ClipboardData(text: messageText));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Messaggio copiato'), duration: Duration(seconds: 1)),
                    );
                  },
                ),
              _actionTile(
                icon: Icons.shortcut_rounded,
                color: const Color(0xFF4CAF50),
                label: 'Inoltra',
                onTap: () {
                  Navigator.pop(context);
                  _forwardMessage(message);
                },
              ),
              if (isMe && messageText.isNotEmpty)
                _actionTile(
                  icon: Icons.edit_rounded,
                  color: const Color(0xFFFF9800),
                  label: 'Modifica',
                  onTap: () {
                    Navigator.pop(context);
                    _editMessage(message);
                  },
                ),
              _actionTile(
                icon: Icons.delete_outline_rounded,
                color: const Color(0xFFE91E63),
                label: 'Elimina per me',
                onTap: () {
                  Navigator.pop(context);
                  _deleteMessage(message, forAll: false);
                },
              ),
              if (isMe)
                _actionTile(
                  icon: Icons.delete_forever_rounded,
                  color: const Color(0xFFF44336),
                  label: 'Elimina per tutti',
                  onTap: () {
                    Navigator.pop(context);
                    _deleteMessage(message, forAll: true);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Map<String, String> _getAuthHeaders() {
    return {};
  }

  Widget _getFileIconWidget(String fileName, {double size = 36, Color? iconColor}) {
    final fallbackColor = iconColor ?? const Color(0xFF3A6AB0);
    if (fileName.isEmpty) {
      return Icon(Icons.insert_drive_file_rounded, color: fallbackColor, size: size);
    }
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
        return Icon(Icons.insert_drive_file_rounded, color: fallbackColor, size: size);
    }
    return Image.asset(
      assetPath!,
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stack) {
        return Icon(Icons.insert_drive_file_rounded, color: fallbackColor, size: size);
      },
    );
  }

  void _openFileUrl(String url, {String? fileName, String? mimeType, String? attachmentId}) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => DocumentViewerScreen(
          fileUrl: url,
          fileName: fileName ?? url.split('/').last,
          mimeType: mimeType ?? '',
          attachmentId: attachmentId,
        ),
      ),
    );
  }

  Future<File> _saveTempFile(Uint8List bytes, String fileName, {String? attachmentId}) async {
    final dir = await getTemporaryDirectory();
    final safeName = fileName.replaceAll(RegExp(r'[^\w\.\-]'), '_');
    final uniqueId = attachmentId ?? DateTime.now().millisecondsSinceEpoch.toString();
    final file = File('${dir.path}/securechat_${uniqueId}_$safeName');
    await file.writeAsBytes(bytes);
    return file;
  }

  void _openLocalFile(File file) {
    OpenFilex.open(file.path);
  }

  /// Decifra l'allegato E2E e restituisce il file temporaneo; null in caso di errore.
  /// Usa _decryptedFileCache per evitare ri-decrypt a ogni rebuild.
  Future<File?> _decryptAttachmentToFile(
    Map<String, dynamic> att,
    Map<String, dynamic> message,
  ) async {
    final attachmentId = att['id']?.toString();
    if (attachmentId == null || attachmentId.isEmpty) return null;
    if (_decryptedFileCache.containsKey(attachmentId)) {
      final cached = _decryptedFileCache[attachmentId]!;
      if (cached.existsSync()) return cached;
      _decryptedFileCache.remove(attachmentId);
    }
    final sender = message['sender'];
    final senderIdRaw = sender is Map ? (sender as Map)['id'] : null;
    final senderUserId = senderIdRaw is int
        ? senderIdRaw
        : int.tryParse(senderIdRaw?.toString() ?? '');
    if (senderUserId == null || senderUserId == 0) return null;
    try {
      String? fileKeyB64 = _attachmentKeyCache[attachmentId];
      if (fileKeyB64 == null) {
        final prefs = await SharedPreferences.getInstance();
        fileKeyB64 = prefs.getString('scp_att_key_$attachmentId');
      }
      if (fileKeyB64 == null || fileKeyB64.isEmpty) return null;
      // Nome file con estensione: caption dal payload E2E (cache/prefs) o da mime_type
      String fileName = _attachmentCaptionCache[attachmentId]?.trim() ?? '';
      if (fileName.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        fileName = prefs.getString('scp_att_caption_$attachmentId')?.trim() ?? '';
      }
      if (fileName.isEmpty) {
        final mimeType = att['mime_type']?.toString() ?? '';
        final ext = _extensionFromMimeType(mimeType);
        fileName = ext.isNotEmpty ? 'decrypted$ext' : 'decrypted_file';
      }
      final fileKey = await MediaEncryptionService.secretKeyFromBytes(base64Decode(fileKeyB64));
      await AuthService().refreshAccessTokenIfNeeded();
      final token = ApiService().accessToken;
      if (token == null) return null;
      final downloadUrl = Uri.parse('${AppConstants.baseUrl}/chat/media/$attachmentId/download/');
      final response = await http.get(
        downloadUrl,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode != 200) return null;
      final encryptedBytes = Uint8List.fromList(response.bodyBytes);
      final plainBytes = await MediaEncryptionService.decryptFile(encryptedBytes, fileKey);
      final expectedHash = att['file_hash']?.toString() ?? '';
      if (expectedHash.isNotEmpty) {
        final actualHash = await MediaEncryptionService.computeFileHash(plainBytes);
        if (actualHash != expectedHash) return null;
      }
      final tempFile = await _saveTempFile(plainBytes, fileName, attachmentId: attachmentId);
      if (mounted) _decryptedFileCache[attachmentId] = tempFile;
      return tempFile;
    } catch (e) {
      debugPrint('Decrypt attachment error: $e');
      return null;
    }
  }

  void _openDecryptedFile(File file, String mimeType) {
    OpenFilex.open(file.path);
  }

  void _showFullImage(String imageUrl, [File? imageFile]) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          body: Center(
            child: InteractiveViewer(
              child: imageFile != null
                  ? Image.file(imageFile, fit: BoxFit.contain)
                  : Image.network(imageUrl, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  /// URL per immagini e file — usa /media/ diretto (senza auth, senza range request)
  String _buildDirectMediaUrl(String? rawUrl) {
    if (rawUrl == null || rawUrl.isEmpty) return '';
    String path = rawUrl
        .replaceAll('http://testserver', '')
        .replaceAll('http://localhost:8000', '')
        .replaceAll('http://127.0.0.1:8000', '');
    // Converti /api/chat/media/ in /media/ per URL diretto
    if (path.contains('/api/chat/media/')) {
      path = path.replaceFirst('/api/chat/media/', '/media/');
    }
    if (path.startsWith('/media/')) {
      return '${AppConstants.mediaBaseUrl}$path';
    }
    if (path.startsWith('http')) return path;
    return '${AppConstants.mediaBaseUrl}$path';
  }

  /// URL per video/audio — usa endpoint con range request support e auth
  String _buildStreamMediaUrl(String? rawUrl) {
    if (rawUrl == null || rawUrl.isEmpty) return '';
    String path = rawUrl
        .replaceAll('http://testserver', '')
        .replaceAll('http://localhost:8000', '')
        .replaceAll('http://127.0.0.1:8000', '');
    if (path.startsWith('/media/')) {
      final relativePath = path.substring(7);
      return '${AppConstants.baseUrl}/chat/media/$relativePath';
    }
    if (path.startsWith('http')) return path;
    return '${AppConstants.mediaBaseUrl}$path';
  }

  Future<void> _preloadVideoThumbnail(String messageId, String? videoUrl, {File? localFile}) async {
    if (_videoThumbnailCache.containsKey(messageId)) return;
    _videoThumbnailCache[messageId] = null;
    if (_videoControllers.length >= 3) {
      final oldestKey = _videoControllers.keys.first;
      if (oldestKey != messageId) {
        _chewieControllers[oldestKey]?.dispose();
        _videoControllers[oldestKey]?.dispose();
        _chewieControllers.remove(oldestKey);
        _videoControllers.remove(oldestKey);
        _videoThumbnailCache.remove(oldestKey);
      }
    }
    try {
      final VideoPlayerController controller = localFile != null
          ? VideoPlayerController.file(localFile)
          : VideoPlayerController.networkUrl(
              Uri.parse(videoUrl!),
              httpHeaders: ApiService().accessToken != null
                  ? {'Authorization': 'Bearer ${ApiService().accessToken}'}
                  : <String, String>{},
            );
      await controller.initialize();
      if (mounted) {
        setState(() {
          _videoControllers[messageId] = controller;
          _videoThumbnailCache[messageId] = 'initialized';
        });
      }
    } catch (e) {
      debugPrint('Errore preload video: $e');
      if (mounted) _videoThumbnailCache.remove(messageId);
    }
  }

  void _openVideoPlayer(String videoUrl, {File? localFile}) {
    final token = ApiService().accessToken ?? '';
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (context) => _VideoPlayerScreen(
          videoUrl: videoUrl,
          token: token,
          localFile: localFile,
        ),
      ),
    );
  }

  Widget _buildVideoPreview(String messageId, String? videoUrl, String? thumbUrl, bool isMe, {File? localFile}) {
    // Se chewie è attivo, mostra il player con controlli custom
    if (_chewieControllers.containsKey(messageId)) {
      final videoController = _videoControllers[messageId]!;
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240, maxHeight: 170),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            width: 240,
            height: 170,
            child: Stack(
              fit: StackFit.expand,
              children: [
                VideoPlayer(videoController),
                GestureDetector(
                  onTap: () {
                    setState(() {
                      if (videoController.value.isPlaying) {
                        videoController.pause();
                        _isPlayingMedia = false;
                      } else {
                        videoController.play();
                        _isPlayingMedia = true;
                      }
                    });
                  },
                  child: Container(
                    color: Colors.transparent,
                    child: Center(
                      child: ListenableBuilder(
                        listenable: videoController,
                        builder: (context, _) {
                          return AnimatedOpacity(
                            opacity: videoController.value.isPlaying ? 0.0 : 1.0,
                            duration: const Duration(milliseconds: 200),
                            child: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.5),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                videoController.value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 30,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: VideoProgressIndicator(
                    videoController,
                    allowScrubbing: true,
                    colors: const VideoProgressColors(
                      playedColor: Color(0xFF2ABFBF),
                      bufferedColor: Colors.white38,
                      backgroundColor: Colors.white24,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 2),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: GestureDetector(
                    onTap: () {
                      videoController.pause();
                      setState(() => _isPlayingMedia = false);
                      if (localFile != null) {
                        _openVideoPlayer('', localFile: localFile);
                      } else if (videoUrl != null) {
                        _openVideoPlayer(videoUrl);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(Icons.fullscreen_rounded, color: Colors.white, size: 20),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Thumbnail
    Widget thumbnailWidget;
    if (_videoControllers.containsKey(messageId) && _videoControllers[messageId]!.value.isInitialized) {
      thumbnailWidget = VideoPlayer(_videoControllers[messageId]!);
    } else if (thumbUrl != null && thumbUrl.isNotEmpty) {
      thumbnailWidget = Image.network(thumbUrl, fit: BoxFit.cover,
        width: double.infinity, height: double.infinity,
        errorBuilder: (_, __, ___) => const Icon(Icons.videocam_rounded, color: Color(0xFF9E9E9E), size: 48));
    } else {
      if ((localFile != null || videoUrl != null) && !_videoThumbnailCache.containsKey(messageId)) {
        _preloadVideoThumbnail(messageId, videoUrl, localFile: localFile);
      }
      thumbnailWidget = const Center(
        child: Icon(Icons.videocam_rounded, color: Color(0xFF9E9E9E), size: 48),
      );
    }

    return GestureDetector(
      onTap: () {
        if (localFile != null) {
          _playInlineVideo(messageId, videoUrl, localFile: localFile);
        } else if (videoUrl != null) {
          _playInlineVideo(messageId, videoUrl);
        }
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240, maxHeight: 170),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: 240,
            height: 170,
            color: const Color(0xFFF0F0F0),
            child: Stack(
              fit: StackFit.expand,
              children: [
                thumbnailWidget,
                Center(
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 36),
                  ),
                ),
                Positioned(
                  bottom: 8,
                  right: 8,
                  child: GestureDetector(
                    onTap: () {
                      if (localFile != null) {
                        _openVideoPlayer('', localFile: localFile);
                      } else if (videoUrl != null) {
                        _openVideoPlayer(videoUrl);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(Icons.fullscreen_rounded, color: Colors.white, size: 20),
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

  Future<void> _playInlineVideo(String messageId, String? videoUrl, {File? localFile}) async {
    if (_videoControllers.containsKey(messageId) &&
        _videoControllers[messageId]!.value.isInitialized) {
      final controller = _videoControllers[messageId]!;
      for (final entry in _videoControllers.entries) {
        if (entry.key != messageId) entry.value.pause();
      }
      final chewie = ChewieController(
        videoPlayerController: controller,
        autoPlay: true,
        looping: false,
        showControls: false,
        allowFullScreen: false,
      );
      if (mounted) {
        setState(() {
          _chewieControllers[messageId] = chewie;
          _isPlayingMedia = true;
        });
      }
    } else {
      await _initInlineVideo(messageId, videoUrl, localFile: localFile);
    }
  }

  Future<void> _initInlineVideo(String messageId, String? videoUrl, {File? localFile}) async {
    if (_videoControllers.length >= 3) {
      final oldestKey = _videoControllers.keys.first;
      _chewieControllers[oldestKey]?.dispose();
      _videoControllers[oldestKey]?.dispose();
      _chewieControllers.remove(oldestKey);
      _videoControllers.remove(oldestKey);
      if (mounted) setState(() => _isPlayingMedia = false);
    }
    try {
      for (final entry in _videoControllers.entries) {
        if (entry.key != messageId) entry.value.pause();
      }

      final VideoPlayerController controller = localFile != null
          ? VideoPlayerController.file(localFile)
          : VideoPlayerController.networkUrl(
              Uri.parse(videoUrl!),
              httpHeaders: ApiService().accessToken != null
                  ? {'Authorization': 'Bearer ${ApiService().accessToken}'}
                  : <String, String>{},
            );
      await controller.initialize();

      final chewie = ChewieController(
        videoPlayerController: controller,
        autoPlay: true,
        looping: false,
        showControls: false,
        allowFullScreen: false,
      );

      if (mounted) {
        setState(() {
          _videoControllers[messageId] = controller;
          _chewieControllers[messageId] = chewie;
          _isPlayingMedia = true;
        });
      }
    } catch (e) {
      debugPrint('Errore init video inline: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Impossibile riprodurre il video${e.toString().length > 60 ? ': ${e.toString().substring(0, 60)}...' : ': $e'}',
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    }
  }

  String _formatTime(dynamic createdAt) {
    if (createdAt == null) return '';
    try {
      final dt = DateTime.parse(createdAt.toString()).toLocal();
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }

  Widget _buildReplyPreview(Map<String, dynamic> message, bool isMe) {
    final replyPreview = message['reply_to_preview'];
    if (replyPreview == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: () => _scrollToMessage(message['reply_to']?.toString()),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isMe
                ? Colors.white.withValues(alpha: 0.25)
                : const Color(0xFF2ABFBF).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border(
              left: BorderSide(
                color: isMe ? Colors.white : const Color(0xFF2ABFBF),
                width: 3,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                (replyPreview is Map ? (replyPreview as Map)['sender_name']?.toString() : null) ?? '',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isMe ? Colors.white : const Color(0xFF2ABFBF),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _getReplyText(message),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: isMe ? Colors.white.withValues(alpha: 0.8) : const Color(0xFF6B7280),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReactionsRow(Map<String, dynamic> message, bool isMe) {
    final reactions = message['reactions'] as List?;
    if (reactions == null || reactions.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 4),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: _groupReactions(reactions).entries.map((e) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text('${e.key} ${e.value}', style: const TextStyle(fontSize: 13)),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildAttachmentContent(Map<String, dynamic> message, bool isMe) {
    final messageType = message['message_type']?.toString() ?? 'text';
    final attachments = message['attachments'] as List? ?? [];
    if (attachments.isEmpty) return const SizedBox.shrink();
    final att = attachments[0] as Map<String, dynamic>;
    final isEncrypted = att['is_encrypted'] == true;

    if (isEncrypted) {
      return FutureBuilder<File?>(
        future: _decryptAttachmentToFile(att, message),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Container(
              width: 240,
              height: 180,
              decoration: BoxDecoration(
                color: const Color(0xFFF0F0F0),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Center(
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2ABFBF)),
              ),
            );
          }
          final decryptedFile = snapshot.data;
          if (decryptedFile == null || !decryptedFile.existsSync()) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isMe ? const Color(0xFF2ABFBF) : const Color(0xFFE0E0E0),
                  width: 1.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock, color: Color(0xFF2ABFBF), size: 28),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      '🔒 Allegato cifrato — sessione non disponibile',
                      style: const TextStyle(fontSize: 13, color: Color(0xFF757575)),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                    ),
                  ),
                ],
              ),
            );
          }
          final mimeType = att['mime_type']?.toString() ?? '';
          final attachmentId = att['id']?.toString() ?? '';
          String displayFileName = _attachmentCaptionCache[attachmentId] ?? att['file_name']?.toString() ?? '';
          if (displayFileName.isEmpty || displayFileName == 'encrypted') {
            displayFileName = decryptedFile.path.split(RegExp(r'[/\\]')).last;
          }
          if (messageType == 'image' || (mimeType.isNotEmpty && mimeType.startsWith('image/'))) {
            return GestureDetector(
              onTap: () => _showFullImage('', decryptedFile),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.file(
                  decryptedFile,
                  width: 240,
                  height: 180,
                  fit: BoxFit.cover,
                ),
              ),
            );
          }
          if (messageType == 'video' || (mimeType.isNotEmpty && mimeType.startsWith('video/'))) {
            final messageId = message['id']?.toString() ?? '';
            return _buildVideoPreview(messageId, null, null, isMe, localFile: decryptedFile);
          }
          if (messageType == 'audio' || messageType == 'voice' ||
              (mimeType.isNotEmpty && (mimeType.startsWith('audio/') || mimeType == 'audio'))) {
            final messageId = message['id']?.toString() ?? '';
            final resolvedAudioUrl = _buildStreamMediaUrl(att['file']?.toString());
            return ValueListenableBuilder<String?>(
              valueListenable: _playingAudioIdNotifier,
              builder: (context, playingId, _) {
                return ValueListenableBuilder<Duration>(
                  valueListenable: _audioPositionNotifier,
                  builder: (context, position, _) {
                    return ValueListenableBuilder<Duration>(
                      valueListenable: _audioDurationNotifier,
                      builder: (context, duration, _) {
                        return AudioPlayerWidget(
                          key: ValueKey('audio_${message['id']}'),
                          messageId: messageId,
                          audioUrl: resolvedAudioUrl.isNotEmpty ? resolvedAudioUrl : null,
                          localFile: decryptedFile,
                          isMe: isMe,
                          createdAt: message['created_at']?.toString() ?? '',
                          durationSec: att['duration'] as int? ?? 0,
                          isPlaying: playingId == messageId,
                          position: playingId == messageId ? position : Duration.zero,
                          duration: playingId == messageId ? duration : Duration.zero,
                          speed: _audioPlaybackSpeed,
                          onTap: () async {
                            if (_playingAudioIdNotifier.value == messageId) {
                              await _audioPlayer?.pause();
                              _playingAudioIdNotifier.value = null;
                              _isPlayingMedia = false;
                            } else {
                              await _audioPlayer?.stop();
                              _playingAudioIdNotifier.value = messageId;
                              _isPlayingMedia = true;
                              if (decryptedFile != null) {
                                await _audioPlayer?.play(ap.DeviceFileSource(decryptedFile.path));
                                await _audioPlayer?.setPlaybackRate(_audioPlaybackSpeed);
                              } else if (resolvedAudioUrl.isNotEmpty) {
                                if (resolvedAudioUrl.contains('chat/media')) {
                                  _downloadAndPlayAudio(messageId, resolvedAudioUrl, ApiService().accessToken);
                                } else {
                                  await _audioPlayer?.play(ap.UrlSource(resolvedAudioUrl));
                                  await _audioPlayer?.setPlaybackRate(_audioPlaybackSpeed);
                                }
                              }
                            }
                          },
                          onSpeedTap: () {
                            _audioPlaybackSpeed = _audioPlaybackSpeed == 1.0 ? 1.5 : _audioPlaybackSpeed == 1.5 ? 2.0 : 1.0;
                            if (_playingAudioIdNotifier.value == messageId) _audioPlayer?.setPlaybackRate(_audioPlaybackSpeed);
                            _playingAudioIdNotifier.notifyListeners();
                          },
                        );
                      },
                    );
                  },
                );
              },
            );
          }
          return GestureDetector(
            onTap: () => _openDecryptedFile(decryptedFile, mimeType),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isMe ? const Color(0xFF2ABFBF) : const Color(0xFFE0E0E0),
                  width: 1.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _getFileIconWidget(displayFileName, size: 36),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          displayFileName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isMe ? const Color(0xFF2ABFBF) : const Color(0xFF1A2B4A),
                          ),
                        ),
                        Text(
                          _formatFileSize(decryptedFile.lengthSync()),
                          style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    switch (messageType) {
      case 'image':
        final imageUrl = _buildDirectMediaUrl(att['file']?.toString() ?? att['thumbnail']?.toString());
        if (imageUrl.isNotEmpty) {
          return GestureDetector(
            onTap: () => _showFullImage(imageUrl),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.network(
                imageUrl,
                width: 240,
                height: 180,
                fit: BoxFit.cover,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return Container(
                    width: 240,
                    height: 180,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0F0F0),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Center(
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2ABFBF)),
                    ),
                  );
                },
                errorBuilder: (context, error, stack) {
                  return Container(
                    width: 240,
                    height: 120,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0F0F0),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Center(
                      child: Icon(Icons.broken_image_rounded, color: Color(0xFF9E9E9E), size: 32),
                    ),
                  );
                },
              ),
            ),
          );
        }
        return const SizedBox.shrink();

      case 'video':
        final thumbUrl = _buildDirectMediaUrl(att['thumbnail']?.toString());
        final videoUrl = _buildStreamMediaUrl(att['file']?.toString());
        final messageId = message['id']?.toString() ?? '';
        return _buildVideoPreview(
          messageId,
          videoUrl.isNotEmpty ? videoUrl : null,
          thumbUrl.isNotEmpty ? thumbUrl : null,
          isMe,
        );

      case 'file':
        final attId = att['id']?.toString() ?? '';
        final fName = _attachmentCaptionCache[attId] ?? att['file_name']?.toString() ?? 'Documento';
        final fMime = att['mime_type']?.toString() ?? '';
        final fileUrl = _buildDirectMediaUrl(att['file']?.toString());
        return GestureDetector(
          onTap: () {
            if (fileUrl.isNotEmpty) {
              final attId = att['id']?.toString();
              _openFileUrl(fileUrl, fileName: fName, mimeType: fMime, attachmentId: attId);
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isMe ? const Color(0xFF2ABFBF) : const Color(0xFFE0E0E0),
                width: 1.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _getFileIconWidget(fName, size: 36),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    fName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isMe ? const Color(0xFF2ABFBF) : const Color(0xFF1A2B4A),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );

      case 'audio':
      case 'voice': {
        final messageId = message['id']?.toString() ?? '';
        final resolvedAudioUrl = _buildStreamMediaUrl(att['file']?.toString());
        return ValueListenableBuilder<String?>(
          valueListenable: _playingAudioIdNotifier,
          builder: (context, playingId, _) {
            return ValueListenableBuilder<Duration>(
              valueListenable: _audioPositionNotifier,
              builder: (context, position, _) {
                return ValueListenableBuilder<Duration>(
                  valueListenable: _audioDurationNotifier,
                  builder: (context, duration, _) {
                    return AudioPlayerWidget(
                      key: ValueKey('audio_${message['id']}'),
                      messageId: messageId,
                      audioUrl: resolvedAudioUrl.isNotEmpty ? resolvedAudioUrl : null,
                      localFile: null,
                      isMe: isMe,
                      createdAt: message['created_at']?.toString() ?? '',
                      durationSec: att['duration'] as int? ?? 0,
                      isPlaying: playingId == messageId,
                      position: playingId == messageId ? position : Duration.zero,
                      duration: playingId == messageId ? duration : Duration.zero,
                      speed: _audioPlaybackSpeed,
                      onTap: () async {
                        if (_playingAudioIdNotifier.value == messageId) {
                          await _audioPlayer?.pause();
                          _playingAudioIdNotifier.value = null;
                          _isPlayingMedia = false;
                        } else {
                          await _audioPlayer?.stop();
                          _playingAudioIdNotifier.value = messageId;
                          _isPlayingMedia = true;
                          if (resolvedAudioUrl.isNotEmpty) {
                            if (resolvedAudioUrl.contains('chat/media')) {
                              _downloadAndPlayAudio(messageId, resolvedAudioUrl, ApiService().accessToken);
                            } else {
                              await _audioPlayer?.play(ap.UrlSource(resolvedAudioUrl));
                              await _audioPlayer?.setPlaybackRate(_audioPlaybackSpeed);
                            }
                          }
                        }
                      },
                      onSpeedTap: () {
                        _audioPlaybackSpeed = _audioPlaybackSpeed == 1.0 ? 1.5 : _audioPlaybackSpeed == 1.5 ? 2.0 : 1.0;
                        if (_playingAudioIdNotifier.value == messageId) _audioPlayer?.setPlaybackRate(_audioPlaybackSpeed);
                        _playingAudioIdNotifier.notifyListeners();
                      },
                    );
                  },
                );
              },
            );
          },
        );
      }

      default:
        return const SizedBox.shrink();
    }
  }

  /// Spunte stato messaggio (solo per messaggi inviati da me): ✓ inviato, ✓✓ consegnato, ✓✓ blu letto.
  /// Backend: statuses[].user è un intero (user ID), non un oggetto {id: ...}.
  Widget _buildMessageStatus(Map<String, dynamic> msg, bool isMe) {
    if (!isMe) return const SizedBox.shrink();

    final statuses = msg['statuses'] as List? ?? [];
    final currentUserId = _effectiveCurrentUserId;

    // user è un intero diretto, non un oggetto
    final otherStatuses = statuses.where((s) {
      if (s is! Map) return false;
      final userId = (s as Map)['user'];
      final id = userId is int ? userId : int.tryParse(userId?.toString() ?? '');
      return id != null && id != currentUserId;
    }).toList();

    final isRead = otherStatuses.any((s) => (s as Map)['status'] == 'read');
    final isDelivered = otherStatuses.any((s) => (s as Map)['status'] == 'delivered');

    // Solo bianche: 1 spunta = inviato, 2 spunte = consegnato/letto
    if (isRead) return Icon(Icons.done_all, size: 14, color: Colors.white); // 2 spunte = letto
    if (isDelivered) return Icon(Icons.done_all, size: 14, color: Colors.white70); // 2 spunte = consegnato
    return Icon(Icons.done, size: 14, color: Colors.white70); // 1 spunta = inviato
  }

  Widget _buildMessageItem(BuildContext context, Map<String, dynamic> message, int index) {
    final sender = message['sender'];
    final senderId = sender is Map ? (sender as Map)['id'] : null;
    final isMe = _effectiveCurrentUserId != null &&
        senderId != null &&
        _effectiveCurrentUserId == (senderId is int ? senderId : int.tryParse(senderId.toString()));
    final messageType = message['message_type']?.toString() ?? 'text';
    final timeStr = _formatTime(message['created_at']);
    final isAttachment = ['image', 'video', 'file', 'audio', 'voice'].contains(messageType);
    final attachments = message['attachments'] as List? ?? [];
    final hasEncryptedAttachment = attachments.isNotEmpty &&
        (attachments[0] is Map) &&
        (attachments[0] as Map)['is_encrypted'] == true;

    if ((isAttachment && attachments.isNotEmpty) || hasEncryptedAttachment) {
      final caption = (message['content']?.toString() ?? '').trim();
      final attName = attachments.isNotEmpty && attachments[0] is Map
          ? (attachments[0] as Map)['file_name']?.toString() ?? ''
          : '';
      // Per allegati E2E non mostrare la caption (è il fileName); il timestamp è già sotto.
      final showCaption = caption.isNotEmpty &&
          !hasEncryptedAttachment &&
          (attName.isEmpty || caption != attName);

      final maxWidth = MediaQuery.of(context).size.width * 0.72;
      final attachmentColumn = Padding(
        padding: EdgeInsets.only(
          left: isMe ? 60 : ((_conversation?.isGroup ?? false) ? 0 : 12),
          right: isMe ? 12 : 60,
          top: 4,
          bottom: 4,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Align(
            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message['reply_to'] != null || message['reply_to_preview'] != null)
                  _buildReplyPreview(message, isMe),
                _buildAttachmentContent(message, isMe),
              if (showCaption)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    caption,
                    style: TextStyle(
                      fontSize: 13,
                      color: isMe ? const Color(0xFF2ABFBF) : const Color(0xFF1A2B4A),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                  children: [
                    Text(
                      timeStr,
                      style: const TextStyle(fontSize: 11, color: Color(0xFF9E9E9E)),
                    ),
                    if (isMe) ...[
                      const SizedBox(width: 3),
                      _buildMessageStatus(message, isMe),
                    ],
                  ],
                ),
              ),
                if ((message['reactions'] as List?)?.isNotEmpty ?? false)
                  _buildReactionsRow(message, isMe),
              ],
            ),
          ),
        ),
      );
      final isGroup = _conversation?.isGroup ?? false;
      final sender = message['sender'] as Map<String, dynamic>?;
      final senderName = sender != null
          ? '${sender['first_name'] ?? ''} ${sender['last_name'] ?? ''}'.trim()
          : '';
      final senderAvatar = sender?['avatar']?.toString();

      final content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (isGroup && !isMe)
            GestureDetector(
              onLongPress: () => _showMessageActions(context, message, isMe),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 8, bottom: 4),
                    child: UserAvatarWidget(
                      avatarUrl: senderAvatar,
                      displayName: senderName.isNotEmpty ? senderName : 'U',
                      size: 28,
                      borderWidth: 0,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 4, bottom: 2),
                          child: Text(
                            senderName,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF2ABFBF),
                            ),
                          ),
                        ),
                        attachmentColumn,
                      ],
                    ),
                  ),
                ],
              ),
            )
          else
            GestureDetector(
              onLongPress: () => _showMessageActions(context, message, isMe),
              child: attachmentColumn,
            ),
        ],
      );
      return Dismissible(
        key: Key(message['id']?.toString() ?? index.toString()),
        direction: DismissDirection.startToEnd,
        confirmDismiss: (direction) async {
          _setReplyMessage(message);
          return false;
        },
        background: Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 20),
          child: const Icon(Icons.reply_rounded, color: Color(0xFF2ABFBF), size: 28),
        ),
        child: content,
      );
    }

    return _buildMessageBubble(context, message, index);
  }

  Widget _buildMessageContent(Map<String, dynamic> message, bool isMe) {
    final messageType = message['message_type']?.toString() ?? 'text';
    final messageText = message['content']?.toString() ?? '';
    final attachments = message['attachments'] as List? ?? [];

    // Immagine con allegato
    if (messageType == 'image' && attachments.isNotEmpty) {
      final att = attachments[0] as Map<String, dynamic>;
      final imageUrl = _buildDirectMediaUrl(att['file']?.toString() ?? att['thumbnail']?.toString());
      if (imageUrl.isNotEmpty) {
        return GestureDetector(
          onTap: () => _showFullImage(imageUrl),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.network(
              imageUrl,
              width: 220,
              height: 220,
              fit: BoxFit.cover,
              loadingBuilder: (context, child, progress) {
                if (progress == null) return child;
                return Container(
                  width: 220,
                  height: 160,
                  color: isMe ? Colors.white10 : const Color(0xFFF0F0F0),
                  child: const Center(
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2ABFBF)),
                  ),
                );
              },
              errorBuilder: (context, error, stack) {
                debugPrint('Errore caricamento immagine: $error - URL: $imageUrl');
                return Container(
                  width: 220,
                  height: 100,
                  color: isMe ? Colors.white10 : const Color(0xFFF0F0F0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.broken_image, color: isMe ? Colors.white70 : Colors.grey, size: 32),
                      const SizedBox(height: 4),
                      Text(
                        'Immagine non disponibile',
                        style: TextStyle(fontSize: 11, color: isMe ? Colors.white70 : Colors.grey),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      }
    }

    // Video con allegato
    if (messageType == 'video' && attachments.isNotEmpty) {
      final att = attachments[0] as Map<String, dynamic>;
      final thumbUrl = _buildDirectMediaUrl(att['thumbnail']?.toString());
      return Container(
        width: 220,
        height: 160,
        decoration: BoxDecoration(
          color: isMe ? Colors.white10 : const Color(0xFFF0F0F0),
          borderRadius: BorderRadius.circular(10),
          image: thumbUrl.isNotEmpty
              ? DecorationImage(
                  image: NetworkImage(thumbUrl),
                  fit: BoxFit.cover,
                )
              : null,
        ),
        child: Center(
          child: Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
            child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 32),
          ),
        ),
      );
    }

    // File/documento con allegato
    if (messageType == 'file' && attachments.isNotEmpty) {
      final att = attachments[0] as Map<String, dynamic>;
      final fName = att['file_name']?.toString() ?? 'Documento';
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE0E0E0), width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _getFileIconWidget(fName, size: 36),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                fName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isMe ? const Color(0xFF2ABFBF) : const Color(0xFF1A2B4A),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Posizione: message_type == 'location' oppure content è JSON {"type":"location",...}
    final isLocationType = messageType == 'location' || messageType == 'location_live';
    final isLocationJson = messageText.trim().startsWith('{"type":"location"');
    if (isLocationType || isLocationJson) {
      final loc = SessionManager.parseLocationPayload(messageText);
      if (loc != null) {
        final lat = (loc['lat'] as num?)?.toDouble();
        final lng = (loc['lng'] as num?)?.toDouble();
        if (lat != null && lng != null) {
          return _buildLocationWidget(lat, lng, isMe);
        }
      }
    }

    // Contatto: message_type == 'contact' oppure content è JSON {"type":"contact",...}
    final isContactType = messageType == 'contact';
    final isContactJson = messageText.trim().startsWith('{"type":"contact"');
    if (isContactType || isContactJson) {
      final contactData = SessionManager.parseContactPayload(messageText);
      if (contactData != null) {
        return _buildContactCard(contactData, isMe);
      }
    }

    // Default: testo normale (never show "(messaggio vuoto)" for E2E encrypted)
    final encryptedB64 = message['content_encrypted_b64']?.toString() ?? '';
    final displayText = messageText.isNotEmpty
        ? messageText
        : (encryptedB64.isNotEmpty ? '🔒 Messaggio cifrato' : '(messaggio vuoto)');
    return Text(
      displayText,
      style: TextStyle(
        color: isMe ? Colors.white : const Color(0xFF1A2B4A),
        fontSize: 15,
      ),
    );
  }

  Widget _buildLocationWidget(double lat, double lng, bool isMe) {
    final latLng = ll.LatLng(lat, lng);
    return GestureDetector(
      onTap: () {
        showModalBottomSheet<void>(
          context: context,
          backgroundColor: Colors.transparent,
          builder: (context) => Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Apri in', style: TextStyle(fontSize: 14, color: Color(0xFF757575))),
                    const SizedBox(height: 12),
                    ListTile(
                      leading: const Icon(Icons.map, color: Color(0xFF2ABFBF)),
                      title: const Text('Apple Maps'),
                      onTap: () async {
                        Navigator.pop(context);
                        final uri = Uri.parse('https://maps.apple.com/?daddr=$lat,$lng');
                        if (await canLaunchUrl(uri)) {
                          await launchUrl(uri, mode: LaunchMode.externalApplication);
                        }
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.map, color: Color(0xFF4285F4)),
                      title: const Text('Google Maps'),
                      onTap: () async {
                        Navigator.pop(context);
                        final uri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng');
                        if (await canLaunchUrl(uri)) {
                          await launchUrl(uri, mode: LaunchMode.externalApplication);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      child: SizedBox(
        width: 240,
        height: 160,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: FlutterMap(
            options: MapOptions(
              initialCenter: latLng,
              initialZoom: 15,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.securechat.app',
              ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: latLng,
                    width: 36,
                    height: 36,
                    child: const Icon(Icons.location_pin, color: Colors.red, size: 36),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContactCard(Map<String, dynamic> data, bool isMe) {
    final name = data['name']?.toString() ?? '';
    final phone = data['phone']?.toString() ?? '';
    final email = data['email']?.toString() ?? '';
    final color = isMe ? const Color(0xFF2ABFBF) : const Color(0xFF3A6AB0);
    return Container(
      width: 260,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.person_rounded, color: color, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name.isNotEmpty ? name : 'Contatto',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (phone.isNotEmpty) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () async {
                final uri = Uri.parse('tel:$phone');
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri);
                }
              },
              child: Row(
                children: [
                  const Icon(Icons.phone_rounded, size: 18, color: Color(0xFF757575)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(phone, style: const TextStyle(fontSize: 13, color: Color(0xFF1A2B4A)), overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          ],
          if (email.isNotEmpty) ...[
            const SizedBox(height: 4),
            GestureDetector(
              onTap: () async {
                final uri = Uri.parse('mailto:$email');
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri);
                }
              },
              child: Row(
                children: [
                  const Icon(Icons.email_rounded, size: 18, color: Color(0xFF757575)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(email, style: const TextStyle(fontSize: 13, color: Color(0xFF1A2B4A)), overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _actionTile({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: color, size: 22),
      ),
      title: Text(
        label,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: Color(0xFF1A2B4A),
        ),
      ),
      onTap: onTap,
      dense: true,
    );
  }

  Widget _buildMessageBubble(BuildContext context, Map<String, dynamic> message, int index) {
    final sender = message['sender'];
    final senderId = sender is Map ? (sender as Map)['id'] : null;
    final isMe = _effectiveCurrentUserId != null &&
        senderId != null &&
        _effectiveCurrentUserId == (senderId is int ? senderId : int.tryParse(senderId.toString()));
    final messageText = message['content']?.toString() ?? '';
    final timestamp = message['created_at']?.toString() ?? '';
    String timeStr = '';
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      timeStr =
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {}

    final reactions = message['reactions'] as List?;
    final hasReactions = (reactions?.isNotEmpty ?? false);
    final replyPreview = message['reply_to_preview'];
    final hasReply = (message['reply_to'] != null || replyPreview != null);
    final messageType = message['message_type']?.toString() ?? 'text';

    final bubble = Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          left: isMe ? 60 : ((_conversation?.isGroup ?? false) ? 0 : 12),
          right: isMe ? 12 : 60,
          top: 4,
          bottom: 4,
        ),
        padding: (messageType == 'image' || messageType == 'video')
            ? const EdgeInsets.all(4)
            : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isMe ? _teal : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
          border: isMe ? null : Border.all(color: const Color(0xFFE0E0E0)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (hasReply) ...[
              GestureDetector(
                onTap: () => _scrollToMessage(message['reply_to']?.toString()),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  margin: const EdgeInsets.only(bottom: 6),
                  decoration: BoxDecoration(
                    color: isMe
                        ? Colors.white.withValues(alpha: 0.25)
                        : const Color(0xFF2ABFBF).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border(
                      left: BorderSide(
                        color: isMe ? Colors.white : const Color(0xFF2ABFBF),
                        width: 3,
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (replyPreview is Map
                                ? (replyPreview as Map)['sender_name']?.toString()
                                : null) ??
                            '',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isMe ? Colors.white : const Color(0xFF2ABFBF),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _getReplyText(message),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: isMe ? Colors.white.withValues(alpha: 0.8) : const Color(0xFF6B7280),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            _buildMessageContent(message, isMe),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
              children: [
                Text(
                  timeStr,
                  style: TextStyle(
                    color: isMe ? Colors.white70 : _statusGray,
                    fontSize: 11,
                  ),
                ),
                if (isMe) ...[
                  const SizedBox(width: 3),
                  _buildMessageStatus(message, isMe),
                ],
              ],
            ),
          ],
        ),
      ),
    );

    final isGroup = _conversation?.isGroup ?? false;
    final senderData = message['sender'] as Map<String, dynamic>?;
    final senderName = senderData != null
        ? '${senderData['first_name'] ?? ''} ${senderData['last_name'] ?? ''}'.trim()
        : '';
    final senderAvatar = senderData?['avatar']?.toString();

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (isGroup && !isMe)
          GestureDetector(
            onLongPress: () => _showMessageActions(context, message, isMe),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 4),
                  child: UserAvatarWidget(
                    avatarUrl: senderAvatar,
                    displayName: senderName.isNotEmpty ? senderName : 'U',
                    size: 28,
                    borderWidth: 0,
                  ),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 4, bottom: 2),
                        child: Text(
                          senderName,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF2ABFBF),
                          ),
                        ),
                      ),
                      bubble,
                    ],
                  ),
                ),
              ],
            ),
          )
        else
          GestureDetector(
            onLongPress: () => _showMessageActions(context, message, isMe),
            child: bubble,
          ),
        if (hasReactions)
          Padding(
            padding: EdgeInsets.only(
              left: isMe ? 60 : ((_conversation?.isGroup ?? false) ? 0 : 12),
              right: isMe ? 12 : 60,
              bottom: 4,
            ),
            child: Align(
              alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 4,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: _groupReactions(reactions!).entries.map((e) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Text(
                        '${e.key} ${e.value}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
      ],
    );

    return Dismissible(
      key: Key(message['id']?.toString() ?? index.toString()),
      direction: DismissDirection.startToEnd,
      confirmDismiss: (direction) async {
        _setReplyMessage(message);
        return false;
      },
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        child: const Icon(Icons.reply_rounded, color: Color(0xFF2ABFBF), size: 28),
      ),
      child: content,
    );
  }

  @override
  void dispose() {
    ChatDetailScreen.currentOpenConversationId = null;
    _typingTimer?.cancel();
    _typingDotsTimer?.cancel();
    _typingDotsPhase.dispose();
    _textController.removeListener(_onTextChanged);
    _webSocket?.close();
    _webSocket = null;
    for (final c in _chewieControllers.values) {
      c.dispose();
    }
    for (final c in _videoControllers.values) {
      c.dispose();
    }
    _videoControllers.clear();
    _chewieControllers.clear();
    _pollingTimer?.cancel();
    _audioPlayer?.dispose();
    _audioPlayer = null;
    _playingAudioIdNotifier.dispose();
    _audioDurationNotifier.dispose();
    _audioPositionNotifier.dispose();
    _messageFocusNode.dispose();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _conversationId == null || _conversationId!.isEmpty) return;
    _typingTimer?.cancel();
    if (_isTyping) {
      _isTyping = false;
      _sendTypingIndicator(false);
    }
    final savedText = text;

    if (_editingMessageId != null) {
      try {
        await ApiService().patch(
          '/chat/messages/$_editingMessageId/',
          body: {'content': savedText},
        );
        setState(() {
          final idx = _messages.indexWhere((m) => m['id']?.toString() == _editingMessageId);
          if (idx >= 0) {
            _messages[idx] = {..._messages[idx], 'content': savedText};
          }
          _editingMessageId = null;
          _replyToMessage = null;
          _textController.clear();
        });
      } catch (e) {
        debugPrint('Error editing message: $e');
      }
      return;
    }

    _textController.clear();
    setState(() {});
    try {
      debugPrint('=== SENDING MESSAGE to $_conversationId: $savedText ===');
      final body = <String, dynamic>{
        'message_type': 'text',
      };
      if (_replyToMessage != null) {
        body['reply_to_id'] = _replyToMessage!['id']?.toString() ?? '';
      }

      final otherUser = _getOtherUserId();
      if (otherUser != null) {
        try {
          final combinedPayload = await _sessionManager.encryptMessage(otherUser, savedText);
          body['content_encrypted'] = base64Encode(combinedPayload);
          debugPrint('[E2E] Message encrypted for user $otherUser (${combinedPayload.length} bytes)');
        } catch (e) {
          // MAI inviare in plaintext — mostra errore all'utente
          debugPrint('[E2E] Encryption failed: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Impossibile cifrare il messaggio. Riprova o riavvia la chat.'),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 4),
              ),
            );
          }
          return; // BLOCCA l'invio
        }
      } else if (_conversation != null && _conversation!.isGroup) {
        // E2E fan-out: cifra per ogni partecipante del gruppo
        final recipientsEncrypted = <String, String>{};
        bool encryptionFailed = false;

        for (final participant in _conversation!.participants) {
          if (participant.userId == _effectiveCurrentUserId) continue;
          try {
            final encrypted = await _sessionManager.encryptMessage(
              participant.userId,
              savedText,
            );
            recipientsEncrypted[participant.userId.toString()] = base64Encode(encrypted);
          } catch (e) {
            debugPrint('[E2E-GROUP] Failed to encrypt for user ${participant.userId}: $e');
            encryptionFailed = true;
            break;
          }
        }

        if (encryptionFailed || recipientsEncrypted.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Impossibile cifrare il messaggio per tutti i partecipanti.'),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 4),
              ),
            );
          }
          return;
        }

        body['recipients_encrypted'] = recipientsEncrypted;
        // Invia anche content_encrypted con il primo payload per compatibilità
        body['content_encrypted'] = recipientsEncrypted.values.first;
      } else {
        body['content'] = savedText;
      }

      final response = await ApiService().post(
        '/chat/conversations/$_conversationId/messages/',
        body: body,
      );
      debugPrint('=== SEND RESPONSE: $response ===');
      if (response != null && response is Map<String, dynamic>) {
        final messageId = response['id']?.toString();
        if (messageId != null && body.containsKey('content_encrypted')) {
          await _sessionManager.cacheSentMessage(messageId, savedText);
          response['content'] = savedText;
        }
        setState(() {
          _messages.insert(0, Map<String, dynamic>.from(response));
          _replyToMessage = null;
          _editingMessageId = null;
        });
        _scrollToBottom();
        SoundService().playMessageSent();
      }
    } catch (e) {
      debugPrint('=== ERROR SENDING: $e ===');
      _textController.text = savedText;
      setState(() {});
    }
  }

  void _showAttachmentBottomSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE0E0E0),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Allega', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF1A2B4A))),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _attachGridItem(icon: Icons.camera_alt_rounded, color: const Color(0xFF2ABFBF), label: 'Fotocamera', onTap: () { Navigator.pop(context); _pickImage(ImageSource.camera); }),
                      _attachGridItem(icon: Icons.photo_library_rounded, color: const Color(0xFF4CAF50), label: 'Galleria', onTap: () { Navigator.pop(context); _pickImage(ImageSource.gallery); }),
                      _attachGridItem(icon: Icons.videocam_rounded, color: const Color(0xFFE91E63), label: 'Video', onTap: () { Navigator.pop(context); _pickVideo(); }),
                      _attachGridItem(icon: Icons.insert_drive_file_rounded, color: const Color(0xFFFF9800), label: 'Documento', onTap: () { Navigator.pop(context); _pickFile(); }),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _attachGridItem(icon: Icons.mic_rounded, color: const Color(0xFF9C27B0), label: 'Audio', onTap: () { Navigator.pop(context); _showAudioRecorder(); }),
                      _attachGridItem(icon: Icons.location_on_rounded, color: const Color(0xFFF44336), label: 'Posizione', onTap: () { Navigator.pop(context); _sendLocation(); }),
                      _attachGridItem(icon: Icons.person_rounded, color: const Color(0xFF3A6AB0), label: 'Contatto', onTap: () { Navigator.pop(context); _shareContact(); }),
                      const SizedBox(width: 56),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showAudioRecorder() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: false,
      builder: (context) => _AudioRecorderSheet(
        onSend: (String filePath) async {
          await _uploadAndSendFile(File(filePath), 'voice');
        },
        onRecordingStarted: () {
          setState(() => _isRecordingAudio = true);
          _sendRecordingIndicator(true);
        },
        onRecordingStopped: () {
          setState(() => _isRecordingAudio = false);
          _sendRecordingIndicator(false);
        },
      ),
    ).then((_) {
      setState(() => _isRecordingAudio = false);
      _sendRecordingIndicator(false);
    });
  }

  Future<void> _sendLocation() async {
    if (_conversationId == null || _conversationId!.isEmpty) return;
    final otherUser = _getOtherUserId();
    final isGroup = _conversation != null && _conversation!.isGroup;
    if (otherUser == null && !isGroup) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Posizione non disponibile'), backgroundColor: Color(0xFF2ABFBF)),
        );
      }
      return;
    }
    try {
      final permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Permesso posizione negato'), backgroundColor: Colors.orange),
          );
        }
        return;
      }
      final position = await Geolocator.getCurrentPosition();
      final payload = jsonEncode({
        'type': 'location',
        'lat': position.latitude,
        'lng': position.longitude,
        'address': '',
      });
      final body = <String, dynamic>{
        'message_type': 'location',
        'content': '',
      };

      if (isGroup) {
        body['content'] = payload;
      } else {
        final encrypted = await _sessionManager.encryptMessage(otherUser!, payload);
        body['content_encrypted'] = base64Encode(encrypted);
      }

      if (_replyToMessage != null) {
        body['reply_to_id'] = _replyToMessage!['id']?.toString() ?? '';
      }
      final response = await ApiService().post(
        '/chat/conversations/$_conversationId/messages/',
        body: body,
      );
      if (response != null && response is Map<String, dynamic>) {
        final messageId = response['id']?.toString();
        final messageMap = Map<String, dynamic>.from(response);
        if (messageId != null) {
          await _sessionManager.cacheSentMessage(messageId, payload);
          messageMap['content'] = payload;
        }
        if (mounted) {
          setState(() {
            _messages.insert(0, messageMap);
            _replyToMessage = null;
          });
          _scrollToBottom();
          SoundService().playMessageSent();
        }
      }
    } catch (e) {
      debugPrint('Send location error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore invio posizione: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // TODO: Su device reale usare MethodChannel 'com.securechat/contacts'
  void _shareContact() {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final emailController = TextEditingController();

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2ABFBF).withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.person, color: Color(0xFF2ABFBF), size: 24),
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      'Condividi contatto',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    labelText: 'Nome *',
                    prefixIcon: const Icon(Icons.person_outline),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF2ABFBF), width: 2),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: 'Telefono',
                    prefixIcon: const Icon(Icons.phone_outlined),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF2ABFBF), width: 2),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: 'Email',
                    prefixIcon: const Icon(Icons.email_outlined),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF2ABFBF), width: 2),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2ABFBF),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    icon: const Icon(Icons.send_rounded),
                    label: const Text('Invia contatto', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    onPressed: () async {
                      final name = nameController.text.trim();
                      if (name.isEmpty) return;
                      Navigator.pop(ctx);
                      await _sendContactMessage(
                        name: name,
                        phone: phoneController.text.trim(),
                        email: emailController.text.trim(),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _sendContactMessage({required String name, String phone = '', String email = ''}) async {
    final convId = _conversationId;
    final otherUserId = _getOtherUserId();
    final isGroup = _conversation != null && _conversation!.isGroup;
    if (convId == null || convId.isEmpty || (otherUserId == null && !isGroup)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Contatto non disponibile'), backgroundColor: Color(0xFF2ABFBF)),
        );
      }
      return;
    }

    final payload = jsonEncode({'type': 'contact', 'name': name, 'phone': phone, 'email': email});

    try {
      final body = <String, dynamic>{
        'message_type': 'contact',
        'content': '',
      };

      if (isGroup) {
        body['content'] = payload;
      } else {
        final encrypted = await _sessionManager.encryptMessage(otherUserId!, payload);
        body['content_encrypted'] = base64Encode(encrypted);
      }

      if (_replyToMessage != null) {
        body['reply_to_id'] = _replyToMessage!['id']?.toString() ?? '';
      }

      final response = await ApiService().post(
        '/chat/conversations/$convId/messages/',
        body: body,
      );

      if (response == null || response is! Map<String, dynamic>) return;

      final messageId = response['id']?.toString();
      final messageMap = Map<String, dynamic>.from(response);
      if (messageId != null) {
        await _sessionManager.cacheSentMessage(messageId, payload);
        messageMap['content'] = payload;
      }

      if (mounted) {
        setState(() {
          _messages.insert(0, messageMap);
          _replyToMessage = null;
        });
        _scrollToBottom();
        SoundService().playMessageSent();
        _saveHomePreview(_messages);
      }
    } catch (e) {
      debugPrint('Share contact error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore invio contatto: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _attachGridItem({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Color(0xFF6B7280),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final xfile = await _imagePicker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      if (xfile != null && mounted) {
        await _uploadAndSendFile(File(xfile.path), 'image');
      }
    } catch (e) {
      debugPrint('Errore selezione immagine: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _pickVideo() async {
    try {
      final xfile = await _imagePicker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 5),
      );
      if (xfile != null && mounted) {
        await _uploadAndSendFile(File(xfile.path), 'video');
      }
    } catch (e) {
      debugPrint('Errore selezione video: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore video: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );
      if (result != null && result.files.single.path != null && mounted) {
        await _uploadAndSendFile(File(result.files.single.path!), 'file');
      }
    } catch (e) {
      debugPrint('Errore selezione documento: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Estensione da mime_type per file temp (es. video/mp4 → .mp4).
  String _extensionFromMimeType(String? mimeType) {
    if (mimeType == null || mimeType.isEmpty) return '';
    switch (mimeType.toLowerCase()) {
      case 'video/mp4':
        return '.mp4';
      case 'video/quicktime':
        return '.mov';
      case 'image/jpeg':
      case 'image/jpg':
        return '.jpg';
      case 'image/png':
        return '.png';
      case 'image/gif':
        return '.gif';
      case 'image/webp':
        return '.webp';
      case 'image/heic':
        return '.heic';
      case 'audio/mpeg':
      case 'audio/mp3':
        return '.mp3';
      case 'audio/mp4':
      case 'audio/x-m4a':
        return '.m4a';
      case 'audio/wav':
        return '.wav';
      case 'audio/ogg':
        return '.ogg';
      default:
        return '';
    }
  }

  String _getMimeTypeForFile(String fileName, String messageType) {
    final ext = fileName.split('.').last.toLowerCase();
    if (['jpg', 'jpeg'].contains(ext)) return 'image/jpeg';
    if (ext == 'png') return 'image/png';
    if (ext == 'gif') return 'image/gif';
    if (ext == 'webp') return 'image/webp';
    if (ext == 'heic') return 'image/heic';
    if (ext == 'mp4') return 'video/mp4';
    if (ext == 'mov') return 'video/quicktime';
    if (ext == 'avi') return 'video/x-msvideo';
    if (ext == 'ogg' || ext == 'ogv') return messageType == 'video' ? 'video/ogg' : 'audio/ogg';
    if (ext == 'mp3') return 'audio/mpeg';
    if (ext == 'wav' || ext == 'wave') return 'audio/wav';
    if (ext == 'pdf') return 'application/pdf';
    if (ext == 'doc') return 'application/msword';
    if (ext == 'docx') return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    return 'application/octet-stream';
  }

  Future<String> _uploadEncryptedBlob({
    required Uint8List encryptedBytes,
    required String encryptedFileKeyB64,
    required String encryptedMetadataB64,
    required String fileHash,
    required String conversationId,
    required String fileName,
    required int plainFileSize,
  }) async {
    await AuthService().refreshAccessTokenIfNeeded();
    final token = ApiService().accessToken;
    if (token == null) throw Exception('Non autenticato');
    final uri = Uri.parse('${AppConstants.baseUrl}/chat/media/upload/');
    final request = http.MultipartRequest('POST', uri);
    request.headers['Authorization'] = 'Bearer $token';
    request.files.add(http.MultipartFile.fromBytes(
      'encrypted_file',
      encryptedBytes,
      filename: 'encrypted_$fileName',
    ));
    request.fields['conversation_id'] = conversationId;
    request.fields['encrypted_file_key'] = encryptedFileKeyB64;
    request.fields['encrypted_metadata'] = encryptedMetadataB64;
    request.fields['file_hash'] = fileHash;
    request.fields['encrypted_file_size'] = plainFileSize.toString();
    final streamedResponse = await request.send();
    final responseBody = await streamedResponse.stream.bytesToString();
    if (streamedResponse.statusCode != 201) {
      throw Exception('Upload failed: ${streamedResponse.statusCode} — $responseBody');
    }
    final data = jsonDecode(responseBody) as Map<String, dynamic>;
    return data['attachment_id'] as String;
  }

  Future<void> _uploadAndSendFile(File file, String messageType) async {
    if (_conversationId == null || _conversationId!.isEmpty) return;
    final otherUserId = _getOtherUserId();
    final isGroup = _conversation != null && _conversation!.isGroup;

    if (otherUserId == null && !isGroup) {
      await _uploadAndSendFileLegacy(file, messageType);
      return;
    }
    setState(() => _isUploading = true);
    try {
      await AuthService().refreshAccessTokenIfNeeded();
      final fileBytes = await file.readAsBytes();
      final fileName = file.path.split(RegExp(r'[/\\]')).last;
      final mimeType = _getMimeTypeForFile(fileName, messageType);
      final fileKey = await MediaEncryptionService.generateFileKey();
      final fileKeyBytes = await fileKey.extractBytes();
      final fileKeyB64 = base64Encode(Uint8List.fromList(fileKeyBytes));
      final encryptedBytes = await MediaEncryptionService.encryptFile(fileBytes, fileKey);
      final fileHash = await MediaEncryptionService.computeFileHash(fileBytes);
      final metadata = <String, dynamic>{
        'file_name': fileName,
        'mime_type': mimeType,
        'file_size': fileBytes.length,
        'encrypted_size': encryptedBytes.length,
      };
      final encryptedMetadataB64 = await MediaEncryptionService.encryptMetadata(metadata, fileKey);
      // Single ratchet step: file key + caption in one encrypted payload (backend needs a placeholder key).
      final attachmentPayload = jsonEncode({
        'type': 'attachment',
        'file_key_b64': fileKeyB64,
        'caption': fileName,
      });
      Map<String, String>? recipientsEncrypted;
      Uint8List? encryptedPayload;

      if (isGroup) {
        // Fan-out: cifra il payload (file_key + caption) per ogni partecipante
        recipientsEncrypted = {};
        for (final participant in _conversation!.participants) {
          if (participant.userId == _effectiveCurrentUserId) continue;
          try {
            final encrypted = await _sessionManager.encryptMessage(
              participant.userId,
              attachmentPayload,
            );
            recipientsEncrypted[participant.userId.toString()] = base64Encode(encrypted);
          } catch (e) {
            debugPrint('[E2E-GROUP] Failed to encrypt attachment for user ${participant.userId}: $e');
            throw Exception('Cifratura allegato fallita per utente ${participant.userId}');
          }
        }
      } else {
        encryptedPayload = await _sessionManager.encryptMessage(otherUserId!, attachmentPayload);
      }

      final attachmentId = await _uploadEncryptedBlob(
        encryptedBytes: encryptedBytes,
        encryptedFileKeyB64: 'e2e-inline',
        encryptedMetadataB64: encryptedMetadataB64,
        fileHash: fileHash,
        conversationId: _conversationId!,
        fileName: fileName,
        plainFileSize: fileBytes.length,
      );
      _attachmentKeyCache[attachmentId] = fileKeyB64;
      _attachmentCaptionCache[attachmentId] = fileName;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('scp_att_key_$attachmentId', fileKeyB64);
      await prefs.setString('scp_att_caption_$attachmentId', fileName);
      final contentEncryptedB64 = isGroup
          ? (recipientsEncrypted!.values.isNotEmpty ? recipientsEncrypted.values.first : '')
          : base64Encode(encryptedPayload!);
      await AuthService().refreshAccessTokenIfNeeded();
      final token = ApiService().accessToken;
      if (token == null) throw Exception('Non autenticato');
      final attachmentIds = [attachmentId];
      final msgBody = <String, dynamic>{
        'content': '',
        'content_encrypted': contentEncryptedB64,
        'message_type': messageType,
        'attachment_ids': attachmentIds,
      };
      if (isGroup && recipientsEncrypted != null) {
        msgBody['recipients_encrypted'] = recipientsEncrypted;
      }
      if (_replyToMessage != null) {
        msgBody['reply_to_id'] = _replyToMessage!['id']?.toString() ?? '';
      }
      final msgResponse = await http.post(
        Uri.parse('${AppConstants.baseUrl}/chat/conversations/$_conversationId/messages/'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(msgBody),
      );
      if (msgResponse.statusCode != 200 && msgResponse.statusCode != 201) {
        throw Exception('Errore creazione messaggio: ${msgResponse.statusCode}');
      }
      final responseBody = msgResponse.body;
      final response = jsonDecode(responseBody) as Map<String, dynamic>;
      final newMessageId = response['id']?.toString();
      if (newMessageId != null) {
        await _sessionManager.cacheSentMessage(newMessageId, fileName);
      }
      debugPrint('[ATTACH] response body: $responseBody');
      debugPrint('[ATTACH] attachments in response: ${response['attachments']}');
      debugPrint('[ATTACH] attachment_ids sent: $attachmentIds');
      SoundService().playMessageSent();
      if (mounted) {
        setState(() => _replyToMessage = null);
        await _forceReloadMessages();
      }
    } catch (e) {
      // MAI inviare in plaintext/legacy — blocca invio allegato
      debugPrint('[E2E] Upload cifrato fallito: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Impossibile cifrare l\'allegato. Riprova o riavvia la chat.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<void> _uploadAndSendFileLegacy(File file, String messageType) async {
    if (_conversationId == null || _conversationId!.isEmpty) return;

    setState(() => _isUploading = true);

    try {
      final token = ApiService().accessToken;
      if (token == null) throw Exception('Non autenticato');

      final fileName = file.path.split(RegExp(r'[/\\]')).last;
      final mimeType = _getMimeTypeForFile(fileName, messageType);

      final msgBody = <String, dynamic>{
        'content': fileName,
        'message_type': messageType,
      };
      if (_replyToMessage != null) {
        msgBody['reply_to_id'] = _replyToMessage!['id']?.toString() ?? '';
      }

      final msgResponse = await http.post(
        Uri.parse('${AppConstants.baseUrl}/chat/conversations/$_conversationId/messages/'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(msgBody),
      );

      if (msgResponse.statusCode != 200 && msgResponse.statusCode != 201) {
        throw Exception('Errore creazione messaggio: ${msgResponse.statusCode}');
      }

      final newMsg = jsonDecode(msgResponse.body) as Map<String, dynamic>;
      final messageId = newMsg['id']?.toString();

      if (!mounted) return;
      setState(() {
        _messages.insert(0, newMsg);
        _replyToMessage = null;
      });
      _scrollToBottom();

      final mimeParts = mimeType.split('/');
      final uploadRequest = http.MultipartRequest(
        'POST',
        Uri.parse('${AppConstants.baseUrl}/chat/upload/'),
      );
      uploadRequest.headers['Authorization'] = 'Bearer $token';
      uploadRequest.fields['message_id'] = messageId ?? '';
      uploadRequest.fields['type'] = messageType;
      uploadRequest.files.add(
        await http.MultipartFile.fromPath(
          'file',
          file.path,
          filename: fileName,
          contentType: MediaType(mimeParts[0], mimeParts[1]),
        ),
      );

      final uploadResponse = await uploadRequest.send();
      final uploadBody = await uploadResponse.stream.bytesToString();

      if (uploadResponse.statusCode == 200 || uploadResponse.statusCode == 201) {
        // Notifica i partecipanti via WS che l'allegato è pronto
        _webSocket?.add(jsonEncode({
          'action': 'attachment_ready',
          'message_id': messageId ?? '',
          'conversation_id': _conversationId ?? '',
        }));
        SoundService().playMessageSent();
        await Future.delayed(const Duration(milliseconds: 300));
        await _forceReloadMessages();
      } else {
        debugPrint('Upload fallito: ${uploadResponse.statusCode} - $uploadBody');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('File inviato ma upload allegato fallito: ${uploadResponse.statusCode}'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Errore upload: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Errore: ${e.toString().length > 80 ? e.toString().substring(0, 80) : e.toString()}',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Widget _buildGroupAvatarAppBar() {
    final groupName = _displayName;
    final groupAvatar = _conversation != null && _conversation!.groupAvatars.isNotEmpty
        ? _conversation!.groupAvatars.first
        : null;
    final participantCount = _conversation?.participants.length ?? 0;

    final parts = groupName.trim().split(RegExp(r'\s+'));
    String initials;
    if (parts.length >= 2) {
      initials = '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    } else if (groupName.length >= 2) {
      initials = groupName.substring(0, 2).toUpperCase();
    } else {
      initials = groupName.toUpperCase();
    }

    return CustomPaint(
      painter: _SegmentedBorderPainter(
        segmentCount: participantCount,
        strokeWidth: 2.0,
      ),
      child: Container(
        width: 40,
        height: 40,
        padding: const EdgeInsets.all(2.5),
        child: ClipOval(
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: groupAvatar == null
                  ? const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFFB0E0D4), // teal200
                        Color(0xFF8DD4C6), // teal300
                        Color(0xFF6EC8B8), // teal400
                      ],
                    )
                  : null,
              image: groupAvatar != null
                  ? DecorationImage(
                      image: NetworkImage(groupAvatar),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            child: groupAvatar == null
                ? Center(
                    child: Text(
                      initials,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('[APPBAR] isGroup=${_conversation?.isGroup}, convType=${_conversation?.convType}, conversationId=$_conversationId');
    return Scaffold(
      backgroundColor: _bodyBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        scrolledUnderElevation: 0.5,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.blue700),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: GestureDetector(
          onTap: _conversation != null && _conversation!.isGroup
              ? () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => GroupInfoScreen(
                        conversationId: _conversationId ?? '',
                        onGroupUpdated: () {
                          _loadConversationAndMessages();
                        },
                      ),
                    ),
                  ).then((_) => _loadConversationAndMessages());
                }
              : null,
          child: Row(
            children: [
              _conversation != null && _conversation!.isGroup
                  ? _buildGroupAvatarAppBar()
                  : UserAvatarWidget(
                      avatarUrl: _otherAvatarUrl,
                      displayName: _displayName,
                      size: 40,
                    ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _displayName,
                      style: const TextStyle(
                        color: _navy,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _getStatusText(_isOtherOnline),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: _getStatusColor(_isOtherOnline),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Chiamata audio: coming soon')),
              );
            },
            icon: const Icon(Icons.phone_rounded, size: 22),
            color: _teal,
          ),
          IconButton(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Videochiamata: coming soon')),
              );
            },
            icon: const Icon(Icons.videocam_rounded, size: 24),
            color: _teal,
          ),
          IconButton(
            icon: const Icon(Icons.more_vert, color: _teal),
            onPressed: () => _showChatActions(),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: _teal, strokeWidth: 2.5),
                  )
                : _messages.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.chat_bubble_outline,
                              size: 60,
                              color: _statusGray.withValues(alpha: 0.5),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Inizia la conversazione!',
                              style: TextStyle(
                                fontSize: 16,
                                color: _statusGray,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        reverse: true,
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          return _buildMessageItem(context, _messages[index], index);
                        },
                      ),
          ),
          if (_isUploading)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF2ABFBF),
                    ),
                  ),
                  SizedBox(width: 8),
                  Text('Invio in corso...', style: TextStyle(color: Color(0xFF9E9E9E), fontSize: 13)),
                ],
              ),
            ),
          if (_replyToMessage != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: const BoxDecoration(
                color: Color(0xFFF5F8FA),
                border: Border(
                  top: BorderSide(color: Color(0xFFE0E0E0), width: 0.5),
                  left: BorderSide(color: Color(0xFF2ABFBF), width: 3),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.reply, color: Color(0xFF2ABFBF), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${_replyToMessage!['sender']?['first_name'] ?? ''} ${_replyToMessage!['sender']?['last_name'] ?? ''}'.trim(),
                          style: const TextStyle(
                            color: Color(0xFF2ABFBF),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _replyToMessage!['content']?.toString() ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Color(0xFF9E9E9E), fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18, color: Color(0xFF9E9E9E)),
                    onPressed: () => setState(() => _replyToMessage = null),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  ),
                ],
              ),
            ),
          if (_otherUserIsTyping || _otherUserIsRecording)
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: const Color(0xFFE0E0E0),
                    backgroundImage: _otherUserAvatarUrl != null
                        ? NetworkImage(_otherUserAvatarUrl!)
                        : null,
                    child: _otherUserAvatarUrl == null
                        ? const Icon(Icons.person, size: 16, color: Color(0xFF9E9E9E))
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_otherUserIsRecording)
                          Icon(Icons.mic, size: 14, color: Colors.grey[600]),
                        if (!_otherUserIsRecording) _buildTypingDots(),
                        const SizedBox(width: 4),
                        Text(
                          _otherUserIsRecording ? 'Sta registrando...' : 'Sta scrivendo...',
                          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(8),
                topRight: Radius.circular(8),
              ),
              boxShadow: [
                BoxShadow(
                  color: Color(0x10000000),
                  blurRadius: 6,
                  offset: Offset(0, -1),
                ),
              ],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: SafeArea(
              top: false,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: IconButton(
                        onPressed: _showAttachmentBottomSheet,
                        icon: const Icon(Icons.attach_file_rounded, color: Color(0xFF2ABFBF), size: 26),
                        color: AppColors.blue700,
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 44),
                      decoration: BoxDecoration(
                        color: _inputBg,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: TextField(
                        controller: _textController,
                        focusNode: _messageFocusNode,
                        maxLines: 4,
                        minLines: 1,
                        decoration: const InputDecoration(
                          hintText: 'Scrivi un messaggio...',
                          hintStyle: TextStyle(color: Color(0xFF9E9E9E), fontSize: 15),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          isDense: true,
                        ),
                        style: const TextStyle(fontSize: 15),
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _textController,
                      builder: (context, value, _) {
                        final hasText = value.text.trim().isNotEmpty;
                        return SizedBox(
                          width: 44,
                          height: 44,
                          child: Container(
                            decoration: const BoxDecoration(
                              color: _teal,
                              shape: BoxShape.circle,
                            ),
                            child: IconButton(
                              onPressed: hasText ? _sendMessage : _showAudioRecorder,
                              icon: Icon(
                                hasText ? Icons.send_rounded : Icons.mic_rounded,
                                size: 22,
                                color: Colors.white,
                              ),
                              padding: EdgeInsets.zero,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AttachmentOption extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color bgColor;
  final Color iconColor;
  final VoidCallback onTap;

  const _AttachmentOption({
    required this.label,
    required this.icon,
    required this.bgColor,
    required this.iconColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: bgColor,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: iconColor, size: 28),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF1A2B4A),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ForwardSheet extends StatefulWidget {
  final Map<String, dynamic> message;
  final int? currentUserId;
  final Future<void> Function(List<int> userIds) onForwardToUsers;
  final Future<void> Function() onShareExternal;

  const _ForwardSheet({
    required this.message,
    required this.currentUserId,
    required this.onForwardToUsers,
    required this.onShareExternal,
  });

  @override
  State<_ForwardSheet> createState() => _ForwardSheetState();
}

class _ForwardSheetState extends State<_ForwardSheet> {
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _filteredUsers = [];
  final Set<int> _selectedIds = {};
  bool _loading = true;
  final _searchController = TextEditingController();
  Timer? _debounce;

  static const Color _teal = Color(0xFF2ABFBF);
  static const Color _navy = Color(0xFF1A2B4A);
  static const Color _subtitleGray = Color(0xFF9E9E9E);

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    try {
      final response = await ApiService().get('/auth/users/search/?q=');
      final users = response is List ? response : (response['results'] ?? response['users'] ?? []);
      final List<Map<String, dynamic>> contacts = [];
      for (final u in users) {
        final userMap = u is Map<String, dynamic> ? u : Map<String, dynamic>.from(u as Map);
        final userId = userMap['id'];
        final id = userId is int ? userId : int.tryParse(userId?.toString() ?? '0');
        if (id == null || id == 0 || id == widget.currentUserId) continue;
        final firstName = userMap['first_name']?.toString() ?? '';
        final lastName = userMap['last_name']?.toString() ?? '';
        contacts.add({
          'id': id,
          'display_name': '$firstName $lastName'.trim(),
          'email': userMap['email']?.toString() ?? '',
          'username': userMap['username'] ?? '',
          'avatar': userMap['profile_picture'] ?? userMap['avatar'] ?? userMap['avatar_url'],
        });
      }
      contacts.sort((a, b) {
        final na = (a['display_name'] ?? a['email'] ?? '').toString().toLowerCase();
        final nb = (b['display_name'] ?? b['email'] ?? '').toString().toLowerCase();
        return na.compareTo(nb);
      });
      if (mounted) {
        setState(() {
          _users = contacts;
          _filteredUsers = contacts;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('Errore caricamento utenti per inoltro: $e');
      if (mounted) setState(() { _users = []; _filteredUsers = []; _loading = false; });
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      final q = value.trim().toLowerCase();
      setState(() {
        if (q.isEmpty) {
          _filteredUsers = List.from(_users);
        } else {
          _filteredUsers = _users.where((c) {
            final name = (c['display_name'] ?? '').toString().toLowerCase();
            final email = (c['email'] ?? '').toString().toLowerCase();
            return name.contains(q) || email.contains(q);
          }).toList();
        }
      });
    });
  }

  String _initials(Map<String, dynamic> u) {
    final name = (u['display_name'] ?? u['username'] ?? '').toString().trim();
    final parts = name.split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  Map<String, List<Map<String, dynamic>>> _groupByLetter(List<Map<String, dynamic>> users) {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final u in users) {
      final name = (u['display_name'] ?? '').toString().trim();
      final letter = name.isEmpty ? '?' : name[0].toUpperCase();
      map.putIfAbsent(letter, () => []).add(u);
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.message['content']?.toString() ?? '';
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.8,
      padding: EdgeInsets.only(bottom: bottomPadding),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 40, height: 4,
            decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.shortcut_rounded, color: _teal, size: 24),
                const SizedBox(width: 10),
                const Text('Inoltra messaggio', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _navy)),
                const Spacer(),
                if (_selectedIds.isNotEmpty)
                  GestureDetector(
                    onTap: () async {
                      Navigator.pop(context);
                      await widget.onForwardToUsers(_selectedIds.toList());
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: _teal,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'Invia (${_selectedIds.length})',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Preview messaggio
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F8FA),
              borderRadius: BorderRadius.circular(10),
              border: const Border(left: BorderSide(color: _teal, width: 3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.format_quote_rounded, color: _teal, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(preview, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: _navy.withValues(alpha: 0.7), fontSize: 13))),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Condividi fuori app
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GestureDetector(
              onTap: () async { Navigator.pop(context); await widget.onShareExternal(); },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                decoration: BoxDecoration(color: const Color(0xFFF5F8FA), borderRadius: BorderRadius.circular(12)),
                child: Row(
                  children: [
                    Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(color: _teal.withValues(alpha: 0.1), shape: BoxShape.circle),
                      child: const Icon(Icons.ios_share_rounded, color: _teal, size: 20),
                    ),
                    const SizedBox(width: 12),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Condividi fuori app', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: _navy)),
                        Text('WhatsApp, Telegram, Mail...', style: TextStyle(fontSize: 12, color: _subtitleGray)),
                      ],
                    ),
                    const Spacer(),
                    const Icon(Icons.chevron_right_rounded, color: _subtitleGray),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Ricerca
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(12)),
              child: TextField(
                controller: _searchController,
                onChanged: _onSearchChanged,
                decoration: const InputDecoration(
                  hintText: 'Cerca per nome o email...',
                  hintStyle: TextStyle(color: _subtitleGray, fontSize: 15),
                  prefixIcon: Icon(Icons.search, color: _subtitleGray, size: 22),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Chip selezionati
          if (_selectedIds.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: _users.where((u) => _selectedIds.contains(u['id'])).map((u) {
                  final avatar = u['avatar']?.toString();
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Chip(
                      avatar: CircleAvatar(
                        backgroundColor: _teal,
                        backgroundImage: avatar != null && avatar.isNotEmpty ? NetworkImage(avatar) : null,
                        child: avatar == null || avatar.isEmpty
                            ? Text(_initials(u), style: const TextStyle(color: Colors.white, fontSize: 11))
                            : null,
                      ),
                      label: Text(
                        (u['display_name'] ?? u['username'] ?? '').toString(),
                        style: const TextStyle(fontSize: 13),
                      ),
                      onDeleted: () => setState(() => _selectedIds.remove(u['id'])),
                      deleteIconColor: _teal,
                    ),
                  );
                }).toList(),
              ),
            ),
          // Lista utenti raggruppata per lettera
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: _teal, strokeWidth: 2.5))
                : _filteredUsers.isEmpty
                    ? const Center(child: Text('Nessun utente trovato', style: TextStyle(color: _subtitleGray)))
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
      itemCount: letters.fold<int>(0, (sum, l) => sum + 1 + (grouped[l]!.length)),
      itemBuilder: (context, index) {
        int offset = 0;
        for (final letter in letters) {
          final list = grouped[letter]!;
          if (index == offset) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(letter, style: const TextStyle(color: _teal, fontSize: 16, fontWeight: FontWeight.bold)),
            );
          }
          offset++;
          final idx = index - offset;
          if (idx < list.length) {
            final u = list[idx];
            final id = u['id'] as int;
            final isSelected = _selectedIds.contains(id);
            final avatar = u['avatar']?.toString();
            return Column(
              children: [
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: CircleAvatar(
                    backgroundColor: _teal,
                    backgroundImage: avatar != null && avatar.isNotEmpty ? NetworkImage(avatar) : null,
                    child: avatar == null || avatar.isEmpty
                        ? Text(_initials(u), style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700))
                        : null,
                  ),
                  title: Text(
                    (u['display_name'] ?? u['username'] ?? '').toString(),
                    style: const TextStyle(color: _navy, fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                  subtitle: Text(u['email']?.toString() ?? '', style: const TextStyle(color: _subtitleGray, fontSize: 13)),
                  trailing: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 26, height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isSelected ? _teal : Colors.transparent,
                      border: Border.all(color: isSelected ? _teal : const Color(0xFFDDDDDD), width: 2),
                    ),
                    child: isSelected ? const Icon(Icons.check_rounded, color: Colors.white, size: 16) : null,
                  ),
                  onTap: () {
                    setState(() {
                      if (isSelected) _selectedIds.remove(id);
                      else _selectedIds.add(id);
                    });
                  },
                ),
                const Divider(height: 1, thickness: 0.5, indent: 72, endIndent: 16, color: Color(0xFFEEEEEE)),
              ],
            );
          }
          offset += list.length;
        }
        return const SizedBox.shrink();
      },
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }
}

class _VideoPlayerScreen extends StatefulWidget {
  const _VideoPlayerScreen({required this.videoUrl, required this.token, this.localFile});
  final String videoUrl;
  final String token;
  final File? localFile;

  @override
  State<_VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<_VideoPlayerScreen> {
  late VideoPlayerController _videoController;
  ChewieController? _chewieController;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  Future<void> _initVideo() async {
    _videoController = widget.localFile != null
        ? VideoPlayerController.file(widget.localFile!)
        : VideoPlayerController.networkUrl(
            Uri.parse(widget.videoUrl),
            httpHeaders: widget.token.isNotEmpty ? {'Authorization': 'Bearer ${widget.token}'} : <String, String>{},
          );
    try {
      await _videoController.initialize();
      _chewieController = ChewieController(
        videoPlayerController: _videoController,
        autoPlay: true,
        looping: false,
        aspectRatio: _videoController.value.aspectRatio,
        allowFullScreen: true,
        allowMuting: true,
        showControls: true,
        materialProgressColors: ChewieProgressColors(
          playedColor: const Color(0xFF2ABFBF),
          handleColor: const Color(0xFF2ABFBF),
          backgroundColor: Colors.white24,
          bufferedColor: Colors.white38,
        ),
      );
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Errore inizializzazione video: $e');
      if (mounted) setState(() => _hasError = true);
    }
  }

  @override
  void dispose() {
    _chewieController?.dispose();
    _videoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        title: const Text('Video', style: TextStyle(color: Colors.white)),
      ),
      body: Center(
        child: _hasError
            ? const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline, color: Colors.white54, size: 48),
                  SizedBox(height: 12),
                  Text(
                    'Impossibile riprodurre il video',
                    style: TextStyle(color: Colors.white54, fontSize: 16),
                  ),
                ],
              )
            : _chewieController != null
                ? Chewie(controller: _chewieController!)
                : const CircularProgressIndicator(color: Color(0xFF2ABFBF)),
      ),
    );
  }
}

class _AudioRecorderSheet extends StatefulWidget {
  final Future<void> Function(String filePath) onSend;
  final VoidCallback? onRecordingStarted;
  final VoidCallback? onRecordingStopped;

  const _AudioRecorderSheet({
    required this.onSend,
    this.onRecordingStarted,
    this.onRecordingStopped,
  });

  @override
  State<_AudioRecorderSheet> createState() => _AudioRecorderSheetState();
}

class _AudioRecorderSheetState extends State<_AudioRecorderSheet> {
  final _recorder = record.AudioRecorder();
  final _player = ap.AudioPlayer();

  bool _isRecording = false;
  bool _hasRecording = false;
  bool _isPlaying = false;
  String? _filePath;
  Duration _recordDuration = Duration.zero;
  Duration _playPosition = Duration.zero;
  Duration _playDuration = Duration.zero;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _playPosition = p);
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _playDuration = d);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isPlaying = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    try {
      if (await _recorder.hasPermission()) {
        final dir = await getTemporaryDirectory();
        _filePath = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

        await _recorder.start(
          const record.RecordConfig(
            encoder: record.AudioEncoder.aacLc,
            bitRate: 128000,
            sampleRate: 44100,
          ),
          path: _filePath!,
        );

        _recordDuration = Duration.zero;
        _timer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) setState(() => _recordDuration += const Duration(seconds: 1));
        });

        setState(() => _isRecording = true);
        widget.onRecordingStarted?.call();
      }
    } catch (e) {
      debugPrint('Errore registrazione: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _stopRecording() async {
    widget.onRecordingStopped?.call();
    _timer?.cancel();
    final path = await _recorder.stop();
    setState(() {
      _isRecording = false;
      _hasRecording = true;
      if (path != null) _filePath = path;
    });
  }

  Future<void> _playRecording() async {
    if (_filePath == null) return;
    if (_isPlaying) {
      await _player.pause();
      setState(() => _isPlaying = false);
    } else {
      await _player.play(ap.DeviceFileSource(_filePath!));
      setState(() => _isPlaying = true);
    }
  }

  void _deleteRecording() {
    setState(() {
      _hasRecording = false;
      _isPlaying = false;
      _recordDuration = Duration.zero;
      _playPosition = Duration.zero;
    });
    _player.stop();
    if (_filePath != null) {
      try {
        File(_filePath!).deleteSync();
      } catch (_) {}
    }
    _filePath = null;
  }

  Future<void> _sendRecording() async {
    if (_filePath == null) return;
    Navigator.pop(context);
    await widget.onSend(_filePath!);
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: const Color(0xFFE0E0E0), borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 16),
              const Text('Registra audio', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF1A2B4A))),
              const SizedBox(height: 24),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 24),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F8FA),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    Icon(
                      _isRecording ? Icons.mic_rounded : (_hasRecording ? Icons.audiotrack_rounded : Icons.mic_none_rounded),
                      color: _isRecording ? Colors.red : const Color(0xFF2ABFBF),
                      size: 48,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _hasRecording && !_isRecording
                          ? '${_formatDuration(_playPosition)} / ${_formatDuration(_recordDuration)}'
                          : _formatDuration(_recordDuration),
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w300,
                        color: _isRecording ? Colors.red : const Color(0xFF1A2B4A),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (_isRecording)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text('Registrazione in corso...', style: TextStyle(color: Colors.red, fontSize: 13)),
                      ),
                    if (_hasRecording && !_isRecording) ...[
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: _playDuration.inMilliseconds > 0
                                ? (_playPosition.inMilliseconds / _playDuration.inMilliseconds).clamp(0.0, 1.0)
                                : 0.0,
                            backgroundColor: const Color(0xFFE0E0E0),
                            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF2ABFBF)),
                            minHeight: 4,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),
              if (!_hasRecording) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Annulla', style: TextStyle(color: Color(0xFF9E9E9E), fontSize: 15)),
                    ),
                    const SizedBox(width: 24),
                    GestureDetector(
                      onTap: _isRecording ? _stopRecording : _startRecording,
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isRecording ? Colors.red : const Color(0xFF2ABFBF),
                          boxShadow: [
                            BoxShadow(
                              color: (_isRecording ? Colors.red : const Color(0xFF2ABFBF)).withOpacity(0.3),
                              blurRadius: 16,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Icon(
                          _isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                          color: Colors.white,
                          size: 36,
                        ),
                      ),
                    ),
                    const SizedBox(width: 24),
                    const SizedBox(width: 64),
                  ],
                ),
              ] else ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    GestureDetector(
                      onTap: _deleteRecording,
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.red.withOpacity(0.1),
                        ),
                        child: const Icon(Icons.delete_rounded, color: Colors.red, size: 28),
                      ),
                    ),
                    GestureDetector(
                      onTap: _playRecording,
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF2ABFBF).withOpacity(0.1),
                        ),
                        child: Icon(
                          _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          color: const Color(0xFF2ABFBF),
                          size: 36,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: _sendRecording,
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF2ABFBF),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF2ABFBF).withOpacity(0.3),
                              blurRadius: 12,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: const Icon(Icons.send_rounded, color: Colors.white, size: 26),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SegmentedBorderPainter extends CustomPainter {
  final int segmentCount;
  final double strokeWidth;

  static const List<Color> _palette = [
    AppColors.teal500,
    AppColors.blue500,
    AppColors.green600,
    AppColors.navy700,
    AppColors.teal300,
    AppColors.blue300,
    AppColors.green400,
    AppColors.teal700,
    AppColors.blue700,
    AppColors.navy600,
  ];

  _SegmentedBorderPainter({
    required this.segmentCount,
    this.strokeWidth = 2.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (segmentCount <= 0) return;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;
    const double pi = 3.14159265358979;
    const gapAngle = 0.08;
    final totalGap = gapAngle * segmentCount;
    final sweepAngle = (2 * pi - totalGap) / segmentCount;
    final startOffset = -pi / 2;

    for (int i = 0; i < segmentCount; i++) {
      final paint = Paint()
        ..color = _palette[i % _palette.length]
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;

      final start = startOffset + i * (sweepAngle + gapAngle);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        sweepAngle,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SegmentedBorderPainter oldDelegate) {
    return oldDelegate.segmentCount != segmentCount ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
