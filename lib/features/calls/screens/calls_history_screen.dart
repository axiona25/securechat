import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/call_service.dart';
import '../../../core/widgets/user_avatar_widget.dart';
import '../../../core/routes/app_router.dart';
import '../../../core/l10n/app_localizations.dart';
import '../models/call_log_model.dart';
import 'call_screen.dart';

/// Cronologia chiamate (tab Chiamate nella Home).
/// Carica da GET /api/calls/log/, supporta filtro Tutte/Perse e pull-to-refresh.
class CallsHistoryScreen extends StatefulWidget {
  final VoidCallback? onMissedCountChanged;

  const CallsHistoryScreen({
    super.key,
    this.onMissedCountChanged,
  });

  @override
  State<CallsHistoryScreen> createState() => CallsHistoryScreenState();
}

class CallsHistoryScreenState extends State<CallsHistoryScreen> {
  final ApiService _api = ApiService();
  List<CallLogModel> _calls = [];
  bool _loading = true;
  bool _showMissedOnly = false;
  String? _nextPageUrl;
  int? _currentUserId;
  StreamSubscription<CallState>? _callStateSubscription;

  static const Color _teal = Color(0xFF2ABFBF);
  static const Color _navy = Color(0xFF1A2B4A);
  static const Color _gray = Color(0xFF9E9E9E);

  AppLocalizations get l10n => AppLocalizations.of(context)!;

  /// Ricarica la lista chiamate (es. quando si torna sul tab o dopo una chiamata).
  void refresh() {
    _loadCalls();
  }

  @override
  void initState() {
    super.initState();
    _loadCurrentUserId();
    _loadCalls();
    _callStateSubscription = CallService().stateStream.listen((callState) {
      if (callState.status == CallStatus.ended || callState.status == CallStatus.idle) {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) {
            _loadCalls();
            widget.onMissedCountChanged?.call();
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _callStateSubscription?.cancel();
    super.dispose();
  }

  /// Carica e salva in stato l'id utente corrente; ritorna l'id per uso immediato.
  Future<int?> _loadCurrentUserId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getInt('current_user_id') ?? int.tryParse(prefs.getString('current_user_id') ?? '');
    if (mounted) setState(() => _currentUserId = id);
    return id;
  }

  Future<void> _loadCalls({bool append = false}) async {
    if (!append) {
      if (mounted) setState(() => _loading = true);
    }
    int? uid = _currentUserId;
    if (uid == null) uid = await _loadCurrentUserId();
    try {
      String endpoint = '/calls/log/';
      Map<String, String>? queryParams;
      if (append && _nextPageUrl != null && _nextPageUrl!.isNotEmpty) {
        final uri = Uri.parse(_nextPageUrl!);
        final path = uri.path;
        endpoint = path.startsWith('/api/') ? '/${path.substring(5)}' : path;
        if (uri.queryParameters.isNotEmpty) {
          queryParams = Map<String, String>.from(uri.queryParameters);
        }
      } else {
        if (_showMissedOnly) queryParams = {'status': 'missed'};
      }
      final response = await _api.get(endpoint, queryParams: queryParams);
      final results = response['results'] as List<dynamic>? ?? [];
      final next = response['next']?.toString();
      final list = results
          .map((e) => CallLogModel.fromJson(e as Map<String, dynamic>, currentUserId: uid))
          .toList();
      if (mounted) {
        setState(() {
          _calls = append ? _calls + list : list;
          _nextPageUrl = (next != null && next.isNotEmpty) ? next : null;
          _loading = false;
        });
        widget.onMissedCountChanged?.call();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[CallsHistory] load error: $e');
      if (mounted) {
        setState(() {
          if (!append) _calls = [];
          _loading = false;
        });
      }
    }
  }

  Future<void> _clearCallHistory() async {
    var token = _api.accessToken;
    if (token == null) {
      final prefs = await SharedPreferences.getInstance();
      token = prefs.getString('access_token') ?? prefs.getString('access');
    }
    final headers = <String, String>{'Accept': 'application/json'};
    if (token != null) headers['Authorization'] = 'Bearer $token';

    Future<http.Response> tryClear() async {
      final deleteUrl = Uri.parse('${AppConstants.baseUrl}/calls/log/');
      if (kDebugMode) debugPrint('[CallsHistory] clear: DELETE $deleteUrl');
      final r = await http.delete(deleteUrl, headers: headers);
      if (kDebugMode) debugPrint('[CallsHistory] clear response: ${r.statusCode} ${r.body}');
      if (r.statusCode == 405) {
        final postUrl = Uri.parse('${AppConstants.baseUrl}/calls/log/clear/');
        if (kDebugMode) debugPrint('[CallsHistory] clear: fallback POST $postUrl');
        headers['Content-Type'] = 'application/json';
        final r2 = await http.post(postUrl, headers: headers, body: jsonEncode(<String, dynamic>{}));
        if (kDebugMode) debugPrint('[CallsHistory] clear fallback response: ${r2.statusCode} ${r2.body}');
        return r2;
      }
      return r;
    }

    try {
      final response = await tryClear();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (mounted) {
          setState(() {
            _calls = [];
            _nextPageUrl = null;
          });
          await _loadCalls();
          widget.onMissedCountChanged?.call();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.t('call_clear_history_success')),
                backgroundColor: _teal,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                duration: const Duration(seconds: 2),
              ),
            );
          }
        }
        return;
      }
      if (kDebugMode) debugPrint('[CallsHistory] clear failed: ${response.statusCode}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.t('error_connection')),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[CallsHistory] clear error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.t('error_connection')),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    }
  }

