import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/routes/app_router.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/crypto_service.dart';
import '../../../core/widgets/securechat_text_field.dart';
import '../../../core/widgets/securechat_button.dart';
import '../../../core/l10n/app_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class RegisterForm extends StatefulWidget {
  const RegisterForm({super.key});

  @override
  State<RegisterForm> createState() => _RegisterFormState();
}

class _RegisterFormState extends State<RegisterForm> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  final _fullNameFocusNode = FocusNode();
  final _emailFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  final _confirmPasswordFocusNode = FocusNode();

  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _isLoading = false;
  String? _errorMessage;

  AppLocalizations get l10n => AppLocalizations.of(context)!;

  @override
  void dispose() {
    _fullNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _fullNameFocusNode.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    _confirmPasswordFocusNode.dispose();
    super.dispose();
  }

  String? _validateFullName(String? value) {
    if (value == null || value.trim().isEmpty) {
      return l10n.t('full_name_required');
    }
    if (value.trim().length < 2) {
      return l10n.t('name_min_2');
    }
    return null;
  }

  String? _validateEmail(String? value) {
    if (value == null || value.trim().isEmpty) {
      return l10n.t('email_required');
    }
    final emailRegex = RegExp(r'^[\w\.\-\+]+@[\w\-]+\.[\w\-\.]+$');
    if (!emailRegex.hasMatch(value.trim())) {
      return l10n.t('email_invalid');
    }
    return null;
  }

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return l10n.t('password_required');
    }
    if (value.length < 8) {
      return l10n.t('password_min_8');
    }
    if (!RegExp(r'[A-Z]').hasMatch(value)) {
      return l10n.t('password_uppercase');
    }
    if (!RegExp(r'[0-9]').hasMatch(value)) {
      return l10n.t('password_number');
    }
    return null;
  }

  String? _validateConfirmPassword(String? value) {
    if (value == null || value.isEmpty) {
      return l10n.t('confirm_password_required');
    }
    if (value != _passwordController.text) {
      return l10n.t('passwords_dont_match');
    }
    return null;
  }

  Future<void> _handleRegister() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final result = await AuthService().register(
      fullName: _fullNameController.text.trim(),
      email: _emailController.text.trim(),
      password: _passwordController.text,
      passwordConfirm: _confirmPasswordController.text,
    );

    if (!mounted) return;

    setState(() => _isLoading = false);

    if (result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text('${l10n.t('registration_success')} ${l10n.t('redirect_to_login')}', style: const TextStyle(fontWeight: FontWeight.w600))),
            ],
          ),
          backgroundColor: Color(0xFF2ABFBF),
          duration: Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
        ),
      );
      await Future.delayed(const Duration(seconds: 3));
      if (mounted) {
        Navigator.of(context).pushReplacementNamed(AppRouter.login);
      }
    } else {
      setState(() => _errorMessage = result.error);
    }
  }

  void _openTermsOfService() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.t('terms_coming_soon'))),
    );
  }

  void _openPrivacyPolicy() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.t('privacy_coming_soon'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_errorMessage != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.error.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: AppColors.error, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: AppColors.error,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          SecureChatTextField(
            label: l10n.t('full_name'),
            hint: l10n.t('hint_full_name'),
            prefixIcon: Icons.person_outline_rounded,
            controller: _fullNameController,
            keyboardType: TextInputType.name,
            validator: _validateFullName,
            focusNode: _fullNameFocusNode,
            textInputAction: TextInputAction.next,
            onEditingComplete: () => _emailFocusNode.requestFocus(),
          ),

          const SizedBox(height: 14),

          SecureChatTextField(
            label: l10n.t('email'),
            hint: l10n.t('hint_email'),
            prefixIcon: Icons.mail_outline_rounded,
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            validator: _validateEmail,
            focusNode: _emailFocusNode,
            textInputAction: TextInputAction.next,
            onEditingComplete: () => _passwordFocusNode.requestFocus(),
          ),

          const SizedBox(height: 14),

          SecureChatTextField(
            label: l10n.t('password'),
            hint: l10n.t('password_min_8'),
            prefixIcon: Icons.lock_outline_rounded,
            obscureText: _obscurePassword,
            controller: _passwordController,
            validator: _validatePassword,
            focusNode: _passwordFocusNode,
            textInputAction: TextInputAction.next,
            onEditingComplete: () => _confirmPasswordFocusNode.requestFocus(),
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: AppColors.textTertiary,
                size: 22,
              ),
              onPressed: () {
                setState(() => _obscurePassword = !_obscurePassword);
              },
            ),
          ),

          const SizedBox(height: 14),

          SecureChatTextField(
            label: l10n.t('confirm_password'),
            hint: l10n.t('hint_confirm_password'),
            prefixIcon: Icons.lock_outline_rounded,
            obscureText: _obscureConfirmPassword,
            controller: _confirmPasswordController,
            validator: _validateConfirmPassword,
            focusNode: _confirmPasswordFocusNode,
            textInputAction: TextInputAction.done,
            onEditingComplete: _handleRegister,
            suffixIcon: IconButton(
              icon: Icon(
                _obscureConfirmPassword
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: AppColors.textTertiary,
                size: 22,
              ),
              onPressed: () {
                setState(() => _obscureConfirmPassword = !_obscureConfirmPassword);
              },
            ),
          ),

          const SizedBox(height: 16),

          RichText(
            text: TextSpan(
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textTertiary,
                height: 1.5,
              ),
              children: [
                TextSpan(text: l10n.t('terms_agreement')),
                TextSpan(
                  text: l10n.t('terms_of_service'),
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.underline,
                    decorationColor: AppColors.primary,
                  ),
                  recognizer: TapGestureRecognizer()..onTap = _openTermsOfService,
                ),
                TextSpan(text: '\n${l10n.t('and')}'),
                TextSpan(
                  text: l10n.t('privacy_policy'),
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.underline,
                    decorationColor: AppColors.primary,
                  ),
                  recognizer: TapGestureRecognizer()..onTap = _openPrivacyPolicy,
                ),
                const TextSpan(text: '.'),
              ],
            ),
          ),

          const SizedBox(height: 24),

          SecureChatButton(
            text: l10n.t('sign_up'),
            isLoading: _isLoading,
            onPressed: _handleRegister,
          ),

          const SizedBox(height: 28),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                l10n.t('already_have_account'),
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.textTertiary,
                ),
              ),
              GestureDetector(
                onTap: () {
                  Navigator.of(context).pop();
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.t('login'),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                        decoration: TextDecoration.underline,
                        decorationColor: AppColors.primary,
                      ),
                    ),
                    SizedBox(width: 4),
                    Icon(
                      Icons.arrow_forward_rounded,
                      size: 16,
                      color: AppColors.primary,
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),
        ],
      ),
    );
  }
}
