import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/routes/app_router.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/crypto_service.dart';
import '../../../core/widgets/securechat_text_field.dart';
import '../../../core/widgets/securechat_button.dart';
import '../../../core/widgets/social_login_button.dart';
import '../../../core/l10n/app_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class LoginForm extends StatefulWidget {
  const LoginForm({super.key});

  @override
  State<LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<LoginForm> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();

  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _errorMessage;

  AppLocalizations get l10n => AppLocalizations.of(context)!;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
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
    if (value.length < 6) {
      return l10n.t('password_min_6');
    }
    return null;
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final result = await AuthService().login(
      email: _emailController.text.trim(),
      password: _passwordController.text,
    );

    if (!mounted) return;

    setState(() => _isLoading = false);

    if (result.success) {
      // Dopo login success, inizializza le chiavi E2E
      try {
        final cryptoService = CryptoService(
          apiService: ApiService(),
          secureStorage: const FlutterSecureStorage(),
        );
        await cryptoService.initializeKeys();
        debugPrint('[Auth] E2E keys initialized');
      } catch (e) {
        debugPrint('[Auth] E2E key init error: $e');
        // Non bloccare il login se le chiavi falliscono
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(AppRouter.home);
    } else {
      final errorMessage = result.error ?? '';
      if (errorMessage.contains('attesa di approvazione') || errorMessage.contains('pending approval')) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.hourglass_empty, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(child: Text(errorMessage, style: const TextStyle(fontWeight: FontWeight.w600))),
              ],
            ),
            backgroundColor: const Color(0xFFFF9800),
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
          ),
        );
      } else {
        setState(() => _errorMessage = errorMessage);
      }
    }
  }

  void _handleForgotPassword() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => _buildForgotPasswordSheet(),
    );
  }

  void _handleGoogleLogin() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.t('google_signin_soon'))),
    );
  }

  void _handleAppleLogin() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.t('apple_signin_soon'))),
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
                border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
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

          const SizedBox(height: 16),

          SecureChatTextField(
            label: l10n.t('password'),
            hint: l10n.t('hint_password'),
            prefixIcon: Icons.lock_outline_rounded,
            obscureText: _obscurePassword,
            controller: _passwordController,
            validator: _validatePassword,
            focusNode: _passwordFocusNode,
            textInputAction: TextInputAction.done,
            onEditingComplete: _handleLogin,
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

          const SizedBox(height: 12),

          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: _handleForgotPassword,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  l10n.t('forgot_password'),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                    decoration: TextDecoration.underline,
                    decorationColor: AppColors.primary,
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 24),

          SecureChatButton(
            text: l10n.t('login'),
            isLoading: _isLoading,
            onPressed: _handleLogin,
          ),

          const SizedBox(height: 28),

          Row(
            children: [
              Expanded(child: Divider(color: AppColors.divider, thickness: 1)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  l10n.t('or_continue_with'),
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textDisabled,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
              Expanded(child: Divider(color: AppColors.divider, thickness: 1)),
            ],
          ),

          const SizedBox(height: 20),

          Row(
            children: [
              SocialLoginButton(
                provider: SocialProvider.google,
                onPressed: _handleGoogleLogin,
              ),
              const SizedBox(width: 14),
              SocialLoginButton(
                provider: SocialProvider.apple,
                onPressed: _handleAppleLogin,
              ),
            ],
          ),

          const SizedBox(height: 28),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                l10n.t('dont_have_account'),
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.textTertiary,
                ),
              ),
              GestureDetector(
                onTap: () {
                  Navigator.of(context).pushNamed(AppRouter.register);
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.t('sign_up'),
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

  Widget _buildForgotPasswordSheet() {
    final emailResetController = TextEditingController();
    bool isSending = false;

    return StatefulBuilder(
      builder: (context, setSheetState) {
        return Padding(
          padding: EdgeInsets.only(
            left: 28,
            right: 28,
            top: 24,
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              Text(
                l10n.t('reset_password'),
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                AppLocalizations.of(context)!.t('reset_password_desc'),
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.textTertiary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),

              SecureChatTextField(
                label: AppLocalizations.of(context)!.t('email'),
                hint: AppLocalizations.of(context)!.t('hint_email'),
                prefixIcon: Icons.mail_outline_rounded,
                controller: emailResetController,
                keyboardType: TextInputType.emailAddress,
              ),

              const SizedBox(height: 24),

              SecureChatButton(
                text: AppLocalizations.of(context)!.t('send_reset_link'),
                showArrow: false,
                isLoading: isSending,
                onPressed: () async {
                  if (emailResetController.text.trim().isEmpty) return;

                  setSheetState(() => isSending = true);

                  final result = await AuthService().requestPasswordReset(
                    email: emailResetController.text.trim(),
                  );

                  setSheetState(() => isSending = false);

                  if (context.mounted) {
                    Navigator.of(context).pop();
                    final l10nSheet = AppLocalizations.of(context)!;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          result.success
                              ? l10nSheet.t('reset_link_sent')
                              : result.error ?? l10nSheet.t('error'),
                        ),
                        backgroundColor:
                            result.success ? AppColors.success : AppColors.error,
                      ),
                    );
                  }
                },
              ),

              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}
