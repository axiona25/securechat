import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/routes/app_router.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/widgets/securechat_text_field.dart';
import '../../../core/widgets/securechat_button.dart';

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
      return 'Please enter your full name';
    }
    if (value.trim().length < 2) {
      return 'Name must be at least 2 characters';
    }
    return null;
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
      return 'Please create a password';
    }
    if (value.length < 8) {
      return 'Password must be at least 8 characters';
    }
    if (!RegExp(r'[A-Z]').hasMatch(value)) {
      return 'Password must contain an uppercase letter';
    }
    if (!RegExp(r'[0-9]').hasMatch(value)) {
      return 'Password must contain a number';
    }
    return null;
  }

  String? _validateConfirmPassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please confirm your password';
    }
    if (value != _passwordController.text) {
      return 'Passwords do not match';
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
      Navigator.of(context).pushReplacementNamed(AppRouter.home);
    } else {
      setState(() => _errorMessage = result.error);
    }
  }

  void _openTermsOfService() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Terms of Service — coming soon')),
    );
  }

  void _openPrivacyPolicy() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Privacy Policy — coming soon')),
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
            label: 'Full Name',
            hint: 'Enter your full name',
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

          const SizedBox(height: 14),

          SecureChatTextField(
            label: 'Password',
            hint: 'Create a password',
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
            label: 'Confirm Password',
            hint: 'Confirm your password',
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
                const TextSpan(text: 'By signing up, you agree to the '),
                TextSpan(
                  text: 'Terms of Service',
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.underline,
                    decorationColor: AppColors.primary,
                  ),
                  recognizer: TapGestureRecognizer()..onTap = _openTermsOfService,
                ),
                const TextSpan(text: '\nand '),
                TextSpan(
                  text: 'Privacy Policy',
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
            text: 'Sign Up',
            isLoading: _isLoading,
            onPressed: _handleRegister,
          ),

          const SizedBox(height: 28),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Already have an account? ',
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.textTertiary,
                ),
              ),
              GestureDetector(
                onTap: () {
                  Navigator.of(context).pop();
                },
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Log In',
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
