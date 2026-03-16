import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_colors.dart';
import '../../core/services/api_service.dart';

class ChatSettingsScreen extends StatefulWidget {
  const ChatSettingsScreen({super.key});

  @override
  State<ChatSettingsScreen> createState() => _ChatSettingsScreenState();
}

class _ChatSettingsScreenState extends State<ChatSettingsScreen> {
  Map<String, dynamic>? _profile;
  bool _loading = true;
  String _theme = 'light';
  bool _notificationsEnabled = true;
  double _fontSize = 14.0;

  static const Color _teal = Color(0xFF2ABFBF);
  static const Color _navy = Color(0xFF1A2B4A);
  static const String _fontSizeKey = 'chat_font_size';

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    try {
      final response = await ApiService().get('/auth/profile/');
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() {
          _profile = response is Map<String, dynamic> ? response : null;
          _theme = _profile?['theme']?.toString() ?? 'light';
          _notificationsEnabled = _profile?['notifications_enabled'] ?? true;
          _fontSize = prefs.getDouble(_fontSizeKey) ?? 14.0;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('Errore caricamento profilo: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showThemeSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Tema',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: _navy,
                ),
              ),
            ),
            ListTile(
              title: const Text('Chiaro'),
              trailing: _theme == 'light' ? const Icon(Icons.check, color: Color(0xFF2ABFBF)) : null,
              onTap: () async {
                Navigator.pop(ctx);
                await ApiService().patch('/auth/profile/', body: {'theme': 'light'});
                if (mounted) setState(() => _theme = 'light');
              },
            ),
            ListTile(
              title: const Text('Scuro'),
              trailing: _theme == 'dark' ? const Icon(Icons.check, color: Color(0xFF2ABFBF)) : null,
              onTap: () async {
                Navigator.pop(ctx);
                await ApiService().patch('/auth/profile/', body: {'theme': 'dark'});
                if (mounted) setState(() => _theme = 'dark');
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showFontSizeDialog() async {
    double value = _fontSize;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Dimensione testo'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${value.toInt()}px', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              Slider(
                value: value,
                min: 12,
                max: 20,
                divisions: 4,
                activeColor: _teal,
                onChanged: (v) => setDialogState(() => value = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annulla'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: _teal, foregroundColor: Colors.white),
              onPressed: () async {
                Navigator.pop(ctx);
                final prefs = await SharedPreferences.getInstance();
                await prefs.setDouble(_fontSizeKey, value);
                if (mounted) setState(() => _fontSize = value);
              },
              child: const Text('Salva'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom + 24;
    return Scaffold(
      backgroundColor: AppColors.backgroundGradient.colors.first,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: Image.asset(
              AppConstants.imgSfondo,
              fit: BoxFit.cover,
            ),
          ),
          SafeArea(
            bottom: true,
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF2ABFBF)))
                : SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(20, 20, 20, bottomPadding),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    const SizedBox(height: 8),
                    // Header
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () => Navigator.of(context).pop(),
                          child: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF1A2B4A), size: 22),
                        ),
                        const Expanded(
                          child: Text(
                            'Impostazioni Chat',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1A2B4A),
                            ),
                          ),
                        ),
                        const SizedBox(width: 22),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 8),
                      child: Text(
                        'Aspetto',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey[600],
                        ),
                      ),
                    ),
                    _buildSection([
                      _buildMenuItem(
                        icon: Icons.palette_outlined,
                        iconColor: _teal,
                        title: 'Tema',
                        trailing: Text(
                          _theme == 'light' ? 'Chiaro' : 'Scuro',
                          style: TextStyle(color: Colors.grey[400], fontSize: 14),
                        ),
                        onTap: _showThemeSheet,
                      ),
                      _buildDivider(),
                      _buildMenuItem(
                        icon: Icons.text_fields_rounded,
                        iconColor: _teal,
                        title: 'Dimensione testo',
                        trailing: Text(
                          '${_fontSize.toInt()}px',
                          style: TextStyle(color: Colors.grey[400], fontSize: 14),
                        ),
                        onTap: _showFontSizeDialog,
                      ),
                    ]),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 8),
                      child: Text(
                        'Notifiche',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey[600],
                        ),
                      ),
                    ),
                    _buildSection([
                      _buildToggleItem(
                        icon: Icons.notifications_outlined,
                        iconColor: _teal,
                        title: 'Suoni notifiche',
                        value: _notificationsEnabled,
                        onChanged: (value) async {
                          setState(() => _notificationsEnabled = value);
                          try {
                            await ApiService().patch(
                              '/auth/profile/notification-settings/',
                              body: {'notifications_enabled': value},
                            );
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: const Text('Impostazione aggiornata'),
                                  backgroundColor: _teal,
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                              );
                            }
                          } catch (e) {
                            if (mounted) setState(() => _notificationsEnabled = !value);
                          }
                        },
                      ),
                    ]),
                    const SizedBox(height: 80),
                      ],
                    ),
                  ),
          ),
        ],
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
    Widget? trailing,
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
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF1A2B4A),
                ),
              ),
            ),
            if (trailing != null) ...[trailing, const SizedBox(width: 8)],
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
            activeTrackColor: _teal.withOpacity(0.3),
            activeThumbColor: _teal,
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
}
