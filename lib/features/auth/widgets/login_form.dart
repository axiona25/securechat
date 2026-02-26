import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/routes/app_router.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/widgets/securechat_text_field.dart';
import '../../../core/widgets/securechat_button.dart';
import '../../../core/widgets/social_login_button.dart';

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
      return 'Please enter your email';
    }
    final emailRegex = RegExp(r'^[\w\.\-\+]+@[\w\-]+\.[\w\-\.]+$');
    if (!emailRegex.hasMatch(value.trim())) {
      return 'Please enter a valid email';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter your password';
    }
    if (value.length < 6) {
      return 'Password must be at least 6 characters';
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
      Navigator.of(context).pushReplacementNamed(AppRouter.home);
    } else {
      setState(() => _errorMessage = result.error);
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
      const SnackBar(content: Text('Google Sign-In coming soon')),
    );
  }

  void _handleAppleLogin() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Apple Sign-In coming soon')),
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
            label: 'Email',
            hint: 'Enter your email',
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
            label: 'Password',
            hint: 'Enter your password',
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
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'Forgot password?',
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
            text: 'Log In',
            isLoading: _isLoading,
            onPressed: _handleLogin,
          ),

          const SizedBox(height: 28),

          Row(
            children: [
              Expanded(child: Divider(color: AppColors.divider, thickness: 1)),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'or continue with',
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
              const Text(
                "Don't have an account? ",
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.textTertiary,
                ),
              ),
              GestureDetector(
                onTap: () {
                  Navigator.of(context).pushNamed(AppRouter.register);
                },
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Sign Up',
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

              const Text(
                'Reset Password',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Enter your email and we\'ll send you a link to reset your password.',
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.textTertiary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),

              SecureChatTextField(
                label: 'Email',
                hint: 'Enter your email',
                prefixIcon: Icons.mail_outline_rounded,
                controller: emailResetController,
                keyboardType: TextInputType.emailAddress,
              ),

              const SizedBox(height: 24),

              SecureChatButton(
                text: 'Send Reset Link',
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
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          result.success
                              ? 'Reset link sent! Check your email.'
                              : result.error ?? 'Something went wrong.',
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
