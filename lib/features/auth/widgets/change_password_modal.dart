import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/crypto_service.dart';
import '../../../core/l10n/app_localizations.dart';

class ChangePasswordModal extends StatefulWidget {
  final VoidCallback onPasswordChanged;

  const ChangePasswordModal({Key? key, required this.onPasswordChanged}) : super(key: key);

  @override
  State<ChangePasswordModal> createState() => _ChangePasswordModalState();
}

class _ChangePasswordModalState extends State<ChangePasswordModal> {
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _loading = false;
  String? _error;

  AppLocalizations get l10n => AppLocalizations.of(context)!;

  @override
  void dispose() {
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _changePassword() async {
    final newPassword = _newPasswordController.text.trim();
    final confirmPassword = _confirmPasswordController.text.trim();

    if (newPassword.isEmpty || confirmPassword.isEmpty) {
      setState(() => _error = l10n.t('fill_both_fields'));
      return;
    }
    if (newPassword.length < 8) {
      setState(() => _error = l10n.t('password_min_8'));
      return;
    }
    if (newPassword != confirmPassword) {
      setState(() => _error = l10n.t('passwords_dont_match'));
      return;
    }

    setState(() { _loading = true; _error = null; });

    try {
      final api = ApiService();
      final token = api.accessToken;

      final response = await http.post(
        Uri.parse('${AppConstants.baseUrl}/auth/change-password/'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'new_password': newPassword,
          'confirm_password': confirmPassword,
        }),
      );

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200) {
        if (data['access'] != null && data['refresh'] != null) {
          api.setTokens(access: data['access'] as String, refresh: data['refresh'] as String);
        }
        final prefs = await SharedPreferences.getInstance();
        if (data['access'] != null) prefs.setString('access_token', data['access'] as String);
        if (data['refresh'] != null) prefs.setString('refresh_token', data['refresh'] as String);
        // Ensure E2E keys are initialized after password change
        // (idempotent — safe if keys already exist, covers the case where
        // initializeKeys() in AuthService.login() failed silently)
        try {
          debugPrint('[ChangePassword] Ensuring crypto keys after password change...');
          final keysOk = await CryptoService(apiService: api).initializeKeys();
          debugPrint('[ChangePassword] Crypto init result: $keysOk');
        } catch (e) {
          debugPrint('[ChangePassword] Crypto init after password change failed: $e');
        }
        if (mounted) widget.onPasswordChanged();
      } else {
        setState(() => _error = data['error']?.toString() ?? l10n.t('error_change_password'));
      }
    } catch (e) {
      setState(() => _error = l10n.t('error_connection'));
    }

    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF2ABFBF), Color(0xFF1FA3A3)],
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(Icons.lock_outline, color: Colors.white, size: 28),
                ),
              ),
              const SizedBox(height: 20),
              Center(
                child: Text(
                  l10n.t('change_password'),
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF1A2B3C)),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  l10n.t('change_password_desc'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, color: Color(0xFF7B8794), height: 1.4),
                ),
              ),
              const SizedBox(height: 24),

              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFEBEE),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Color(0xFFEF5350), size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_error!, style: const TextStyle(color: Color(0xFFEF5350), fontSize: 13, fontWeight: FontWeight.w500)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              Text(l10n.t('new_password_label'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF7B8794), letterSpacing: 0.5)),
              const SizedBox(height: 6),
              TextField(
                controller: _newPasswordController,
                obscureText: _obscureNew,
                decoration: InputDecoration(
                  hintText: l10n.t('hint_new_password'),
                  hintStyle: const TextStyle(color: Color(0xFFB0BEC5), fontSize: 14),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE8ECF0))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE8ECF0))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2ABFBF), width: 2)),
                  suffixIcon: IconButton(
                    icon: Icon(_obscureNew ? Icons.visibility_off : Icons.visibility, color: const Color(0xFF7B8794)),
                    onPressed: () => setState(() => _obscureNew = !_obscureNew),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              Text(l10n.t('confirm_password_label'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF7B8794), letterSpacing: 0.5)),
              const SizedBox(height: 6),
              TextField(
                controller: _confirmPasswordController,
                obscureText: _obscureConfirm,
                decoration: InputDecoration(
                  hintText: l10n.t('hint_confirm_new_password'),
                  hintStyle: const TextStyle(color: Color(0xFFB0BEC5), fontSize: 14),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE8ECF0))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE8ECF0))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2ABFBF), width: 2)),
                  suffixIcon: IconButton(
                    icon: Icon(_obscureConfirm ? Icons.visibility_off : Icons.visibility, color: const Color(0xFF7B8794)),
                    onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.t('min_8_chars'),
                style: const TextStyle(fontSize: 12, color: Color(0xFF7B8794)),
              ),
              const SizedBox(height: 24),

              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _loading ? null : _changePassword,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2ABFBF),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                  child: _loading
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                      : Text(l10n.t('save_new_password'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
