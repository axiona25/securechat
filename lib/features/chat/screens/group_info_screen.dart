import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/services/api_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/user_avatar_widget.dart';

class GroupInfoScreen extends StatefulWidget {
  final String conversationId;
  final Map<String, dynamic>? conversationData;
  final VoidCallback? onGroupUpdated;

  const GroupInfoScreen({
    super.key,
    required this.conversationId,
    this.conversationData,
    this.onGroupUpdated,
  });

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  Map<String, dynamic>? _conversation;
  List<Map<String, dynamic>> _participants = [];
  bool _loading = true;
  bool _isAdmin = false;
  int? _currentUserId;
  String _groupName = '';
  String _groupDescription = '';
  String? _groupAvatar;
  int? _creatorUserId;
  final Set<int> _mutedUserIds = {};
  final Set<int> _blockedUserIds = {};

  static const Color _teal = Color(0xFF2ABFBF);
  static const Color _navy = Color(0xFF1A2B4A);
  static const Color _subtitleGray = Color(0xFF9E9E9E);

  @override
  void initState() {
    super.initState();
    _loadGroupInfo();
  }

  Future<void> _loadGroupInfo() async {
    try {
      final response = await ApiService().get('/chat/conversations/${widget.conversationId}/');
      if (response != null && mounted) {
        debugPrint('[GROUP-INFO] Response: $response');
        debugPrint('[GROUP-INFO] Participants info count: ${(response['participants_info'] as List?)?.length ?? 0}');
        final prefs = await SharedPreferences.getInstance();
        // Recupera current user id dalle prefs (potrebbe essere salvato come int o String)
        final rawUserId = prefs.get('user_id') ?? prefs.get('userId') ?? prefs.get('current_user_id');
        if (rawUserId is int) {
          _currentUserId = rawUserId;
        } else if (rawUserId is String) {
          _currentUserId = int.tryParse(rawUserId);
        }
        debugPrint('[GROUP-INFO] currentUserId: $_currentUserId (raw: $rawUserId)');

        final participantsRaw = response['participants_info'] as List? ?? [];
        final participants = participantsRaw.map((p) {
          final pMap = p is Map<String, dynamic> ? p : Map<String, dynamic>.from(p as Map);
          final user = pMap['user'] is Map<String, dynamic>
              ? pMap['user'] as Map<String, dynamic>
              : (pMap['user'] is Map ? Map<String, dynamic>.from(pMap['user'] as Map) : <String, dynamic>{});
          return {
            'id': user['id'],
            'user_id': user['id'],
            'first_name': user['first_name'] ?? '',
            'last_name': user['last_name'] ?? '',
            'username': user['username'] ?? '',
            'email': user['email'] ?? '',
            'avatar': user['profile_picture'] ?? user['avatar'] ?? user['avatar_url'],
            'role': pMap['role'] ?? 'member',
            'is_online': user['is_online'] ?? false,
          };
        }).toList();

        final myRole = participants
            .where((p) => p['user_id'] == _currentUserId || p['id'] == _currentUserId)
            .map((p) => p['role']?.toString() ?? 'member')
            .firstOrNull ?? 'member';

        int? creatorUserId;
        for (final p in participantsRaw) {
          if (p is Map && p['role'] == 'admin') {
            final creatorUser = p['user'];
            if (creatorUser is Map) {
              creatorUserId = creatorUser['id'] is int
                  ? creatorUser['id'] as int
                  : int.tryParse(creatorUser['id']?.toString() ?? '');
            }
            break;
          }
        }

        debugPrint('[GROUP-INFO] currentUserId: $_currentUserId, myRole: $myRole');

        setState(() {
          _conversation = response;
          _participants = participants;
          _isAdmin = myRole == 'admin';
          _creatorUserId = creatorUserId;
          _groupName = response['group_name']?.toString() ?? response['name']?.toString() ?? '';
          _groupDescription = response['group_description']?.toString() ?? response['description']?.toString() ?? '';
          final avatarRaw = response['group_avatar']?.toString() ?? response['avatar']?.toString();
          _groupAvatar = (avatarRaw != null && avatarRaw != 'null' && avatarRaw.isNotEmpty) ? avatarRaw : null;
          _loading = false;
        });
      }
    } catch (e, stackTrace) {
      debugPrint('[GROUP-INFO] ERROR: $e');
      debugPrint('[GROUP-INFO] STACK: $stackTrace');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _changeGroupAvatar() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 80);
    if (picked == null) return;

    try {
      final token = ApiService().accessToken;
      if (token == null) return;
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('${AppConstants.baseUrl}/chat/conversations/${widget.conversationId}/avatar/'),
      );
      request.headers['Authorization'] = 'Bearer $token';
      request.files.add(await http.MultipartFile.fromPath('avatar', picked.path));
      final response = await request.send();
      if (response.statusCode == 200) {
        await _loadGroupInfo();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Avatar aggiornato'), backgroundColor: _teal),
          );
          widget.onGroupUpdated?.call();
        }
      }
    } catch (e) {
      debugPrint('Change avatar error: $e');
    }
  }

  Future<void> _editGroupName() async {
    final controller = TextEditingController(text: _groupName);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Modifica nome gruppo', style: TextStyle(fontWeight: FontWeight.w700)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Nome del gruppo',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _teal, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Salva'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty && result != _groupName) {
      try {
        await ApiService().patch(
          '/chat/conversations/${widget.conversationId}/',
          body: {'name': result},
        );
        setState(() => _groupName = result);
        widget.onGroupUpdated?.call();
      } catch (e) {
        debugPrint('Edit group name error: $e');
      }
    }
  }

  Future<void> _changeRole(int userId, String newRole) async {
    try {
      await ApiService().patch(
        '/chat/conversations/${widget.conversationId}/participants/$userId/',
        body: {'role': newRole},
      );
      await _loadGroupInfo();
    } catch (e) {
      debugPrint('Change role error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _removeMember(int userId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Rimuovi partecipante', style: TextStyle(fontWeight: FontWeight.w700)),
        content: const Text('Vuoi rimuovere questo partecipante dal gruppo?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annulla')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Rimuovi'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ApiService().delete('/chat/conversations/${widget.conversationId}/participants/$userId/');
      await _loadGroupInfo();
      widget.onGroupUpdated?.call();
    } catch (e) {
      debugPrint('Remove member error: $e');
    }
  }

  Future<void> _muteParticipant(int userId) async {
    setState(() {
      if (_mutedUserIds.contains(userId)) {
        _mutedUserIds.remove(userId);
      } else {
        _mutedUserIds.add(userId);
      }
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_mutedUserIds.contains(userId) ? 'Utente silenziato' : 'Utente non più silenziato'),
          backgroundColor: _teal,
        ),
      );
    }
  }

  Future<void> _blockParticipant(int userId) async {
    final isBlocked = _blockedUserIds.contains(userId);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(isBlocked ? 'Sblocca utente' : 'Blocca utente', style: const TextStyle(fontWeight: FontWeight.w700)),
        content: Text(isBlocked ? 'Vuoi sbloccare questo utente?' : 'Vuoi bloccare questo utente? Non potrà inviarti messaggi.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annulla')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: isBlocked ? _teal : Colors.orange, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isBlocked ? 'Sblocca' : 'Blocca'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() {
      if (isBlocked) {
        _blockedUserIds.remove(userId);
      } else {
        _blockedUserIds.add(userId);
      }
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isBlocked ? 'Utente sbloccato' : 'Utente bloccato'),
          backgroundColor: isBlocked ? _teal : Colors.orange,
        ),
      );
    }
  }

  Future<void> _addMembers() async {
    final result = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _AddMembersSheet(
        conversationId: widget.conversationId,
        existingParticipantIds: _participants.map((p) => p['user_id'] as int? ?? p['id'] as int? ?? 0).toSet(),
      ),
    );
    if (result != null && result.isNotEmpty) {
      try {
        for (final userId in result) {
          await ApiService().post(
            '/chat/conversations/${widget.conversationId}/participants/',
            body: {'user_id': userId},
          );
        }
        await _loadGroupInfo();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${result.length} ${result.length == 1 ? "membro aggiunto" : "membri aggiunti"}'),
              backgroundColor: _teal,
            ),
          );
          widget.onGroupUpdated?.call();
        }
      } catch (e) {
        debugPrint('Add members error: $e');
      }
    }
  }

  Future<void> _leaveGroup() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Abbandona gruppo', style: TextStyle(fontWeight: FontWeight.w700)),
        content: const Text('Vuoi abbandonare questo gruppo?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annulla')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Abbandona'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ApiService().delete('/chat/conversations/${widget.conversationId}/leave/');
      if (mounted) {
        Navigator.pop(context);
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint('Leave group error: $e');
    }
  }

  String _roleLabel(String role) {
    switch (role) {
      case 'admin':
        return 'Admin';
      case 'moderator':
        return 'Moderatore';
      default:
        return 'Membro';
    }
  }

  Color _roleColor(String role) {
    switch (role) {
      case 'admin':
        return _teal;
      case 'moderator':
        return Colors.orange;
      default:
        return _subtitleGray;
    }
  }

  String _initials(Map<String, dynamic> p) {
    final first = (p['first_name'] ?? '').toString().trim();
    final last = (p['last_name'] ?? '').toString().trim();
    if (first.isNotEmpty && last.isNotEmpty) return '${first[0]}${last[0]}'.toUpperCase();
    if (first.isNotEmpty) return first[0].toUpperCase();
    return '?';
  }

  String _displayName(Map<String, dynamic> p) {
    final name = '${p['first_name'] ?? ''} ${p['last_name'] ?? ''}'.trim();
    return name.isNotEmpty ? name : p['username']?.toString() ?? p['email']?.toString() ?? '?';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.blue700),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Info Gruppo', style: TextStyle(color: _navy, fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _teal))
          : SingleChildScrollView(
              child: Column(
                children: [
                  // Header con avatar e nome
                  Container(
                    color: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Column(
                      children: [
                        // Avatar gruppo
                        GestureDetector(
                          onTap: _isAdmin ? _changeGroupAvatar : null,
                          child: Stack(
                            children: [
                              CircleAvatar(
                                radius: 55,
                                backgroundColor: const Color(0xFFB0E0D4),
                                backgroundImage: _groupAvatar != null && _groupAvatar!.isNotEmpty
                                    ? NetworkImage(_groupAvatar!)
                                    : null,
                                child: _groupAvatar == null || _groupAvatar!.isEmpty
                                    ? Text(
                                        _groupName.length >= 2
                                            ? _groupName.substring(0, 2).toUpperCase()
                                            : _groupName.toUpperCase(),
                                        style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.w700),
                                      )
                                    : null,
                              ),
                              if (_isAdmin)
                                Positioned(
                                  bottom: 0,
                                  right: 0,
                                  child: Container(
                                    width: 34,
                                    height: 34,
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
                        const SizedBox(height: 12),
                        // Nome gruppo
                        GestureDetector(
                          onTap: _isAdmin ? _editGroupName : null,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(_groupName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: _navy)),
                              if (_isAdmin) ...[
                                const SizedBox(width: 6),
                                const Icon(Icons.edit, size: 18, color: _teal),
                              ],
                            ],
                          ),
                        ),
                        if (_groupDescription.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Text(_groupDescription, style: const TextStyle(fontSize: 14, color: _subtitleGray), textAlign: TextAlign.center),
                          ),
                        ],
                        const SizedBox(height: 4),
                        Text('${_participants.length} partecipanti', style: const TextStyle(fontSize: 14, color: _subtitleGray)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Partecipanti
                  Container(
                    color: Colors.white,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                          child: Row(
                            children: [
                              const Text('Partecipanti', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _navy)),
                              const Spacer(),
                              if (_isAdmin)
                                GestureDetector(
                                  onTap: _addMembers,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(color: _teal, borderRadius: BorderRadius.circular(16)),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.person_add, color: Colors.white, size: 16),
                                        SizedBox(width: 4),
                                        Text('Aggiungi', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        ..._participants.map((p) {
                          final userId = p['user_id'] ?? p['id'];
                          final isMe = userId == _currentUserId;
                          final role = p['role']?.toString() ?? 'member';
                          final avatar = p['avatar']?.toString();
                          final uid = userId is int ? userId : int.tryParse(userId.toString());
                          debugPrint('[GROUP-INFO] participant: ${_displayName(p)}, userId=$userId, currentUserId=$_currentUserId, isMe=$isMe');
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ListTile(
                            leading: CircleAvatar(
                              backgroundColor: _teal,
                              backgroundImage: avatar != null && avatar.isNotEmpty ? NetworkImage(avatar) : null,
                              child: avatar == null || avatar.isEmpty
                                  ? Text(_initials(p), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))
                                  : null,
                            ),
                            title: Row(
                              children: [
                                Text(
                                  _displayName(p) + (isMe ? ' (Tu)' : ''),
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: _navy),
                                ),
                                if (role != 'member') ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: _roleColor(role).withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(_roleLabel(role), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _roleColor(role))),
                                  ),
                                ],
                                if (uid != null && _mutedUserIds.contains(uid)) ...[
                                  const SizedBox(width: 6),
                                  const Icon(Icons.volume_off_rounded, size: 16, color: Color(0xFF607D8B)),
                                ],
                                if (uid != null && _blockedUserIds.contains(uid)) ...[
                                  const SizedBox(width: 6),
                                  const Icon(Icons.block_rounded, size: 16, color: Colors.orange),
                                ],
                              ],
                            ),
                            subtitle: Text(p['email']?.toString() ?? '', style: const TextStyle(fontSize: 12, color: _subtitleGray)),
                            trailing: !isMe
                                ? PopupMenuButton<String>(
                                    icon: const Icon(Icons.more_vert, color: _subtitleGray, size: 22),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    onSelected: (value) {
                                      final uid = userId is int ? userId : int.parse(userId.toString());
                                      switch (value) {
                                        case 'mute':
                                          _muteParticipant(uid);
                                          break;
                                        case 'block':
                                          _blockParticipant(uid);
                                          break;
                                        case 'admin':
                                        case 'moderator':
                                        case 'member':
                                          _changeRole(uid, value);
                                          break;
                                        case 'remove':
                                          _removeMember(uid);
                                          break;
                                      }
                                    },
                                    itemBuilder: (ctx) => [
                                      PopupMenuItem(
                                        value: 'mute',
                                        child: Row(
                                          children: [
                                            const Icon(Icons.volume_off_rounded, color: Color(0xFF607D8B), size: 20),
                                            const SizedBox(width: 12),
                                            Text(uid != null && _mutedUserIds.contains(uid) ? 'Riattiva audio' : 'Silenzia'),
                                          ],
                                        ),
                                      ),
                                      PopupMenuItem(
                                        value: 'block',
                                        child: Row(
                                          children: [
                                            const Icon(Icons.block_rounded, color: Color(0xFFFF9800), size: 20),
                                            const SizedBox(width: 12),
                                            Text(uid != null && _blockedUserIds.contains(uid) ? 'Sblocca' : 'Blocca'),
                                          ],
                                        ),
                                      ),
                                      if (_isAdmin) ...[
                                        const PopupMenuDivider(),
                                        if (role != 'admin')
                                          const PopupMenuItem(
                                            value: 'admin',
                                            child: Row(
                                              children: [
                                                Icon(Icons.shield_rounded, color: Color(0xFF2ABFBF), size: 20),
                                                SizedBox(width: 12),
                                                Text('Promuovi ad Admin'),
                                              ],
                                            ),
                                          ),
                                        if (role != 'moderator')
                                          const PopupMenuItem(
                                            value: 'moderator',
                                            child: Row(
                                              children: [
                                                Icon(Icons.security_rounded, color: Color(0xFFFF9800), size: 20),
                                                SizedBox(width: 12),
                                                Text('Rendi Moderatore'),
                                              ],
                                            ),
                                          ),
                                        if (role != 'member' && uid != _creatorUserId)
                                          const PopupMenuItem(
                                            value: 'member',
                                            child: Row(
                                              children: [
                                                Icon(Icons.person_rounded, color: Color(0xFF607D8B), size: 20),
                                                SizedBox(width: 12),
                                                Text('Rimuovi ruolo'),
                                              ],
                                            ),
                                          ),
                                        const PopupMenuDivider(),
                                        if (uid != _creatorUserId)
                                          const PopupMenuItem(
                                            value: 'remove',
                                            child: Row(
                                              children: [
                                                Icon(Icons.person_remove_rounded, color: Colors.red, size: 20),
                                                SizedBox(width: 12),
                                                Text('Rimuovi dal gruppo', style: TextStyle(color: Colors.red)),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ],
                                  )
                                : null,
                              ),
                              const Divider(height: 1, thickness: 0.5, indent: 72, endIndent: 16, color: Color(0xFFEEEEEE)),
                            ],
                          );
                        }),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Azioni
                  Container(
                    color: Colors.white,
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.exit_to_app, color: Colors.red),
                          title: const Text('Abbandona gruppo', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
                          onTap: _leaveGroup,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }
}

// Foglio per aggiungere nuovi membri
class _AddMembersSheet extends StatefulWidget {
  final String conversationId;
  final Set<int> existingParticipantIds;

  const _AddMembersSheet({required this.conversationId, required this.existingParticipantIds});

  @override
  State<_AddMembersSheet> createState() => _AddMembersSheetState();
}

class _AddMembersSheetState extends State<_AddMembersSheet> {
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _filtered = [];
  final Set<int> _selectedIds = {};
  bool _loading = true;
  final _searchController = TextEditingController();

  static const Color _teal = Color(0xFF2ABFBF);
  static const Color _navy = Color(0xFF1A2B4A);

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    try {
      final response = await ApiService().get('/auth/users/search/?q=');
      final users = response is List ? response : (response['results'] ?? response['users'] ?? []);
      final available = <Map<String, dynamic>>[];
      for (final u in users) {
        final userMap = u is Map<String, dynamic> ? u : Map<String, dynamic>.from(u as Map);
        final id = userMap['id'] is int ? userMap['id'] as int : int.tryParse(userMap['id']?.toString() ?? '0') ?? 0;
        if (id == 0 || widget.existingParticipantIds.contains(id)) continue;
        available.add({
          'id': id,
          'display_name': '${userMap['first_name'] ?? ''} ${userMap['last_name'] ?? ''}'.trim(),
          'email': userMap['email'] ?? '',
          'avatar': userMap['profile_picture'] ?? userMap['avatar'] ?? userMap['avatar_url'],
        });
      }
      if (mounted) setState(() {
        _users = available;
        _filtered = available;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _filter(String q) {
    setState(() {
      if (q.isEmpty) {
        _filtered = _users;
        return;
      }
      final query = q.toLowerCase();
      _filtered = _users.where((u) {
        final name = (u['display_name'] ?? '').toString().toLowerCase();
        final email = (u['email'] ?? '').toString().toLowerCase();
        return name.contains(query) || email.contains(query);
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Text('Aggiungi membri', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _navy)),
                const Spacer(),
                if (_selectedIds.isNotEmpty)
                  GestureDetector(
                    onTap: () => Navigator.pop(context, _selectedIds.toList()),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(color: _teal, borderRadius: BorderRadius.circular(20)),
                      child: Text('Aggiungi (${_selectedIds.length})', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _searchController,
              onChanged: _filter,
              decoration: InputDecoration(
                hintText: 'Cerca...',
                prefixIcon: const Icon(Icons.search, color: Color(0xFF9E9E9E)),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                filled: true,
                fillColor: const Color(0xFFF5F5F5),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: _teal))
                : ListView.builder(
                    itemCount: _filtered.length,
                    itemBuilder: (ctx, i) {
                      final u = _filtered[i];
                      final id = u['id'] as int;
                      final selected = _selectedIds.contains(id);
                      final avatar = u['avatar']?.toString();
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: _teal,
                          backgroundImage: avatar != null && avatar.isNotEmpty ? NetworkImage(avatar) : null,
                          child: avatar == null || avatar.isEmpty
                              ? Text(
                                  (u['display_name'] ?? '?').toString().isNotEmpty ? (u['display_name'] ?? '?').toString()[0].toUpperCase() : '?',
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                                )
                              : null,
                        ),
                        title: Text((u['display_name'] ?? '').toString(), style: const TextStyle(fontWeight: FontWeight.w500)),
                        subtitle: Text(u['email']?.toString() ?? '', style: const TextStyle(fontSize: 12, color: Color(0xFF9E9E9E))),
                        trailing: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: selected ? _teal : Colors.transparent,
                            border: Border.all(color: selected ? _teal : const Color(0xFFDDDDDD), width: 2),
                          ),
                          child: selected ? const Icon(Icons.check, color: Colors.white, size: 16) : null,
                        ),
                        onTap: () => setState(() {
                          if (selected) {
                            _selectedIds.remove(id);
                          } else {
                            _selectedIds.add(id);
                          }
                        }),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }
}
