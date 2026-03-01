import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../core/widgets/feature_icons_row.dart';
import '../../core/l10n/app_localizations.dart';
import 'widgets/login_form.dart';

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ));

    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.asset(
              AppConstants.imgSfondo,
              fit: BoxFit.cover,
            ),
          ),

          SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: screenHeight -
                      MediaQuery.of(context).padding.top -
                      MediaQuery.of(context).padding.bottom,
                ),
                child: IntrinsicHeight(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      children: [
                        SizedBox(height: screenHeight * 0.06),

                        Image.asset(
                          AppConstants.imgTestoLogo,
                          width: 200,
                          fit: BoxFit.contain,
                        ),

                        const SizedBox(height: 8),

                        SizedBox(height: screenHeight * 0.03),

                        Text(
                          AppLocalizations.of(context)!.t('welcome_back'),
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                            letterSpacing: -0.5,
                          ),
                        ),

                        const SizedBox(height: 6),

                        Text(
                          AppLocalizations.of(context)!.t('login_subtitle'),
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w400,
                            color: AppColors.textTertiary,
                          ),
                        ),

                        SizedBox(height: screenHeight * 0.035),

                        const LoginForm(),

                        const Spacer(),

                        const Padding(
                          padding: EdgeInsets.only(bottom: 20),
                          child: FeatureIconsRow(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