  Future<void> _showClearCallHistoryDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.t('call_clear_history_title')),
        content: Text(l10n.t('call_clear_history_message')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.t('delete'), style: const TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _clearCallHistory();
  }

  Future<String?> _fetchCallDetail(String callId) async {
    try {
      final data = await _api.get('/calls/$callId/');
      final conv = data['conversation'];
      return conv?.toString();
    } catch (_) {
      return null;
    }
  }

  void _openChat(String? conversationId) {
    if (conversationId == null) return;
    Navigator.of(context).pushNamed(
      AppRouter.chatDetail,
      arguments: {'conversationId': conversationId},
    ).then((_) => _loadCalls());
  }

  void _startCall(CallLogModel call, String callType) {
    final otherId = call.otherUserId();
    if (otherId == null) return;
    _fetchCallDetail(call.id).then((convId) {
      if (!mounted || convId == null) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CallScreen(
            conversationId: convId,
            callType: callType,
            isIncoming: false,
            remoteUserId: otherId,
            remoteUserName: call.displayName(_currentUserId),
            remoteUserAvatar: _avatarUrl(call.displayAvatarUrl()),
          ),
        ),
      ).then((_) => _loadCalls());
    });
  }

  String? _avatarUrl(String? path) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http')) return path;
    final base = AppConstants.mediaBaseUrl;
    return path.startsWith('/') ? '$base$path' : '$base/$path';
  }

  Future<void> _onTapRow(CallLogModel call) async {
    final conv = await _api.get('/calls/${call.id}/');
    final conversationId = conv['conversation']?.toString();
    if (mounted) _openChat(conversationId);
  }

  void _showLongPressMenu(CallLogModel call) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.call, color: _teal),
              title: Text(l10n.t('call_audio')), // fallback: Chiama audio
              onTap: () {
                Navigator.pop(ctx);
                _startCall(call, 'audio');
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam, color: _teal),
              title: Text(l10n.t('call_video')), // fallback: Videochiamata
              onTap: () {
                Navigator.pop(ctx);
                _startCall(call, 'video');
              },
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline, color: _teal),
              title: Text(l10n.t('go_to_chat')), // fallback: Vai alla chat
              onTap: () async {
                Navigator.pop(ctx);
                try {
                  final conv = await _api.get('/calls/${call.id}/');
                  final conversationId = conv['conversation']?.toString();
                  if (mounted) _openChat(conversationId);
                } catch (_) {}
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: _gray),
              title: Text(l10n.t('delete_from_log')), // Elimina dal registro (placeholder)
              onTap: () {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.t('not_available'))),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime dt, String todayLabel, String yesterdayLabel) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(dt.year, dt.month, dt.day);
    final time = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (day == today) return '$todayLabel $time';
    if (today.difference(day).inDays == 1) return '$yesterdayLabel $time';
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} $time';
  }

  static String _formatDuration(int seconds) {
    if (seconds <= 0) return '';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(1)}:${s.toString().padLeft(2, '0')}';
  }

  /// Icona direzione basata su direction e status (rispetto a currentUserId).
  /// outgoing: ↗ verde; incoming completed: ↙ verde; incoming missed: ↙ rossa; rejected: X rossa.
  Widget _buildDirectionIcon(CallLogModel call) {
    if (call.isRejected) {
      return const Icon(Icons.close, color: AppColors.error, size: 20); // rifiutata: X rossa
    }
    if (call.isMissed) {
      return const Icon(Icons.call_received, color: AppColors.error, size: 20); // persa: ↙ rossa
    }
    if (call.direction == 'outgoing') {
      return const Icon(Icons.call_made, color: _teal, size: 20); // uscita: ↗ verde
    }
    return const Icon(Icons.call_received, color: _teal, size: 20); // entrata completata: ↙ verde
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                l10n.t('calls'),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: _navy,
                ),
              ),
              Row(
                children: [
                  _filterChip(l10n.t('call_filter_all'), !_showMissedOnly),
                  const SizedBox(width: 8),
                  _filterChip(l10n.t('call_filter_missed'), _showMissedOnly),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.delete_sweep_outlined, color: _teal),
                    onPressed: _calls.isEmpty ? null : _showClearCallHistoryDialog,
                    tooltip: l10n.t('call_clear_history'),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            color: _teal,
            onRefresh: () async {
              _nextPageUrl = null;
              await _loadCalls();
            },
            child: _loading && _calls.isEmpty
                ? const Center(child: CircularProgressIndicator(color: _teal))
                : _calls.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                        children: [
                          SizedBox(
                            height: MediaQuery.of(context).size.height * 0.35,
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.call_outlined, size: 64, color: _gray.withOpacity(0.6)),
                                  const SizedBox(height: 16),
                                  Text(
                                    l10n.t('no_calls'),
                                    style: const TextStyle(
                                      fontSize: 16,
                                      color: _gray,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                        itemCount: _calls.length + (_nextPageUrl != null ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index >= _calls.length) {
                            _loadCalls(append: true);
                            return const Padding(
                              padding: EdgeInsets.all(16),
                              child: Center(child: CircularProgressIndicator(color: _teal, strokeWidth: 2)),
                            );
                          }
                          final call = _calls[index];
                          return _buildCallRow(call);
                        },
                      ),
          ),
        ),
      ],
    );
  }

  Widget _filterChip(String label, bool selected) {
    return GestureDetector(
      onTap: () {
        setState(() {
          _showMissedOnly = label == l10n.t('call_filter_missed');
          _nextPageUrl = null;
          _calls = [];
        });
        _loadCalls();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? _teal.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? _teal : _gray.withOpacity(0.5),
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? _teal : _gray,
          ),
        ),
      ),
    );
  }

  Widget _buildCallRow(CallLogModel call) {
    final isMissed = call.isMissed;
    final dateStr = _formatDate(
      call.createdAt,
      l10n.t('today'),
      l10n.t('yesterday'),
    );
    final durationStr = call.isCompleted && call.duration > 0
        ? _formatDuration(call.duration)
        : '';

    return InkWell(
      onTap: () {
        if (call.otherUserId() != null) {
          _startCall(call, call.callType);
        }
      },
      onLongPress: () => _showLongPressMenu(call),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            UserAvatarWidget(
              size: 48,
              avatarUrl: _avatarUrl(call.displayAvatarUrl(_currentUserId)),
              displayName: call.displayName(_currentUserId),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    call.displayName(_currentUserId),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: isMissed ? AppColors.error : _navy,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      _buildDirectionIcon(call),
                      const SizedBox(width: 4),
                      Icon(
                        call.callType == 'video' ? Icons.videocam : Icons.call,
                        size: 14,
                        color: _gray,
                      ),
                      if (durationStr.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Text(
                          durationStr,
                          style: const TextStyle(fontSize: 13, color: _gray),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Text(
              dateStr,
              style: const TextStyle(fontSize: 13, color: _gray),
            ),
          ],
        ),
      ),
    );
  }
}
