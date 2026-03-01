import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_colors.dart';
import '../../core/services/api_service.dart';
import '../../core/services/auth_service.dart';
import '../../core/widgets/user_avatar_widget.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/locale_provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.onBack});

  /// Se fornito, il pulsante indietro richiama questo invece di Navigator.pop (es. per tornare alla tab Chat).
  final VoidCallback? onBack;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic>? _profile;
  bool _notificationsEnabled = true;
  bool _autoTranslateEnabled = false;
  bool _loading = true;

  static const Color _teal = Color(0xFF2ABFBF);
  AppLocalizations get l10n => AppLocalizations.of(context)!;
  static const Color _navy = Color(0xFF1A2B4A);

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _autoTranslateEnabled = prefs.getBool('auto_translate') ?? false;
      final response = await ApiService().get('/auth/profile/');
      if (response != null) {
        setState(() {
          _profile = response is Map<String, dynamic> ? response : null;
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
    } catch (e) {
      debugPrint('Errore caricamento profilo: $e');
      setState(() => _loading = false);
    }
  }

  String get _displayName {
    if (_profile == null) return '';
    final first = _profile!['first_name']?.toString() ?? '';
    final last = _profile!['last_name']?.toString() ?? '';
    return '$first $last'.trim();
  }

  String get _email => _profile?['email']?.toString() ?? '';

  String get _currentLanguageName {
    final code = localeProvider.locale.languageCode;
    for (final l in AppLocalizations.supportedLanguages) {
      if (l['code'] == code) return l['name']!;
    }
    return 'Italiano';
  }

  void _showLanguageSelector(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        height: MediaQuery.of(context).size.height * 0.7,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    AppLocalizations.of(context)?.t('select_language') ?? 'Seleziona Lingua',
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Color(0xFF1A2B3C)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: Colors.grey.shade200),
            Expanded(
              child: ListView.builder(
                itemCount: AppLocalizations.supportedLanguages.length,
                itemBuilder: (context, index) {
                  final lang = AppLocalizations.supportedLanguages[index];
                  final isSelected = localeProvider.locale.languageCode == lang['code'];
                  return ListTile(
                    leading: Text(lang['flag']!, style: const TextStyle(fontSize: 28)),
                    title: Text(lang['name']!, style: TextStyle(fontSize: 16, fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500, color: const Color(0xFF1A2B3C))),
                    trailing: isSelected ? const Icon(Icons.check_circle, color: Color(0xFF2ABFBF), size: 24) : null,
                    tileColor: isSelected ? const Color(0xFF2ABFBF).withOpacity(0.05) : null,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    onTap: () async {
                      await localeProvider.setLocale(Locale(lang['code']!));
                      if (context.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('${lang['flag']} ${lang['name']}'),
                            backgroundColor: const Color(0xFF2ABFBF),
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        );
                      }
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? get _avatarUrl {
    final url = _profile?['avatar']?.toString();
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('http')) return url;
    return '${AppConstants.mediaBaseUrl}$url';
  }

  String get _statusText {
    final isOnline = _profile?['is_online'] == true;
    return isOnline ? l10n.t('online') : l10n.t('offline');
  }

  Color get _statusColor {
    final isOnline = _profile?['is_online'] == true;
    return isOnline ? const Color(0xFF4CAF50) : Colors.grey;
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(l10n.t('logout'), style: const TextStyle(fontWeight: FontWeight.w700)),
        content: Text(l10n.t('confirm_logout')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.t('cancel'), style: TextStyle(color: Colors.grey[600])),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.t('logout'), style: const TextStyle(color: Color(0xFFE53935), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      // 1. Imposta stato offline sul server (se il backend supporta PATCH profile)
      try {
        await ApiService().patch('/auth/profile/', body: {'is_online': false});
      } catch (_) {}

      // 2. Cancella token e sessione (chiama anche POST /auth/logout/ che imposta is_online=false)
      await AuthService().logout();

      // 3. Naviga alla login
      if (mounted) {
        Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
      }
    } catch (e) {
      debugPrint('Errore logout: $e');
      await AuthService().logout();
      if (mounted) {
        Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
      }
    }
  }

  Future<void> _editProfile() async {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(margin: const EdgeInsets.only(top: 10, bottom: 8), width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
            ListTile(
              leading: const Icon(Icons.camera_alt_rounded, color: Color(0xFF2ABFBF)),
              title: const Text('Cambia foto profilo'),
              onTap: () { Navigator.pop(ctx); _pickAndUploadAvatar(); },
            ),
            ListTile(
              leading: const Icon(Icons.person_rounded, color: Color(0xFF2ABFBF)),
              title: const Text('Modifica nome'),
              onTap: () { Navigator.pop(ctx); _editName(); },
            ),
            if (_avatarUrl != null)
              ListTile(
                leading: const Icon(Icons.delete_rounded, color: Colors.red),
                title: const Text('Rimuovi foto', style: TextStyle(color: Colors.red)),
                onTap: () { Navigator.pop(ctx); _removeAvatar(); },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndUploadAvatar() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 80);
    if (picked == null) return;

    try {
      final token = ApiService().accessToken;
      if (token == null) return;

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('${AppConstants.baseUrl}/auth/avatar/'),
      );
      request.headers['Authorization'] = 'Bearer $token';
      request.files.add(await http.MultipartFile.fromPath('avatar', picked.path));

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      if (response.statusCode == 200) {
        await _loadProfile();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Foto profilo aggiornata'), backgroundColor: Color(0xFF2ABFBF)),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Errore nel caricamento della foto'), backgroundColor: Colors.red),
          );
        }
      }
    } catch (e) {
      debugPrint('Upload avatar error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _editName() async {
    final firstNameController = TextEditingController(text: _profile?['first_name']?.toString() ?? '');
    final lastNameController = TextEditingController(text: _profile?['last_name']?.toString() ?? '');

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Modifica nome', style: TextStyle(fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: firstNameController,
              decoration: InputDecoration(
                labelText: 'Nome',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: lastNameController,
              decoration: InputDecoration(
                labelText: 'Cognome',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.t('cancel'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2ABFBF), foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.t('save')),
          ),
        ],
      ),
    );

    if (result != true) return;
    try {
      await ApiService().patch('/auth/profile/', body: {
        'first_name': firstNameController.text.trim(),
        'last_name': lastNameController.text.trim(),
      });
      await _loadProfile();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nome aggiornato'), backgroundColor: Color(0xFF2ABFBF)),
        );
      }
    } catch (e) {
      debugPrint('Edit name error: $e');
    }
  }

  Future<void> _removeAvatar() async {
    try {
      await ApiService().delete('/auth/avatar/');
      await _loadProfile();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Foto profilo rimossa'), backgroundColor: Color(0xFF2ABFBF)),
        );
      }
    } catch (e) {
      debugPrint('Remove avatar error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF2ABFBF)))
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    const SizedBox(height: 8),
                    // Header
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () {
                            if (widget.onBack != null) {
                              widget.onBack!();
                            } else {
                              Navigator.maybePop(context);
                            }
                          },
                          child: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF1A2B4A), size: 22),
                        ),
                        Expanded(
                          child: Text(
                            l10n.t('settings'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1A2B4A),
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: _editProfile,
                          child: Text(
                            l10n.t('edit'),
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF2ABFBF),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Avatar
                    GestureDetector(
                      onTap: _pickAndUploadAvatar,
                      child: Stack(
                        children: [
                          UserAvatarWidget(
                            avatarUrl: _avatarUrl,
                            firstName: _profile?['first_name']?.toString(),
                            lastName: _profile?['last_name']?.toString(),
                            size: 100,
                            borderWidth: 3,
                            borderColor: _teal.withOpacity(0.3),
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
                          Positioned(
                            bottom: 4,
                            left: 4,
                            child: Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                color: _statusColor,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2.5),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Nome e email
                    Text(
                      _displayName,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1A2B4A),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _email,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[500],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Sezione 1 — Account settings
                    _buildSection([
                      _buildMenuItem(
                        icon: Icons.person_outline_rounded,
                        iconColor: _teal,
                        title: l10n.t('account'),
                        onTap: () => _showComingSoon(l10n.t('account')),
                      ),
                      _buildDivider(),
                      _buildMenuItem(
                        icon: Icons.shield_outlined,
                        iconColor: const Color(0xFF4CAF50),
                        title: l10n.t('privacy'),
                        onTap: () => _showComingSoon(l10n.t('privacy')),
                      ),
                      _buildDivider(),
                      _buildToggleItem(
                        icon: Icons.notifications_none_rounded,
                        iconColor: _teal,
                        title: l10n.t('notifications'),
                        value: _notificationsEnabled,
                        onChanged: (val) {
                          setState(() => _notificationsEnabled = val);
                        },
                      ),
                      _buildDivider(),
                      _buildMenuItem(
                        icon: Icons.chat_bubble_outline_rounded,
                        iconColor: _teal,
                        title: l10n.t('chat_settings'),
                        onTap: () => _showComingSoon(l10n.t('chat_settings')),
                      ),
                      _buildDivider(),
                      _buildToggleItem(
                        icon: Icons.translate_rounded,
                        iconColor: const Color(0xFF7C4DFF),
                        title: l10n.t('auto_translate'),
                        value: _autoTranslateEnabled,
                        onChanged: (val) async {
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setBool('auto_translate', val);
                          setState(() => _autoTranslateEnabled = val);
                          if (val && mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(l10n.t('auto_translate_enabled')),
                                backgroundColor: const Color(0xFF2ABFBF),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                            );
                          }
                        },
                      ),
                      _buildDivider(),
                      _buildMenuItem(
                        icon: Icons.language_rounded,
                        iconColor: _teal,
                        title: l10n.t('language'),
                        trailing: Text(_currentLanguageName, style: TextStyle(color: Colors.grey[400], fontSize: 14)),
                        onTap: () => _showLanguageSelector(context),
                      ),
                    ]),
                    const SizedBox(height: 16),

                    // Sezione 2 — Help
                    _buildSection([
                      _buildMenuItem(
                        icon: Icons.help_outline_rounded,
                        iconColor: Colors.grey[500]!,
                        title: l10n.t('help'),
                        onTap: () => _showComingSoon(l10n.t('help')),
                      ),
                      _buildDivider(),
                      _buildMenuItem(
                        icon: Icons.person_add_outlined,
                        iconColor: Colors.grey[500]!,
                        title: l10n.t('invite_friends'),
                        onTap: () => _showComingSoon(l10n.t('invite_friends')),
                      ),
                    ]),
                    const SizedBox(height: 16),

                    // Sezione 3 — Logout
                    _buildSection([
                      _buildMenuItem(
                        icon: Icons.logout_rounded,
                        iconColor: const Color(0xFFE53935),
                        title: l10n.t('logout'),
                        titleColor: const Color(0xFFE53935),
                        showChevron: false,
                        onTap: _logout,
                      ),
                    ]),
                    const SizedBox(height: 100),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildSection(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.85),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(children: children),
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required Color iconColor,
    required String title,
    Color? titleColor,
    Widget? trailing,
    bool showChevron = true,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: titleColor ?? _navy,
                ),
              ),
            ),
            if (trailing != null) ...[trailing, const SizedBox(width: 8)],
            if (showChevron)
              Icon(Icons.chevron_right_rounded, color: Colors.grey[300], size: 22),
          ],
        ),
      ),
    );
  }

  Widget _buildToggleItem({
    required IconData icon,
    required Color iconColor,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Color(0xFF1A2B4A),
              ),
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: _teal,
            activeTrackColor: _teal.withOpacity(0.3),
          ),
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return Padding(
      padding: const EdgeInsets.only(left: 66),
      child: Divider(height: 1, color: Colors.grey[200]),
    );
  }

  void _showComingSoon(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$feature — ${l10n.t('coming_soon')}'),
        backgroundColor: _teal,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
