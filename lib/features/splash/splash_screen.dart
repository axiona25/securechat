import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../core/routes/app_router.dart';
import '../../core/services/api_service.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/crypto_service.dart';
import 'widgets/animated_feature_icon.dart';
import 'widgets/dashed_line_painter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // Animation controllers
  late AnimationController _bgController;
  late AnimationController _iconController;
  late AnimationController _textLogoController;
  late AnimationController _subtitleController;
  late AnimationController _feature1Controller;
  late AnimationController _feature2Controller;
  late AnimationController _feature3Controller;
  late AnimationController _dashedLineController;
  late AnimationController _shimmerController;

  // Animations
  late Animation<double> _bgOpacity;
  late Animation<double> _iconSlideDown;
  late Animation<double> _iconScale;
  late Animation<double> _iconOpacity;
  late Animation<double> _textLogoSlideUp;
  late Animation<double> _textLogoOpacity;
  late Animation<double> _subtitleOpacity;
  late Animation<double> _feature1Scale;
  late Animation<double> _feature2Scale;
  late Animation<double> _feature3Scale;
  late Animation<double> _dashedLineProgress;
  late Animation<double> _shimmerPosition;

  @override
  void initState() {
    super.initState();

    // Set status bar to transparent
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ));

    _setupAnimations();
    _startAnimationSequence();
  }

  void _setupAnimations() {
    // 1. Background fade-in (0ms → 600ms)
    _bgController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _bgOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _bgController, curve: Curves.easeIn),
    );

    // 2. Icon slide-down + scale + fade (400ms → 1200ms)
    _iconController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _iconSlideDown = Tween<double>(begin: -60.0, end: 0.0).animate(
      CurvedAnimation(parent: _iconController, curve: Curves.elasticOut),
    );
    _iconScale = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _iconController, curve: Curves.elasticOut),
    );
    _iconOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _iconController,
        curve: const Interval(0.0, 0.4, curve: Curves.easeIn),
      ),
    );

    // 3. Text logo slide-up + fade (800ms → 1400ms)
    _textLogoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _textLogoSlideUp = Tween<double>(begin: 30.0, end: 0.0).animate(
      CurvedAnimation(parent: _textLogoController, curve: Curves.easeOutCubic),
    );
    _textLogoOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _textLogoController, curve: Curves.easeOutCubic),
    );

    // 4. Subtitle fade-in (1200ms → 1800ms)
    _subtitleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _subtitleOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _subtitleController, curve: Curves.easeIn),
    );

    // 5. Feature icons scale-in (1600ms → 2400ms, staggered 200ms)
    _feature1Controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _feature1Scale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _feature1Controller, curve: Curves.elasticOut),
    );

    _feature2Controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _feature2Scale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _feature2Controller, curve: Curves.elasticOut),
    );

    _feature3Controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _feature3Scale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _feature3Controller, curve: Curves.elasticOut),
    );

    // 6. Dashed lines draw animation
    _dashedLineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _dashedLineProgress = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _dashedLineController, curve: Curves.easeInOut),
    );

    // 7. Shimmer effect (continuous loop on icon)
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _shimmerPosition = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(parent: _shimmerController, curve: Curves.easeInOut),
    );
  }

  void _startAnimationSequence() async {
    // 1. Background fade-in at 0ms
    _bgController.forward();

    // 2. Icon at 400ms
    await Future.delayed(const Duration(milliseconds: 400));
    _iconController.forward();

    // 3. Text logo at 800ms
    await Future.delayed(const Duration(milliseconds: 400));
    _textLogoController.forward();

    // 4. Subtitle at 1200ms
    await Future.delayed(const Duration(milliseconds: 400));
    _subtitleController.forward();

    // 5. Feature icons staggered at 1600ms
    await Future.delayed(const Duration(milliseconds: 400));
    _feature1Controller.forward();

    await Future.delayed(const Duration(milliseconds: 200));
    _feature2Controller.forward();

    await Future.delayed(const Duration(milliseconds: 200));
    _feature3Controller.forward();

    // 6. Dashed lines at 2000ms
    await Future.delayed(const Duration(milliseconds: 200));
    _dashedLineController.forward();

    // 7. Shimmer loop starts
    await Future.delayed(const Duration(milliseconds: 400));
    _shimmerController.repeat();

    // 8. Navigate after total ~3500ms (o a home se già autenticato)
    await Future.delayed(const Duration(milliseconds: 1000));
    if (!mounted) return;
    if (AuthService().isLoggedIn) {
      // Utente già autenticato che riapre l'app — inizializza chiavi E2E
      try {
        final cryptoService = CryptoService(
          apiService: ApiService(),
          secureStorage: const FlutterSecureStorage(),
        );
        await cryptoService.initializeKeys();
        debugPrint('[Splash] E2E keys initialized for returning user');
      } catch (e) {
        debugPrint('[Splash] E2E key init error: $e');
      }
      if (mounted) {
        Navigator.of(context).pushReplacementNamed(AppRouter.home);
      }
    } else {
      Navigator.of(context).pushReplacementNamed(AppRouter.login);
    }
  }

  @override
  void dispose() {
    _bgController.dispose();
    _iconController.dispose();
    _textLogoController.dispose();
    _subtitleController.dispose();
    _feature1Controller.dispose();
    _feature2Controller.dispose();
    _feature3Controller.dispose();
    _dashedLineController.dispose();
    _shimmerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      body: Stack(
        children: [
          // ── LAYER 1: Background Image ──
          _buildBackground(),

          // ── LAYER 2: Main Content ──
          SafeArea(
            child: SizedBox(
              width: double.infinity,
              height: double.infinity,
              child: Column(
                children: [
                  SizedBox(height: screenHeight * 0.22),

                  // ── Icon + Shimmer ──
                  _buildAnimatedIcon(),

                  const SizedBox(height: 20),

                  // ── Text Logo ──
                  _buildAnimatedTextLogo(),

                  const SizedBox(height: 16),

                  // ── Subtitle ──
                  _buildAnimatedSubtitle(),

                  const Spacer(),

                  // ── Feature Icons Row ──
                  _buildFeatureIconsRow(screenWidth),

                  SizedBox(height: screenHeight * 0.08),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackground() {
    return AnimatedBuilder(
      animation: _bgOpacity,
      builder: (context, child) {
        return Opacity(
          opacity: _bgOpacity.value,
          child: SizedBox.expand(
            child: Image.asset(
              AppConstants.imgSfondo,
              fit: BoxFit.cover,
            ),
          ),
        );
      },
    );
  }

  Widget _buildAnimatedIcon() {
    return AnimatedBuilder(
      animation: _iconController,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _iconSlideDown.value),
          child: Transform.scale(
            scale: _iconScale.value,
            child: Opacity(
              opacity: _iconOpacity.value,
              child: _buildIconWithShimmer(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildIconWithShimmer() {
    return AnimatedBuilder(
      animation: _shimmerController,
      builder: (context, child) {
        final pos = _shimmerPosition.value.clamp(0.0, 1.0);
        final stopStart = (pos - 0.25).clamp(0.0, 1.0);
        final stopMid = pos;
        final stopEnd = (pos + 0.25).clamp(0.0, 1.0);
        final stops = [stopStart, stopMid, stopEnd]..sort();

        return SizedBox(
          width: 120,
          height: 120,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Icon image
              Image.asset(
                AppConstants.imgIcona,
                width: 110,
                height: 110,
                fit: BoxFit.contain,
              ),

              // Shimmer overlay
              if (_shimmerController.isAnimating)
                ClipRRect(
                  borderRadius: BorderRadius.circular(60),
                  child: ShaderMask(
                    shaderCallback: (rect) {
                      return LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: const [
                          Colors.transparent,
                          AppColors.shimmerHighlight,
                          Colors.transparent,
                        ],
                        stops: stops,
                      ).createShader(rect);
                    },
                    blendMode: BlendMode.srcATop,
                    child: Container(
                      width: 120,
                      height: 120,
                      color: Colors.white.withValues(alpha: 0.3),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAnimatedTextLogo() {
    return AnimatedBuilder(
      animation: _textLogoController,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _textLogoSlideUp.value),
          child: Opacity(
            opacity: _textLogoOpacity.value,
            child: Image.asset(
              AppConstants.imgTestoLogo,
              width: 220,
              fit: BoxFit.contain,
            ),
          ),
        );
      },
    );
  }

  Widget _buildAnimatedSubtitle() {
    return AnimatedBuilder(
      animation: _subtitleController,
      builder: (context, child) {
        return Opacity(
          opacity: _subtitleOpacity.value,
          child: const Text(
            AppConstants.appTagline,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w300,
              color: AppColors.textTertiary,
              letterSpacing: 1.2,
            ),
          ),
        );
      },
    );
  }

  Widget _buildFeatureIconsRow(double screenWidth) {
    final lineWidth = screenWidth * 0.12;

    return SizedBox(
      height: 60,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Feature 1: Lock + Shield
          AnimatedFeatureIcon(
            icon: Icons.lock_outline,
            overlayIcon: Icons.shield_outlined,
            animation: _feature1Scale,
          ),

          // Dashed line 1
          AnimatedBuilder(
            animation: _dashedLineProgress,
            builder: (context, child) {
              return SizedBox(
                width: lineWidth,
                height: 2,
                child: CustomPaint(
                  painter: DashedLinePainter(
                    progress: _dashedLineProgress.value,
                  ),
                ),
              );
            },
          ),

          // Feature 2: Chat bubble
          AnimatedFeatureIcon(
            icon: Icons.chat_bubble_outline,
            animation: _feature2Scale,
          ),

          // Dashed line 2
          AnimatedBuilder(
            animation: _dashedLineProgress,
            builder: (context, child) {
              return SizedBox(
                width: lineWidth,
                height: 2,
                child: CustomPaint(
                  painter: DashedLinePainter(
                    progress: _dashedLineProgress.value,
                  ),
                ),
              );
            },
          ),

          // Feature 3: Verified shield
          AnimatedFeatureIcon(
            icon: Icons.verified_user_outlined,
            animation: _feature3Scale,
          ),
        ],
      ),
    );
  }
}
