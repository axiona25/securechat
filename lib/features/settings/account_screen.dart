import 'package:flutter/material.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_colors.dart';
import '../../core/services/api_service.dart';
import '../../core/services/profile_cache_service.dart';
import '../auth/widgets/change_password_modal.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  Map<String, dynamic>? _profile;
  bool _loading = true;

  static const Color _teal = Color(0xFF2ABFBF);
  static const Color _navy = Color(0xFF1A2B4A);

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    // Carica dalla cache immediatamente
    final cached = await ProfileCacheService.instance.load();
    if (cached != null && _profile == null && mounted) {
      setState(() {
        _profile = cached;
        _loading = false;
      });
    }

    // Poi prova a caricare dal server
    try {
      final response = await ApiService().get('/auth/profile/');
      if (response != null && response is Map<String, dynamic> && mounted) {
        setState(() {
          _profile = response;
          _loading = false;
        });
        await ProfileCacheService.instance.save(response);
      } else if (mounted) {
        setState(() => _loading = false);
      }
    } catch (e) {
      debugPrint('Errore caricamento profilo (keeping cached data): $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _editField(String label, String key, String currentValue) async {
    final controller = TextEditingController(text: currentValue);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Modifica $label'),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          autofocus: true,
          onSubmitted: (_) => Navigator.pop(ctx, controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annulla'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _teal, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Salva'),
          ),
        ],
      ),
    );
    if (result == null || result == currentValue || !mounted) return;
    try {
      await ApiService().patch('/auth/profile/', body: {key: result});
      if (mounted) {
        setState(() => _profile = {...?_profile, key: result});
        if (_profile != null) {
          await ProfileCacheService.instance.save(_profile!);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$label aggiornato'),
            backgroundColor: _teal,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Errore: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    }
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
                            'Account',
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
                        'Profilo',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey[600],
                        ),
                      ),
                    ),
                    _buildSection([
                      _buildMenuItem(
                        icon: Icons.person_outline_rounded,
                        iconColor: _teal,
                        title: 'Nome',
                        trailing: Text(
                          _profile?['first_name']?.toString() ?? '',
                          style: TextStyle(color: Colors.grey[400], fontSize: 14),
                        ),
                        onTap: () => _editField('Nome', 'first_name', _profile?['first_name']?.toString() ?? ''),
                      ),
                      _buildDivider(),
                      _buildMenuItem(
                        icon: Icons.badge_outlined,
                        iconColor: _teal,
                        title: 'Cognome',
                        trailing: Text(
                          _profile?['last_name']?.toString() ?? '',
                          style: TextStyle(color: Colors.grey[400], fontSize: 14),
                        ),
                        onTap: () => _editField('Cognome', 'last_name', _profile?['last_name']?.toString() ?? ''),
                      ),
                      _buildDivider(),
                      _buildMenuItem(
                        icon: Icons.lock_outline,
                        iconColor: _teal,
                        title: 'Cambia password',
                        onTap: () {
                          showDialog(
                            context: context,
                            barrierDismissible: true,
                            builder: (_) => ChangePasswordModal(
                              onPasswordChanged: () => Navigator.of(context).pop(),
                            ),
                          );
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

  Widget _buildDivider() {
    return Padding(
      padding: const EdgeInsets.only(left: 66),
      child: Divider(height: 1, color: Colors.grey[200]),
    );
  }
}
