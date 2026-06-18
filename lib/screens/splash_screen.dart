import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';
import '../core/app_theme.dart';
import '../core/app_router.dart';
import '../core/design_system.dart';
import 'lobby_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, this.initError});
  final String? initError;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnim;
  late final Animation<double> _scaleAnim;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnim;

  String? _errorMessage;
  bool _isRetrying = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1800),
      vsync: this,
    );
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeIn),
    );
    _scaleAnim = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.elasticOut),
    );
    _controller.forward();

    _pulseController = AnimationController(
      duration: const Duration(seconds: 4),
      vsync: this,
    )..repeat();
    _pulseAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    
    if (widget.initError != null) {
      _errorMessage = widget.initError;
    } else {
      _signInAndNavigate();
    }
  }

  Future<void> _signInAndNavigate() async {
    setState(() {
      _errorMessage = null;
      _isRetrying = true;
    });

    try {
      // Run the minimum 2 s splash and auth sign-in concurrently.
      final results = await Future.wait<dynamic>([
        Future.delayed(const Duration(seconds: 2)),
        _getOrCreateUser(),
      ]);

      if (!mounted) return;
      final user = results[1] as User?;
      if (user == null) {
        throw Exception("Failed to retrieve Firebase user session.");
      }

      Navigator.pushReplacement(
        context,
        AppRouter.fade(LobbyScreen(userId: user.uid)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _isRetrying = false;
      });
    }
  }

  Future<User?> _getOrCreateUser() async {
    User? user = FirebaseAuth.instance.currentUser;
    user ??= (await FirebaseAuth.instance.signInAnonymously()).user;
    return user;
  }

  @override
  void dispose() {
    _controller.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: AppTheme.mainGradient(),
        ),
        child: Stack(
          children: [
            // Ambient floating glowing orbs (background layer)
            Positioned(
              top: -100,
              left: -50,
              child: Container(
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.accent.withValues(alpha: 0.08),
                ),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 80, sigmaY: 80),
                  child: Container(color: Colors.transparent),
                ),
              ),
            ),
            Positioned(
              bottom: -150,
              right: -50,
              child: Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.thiefAccent.withValues(alpha: 0.06),
                ),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 90, sigmaY: 90),
                  child: Container(color: Colors.transparent),
                ),
              ),
            ),
            
            // Core UI Content
            Center(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) => FadeTransition(
                  opacity: _fadeAnim,
                  child: ScaleTransition(scale: _scaleAnim, child: child),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Multi-layered Breathing & Rotating Tactical Core
                    AnimatedBuilder(
                      animation: _pulseController,
                      builder: (context, _) {
                        return Container(
                          padding: const EdgeInsets.all(28),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [
                                AppTheme.accent.withValues(alpha: 0.15),
                                AppTheme.secondary.withValues(alpha: 0.6),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: AppTheme.accent.withValues(alpha: 0.2 + _pulseAnim.value * 0.15),
                                blurRadius: 30 + _pulseAnim.value * 15,
                                spreadRadius: 1 + _pulseAnim.value * 2,
                              ),
                              BoxShadow(
                                color: AppTheme.thiefAccent.withValues(alpha: 0.08 + _pulseAnim.value * 0.08),
                                blurRadius: 45,
                                offset: const Offset(0, 10),
                              ),
                            ],
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.09),
                              width: 1.5,
                            ),
                          ),
                          child: ClipOval(
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                              child: Transform.rotate(
                                angle: _pulseController.value * 2 * pi,
                                child: Icon(
                                  Icons.gps_fixed_rounded,
                                  size: 80,
                                  color: Color.lerp(Colors.white, AppTheme.accent, 0.3),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 50),
                    
                    // Logo Title with accessible neon dropshadow
                    Shimmer.fromColors(
                      baseColor: AppTheme.textPrimary,
                      highlightColor: AppTheme.accent,
                      period: const Duration(seconds: 3),
                      child: GlowText(
                        'THIEF & POLICE',
                        glowColor: AppTheme.accent,
                        glowRadius: 12,
                        style: AppTheme.bangersStyle(
                          fontSize: 52,
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    
                    // Subtitle
                    Text(
                      'REAL-TIME LOCATION CHASE',
                      style: GoogleFonts.spaceMono(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textSecondary,
                        letterSpacing: 4.0,
                      ),
                    ),
                    const SizedBox(height: 60),
                    
                    // Status / Connection Panel
                    if (_errorMessage == null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.03),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(AppTheme.accent),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _isRetrying ? 'AUTHENTICATING...' : 'LOADING GAME...',
                              style: GoogleFonts.spaceMono(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textSecondary,
                                letterSpacing: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      // Premium Liquid Glass Error Box
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 32),
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: AppTheme.danger.withValues(alpha: 0.35),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.danger.withValues(alpha: 0.08),
                              blurRadius: 20,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(24),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                            child: Column(
                              children: [
                                const Icon(Icons.cloud_off, color: AppTheme.danger, size: 48),
                                const SizedBox(height: 16),
                                Text(
                                  'CONNECTION ERROR',
                                  style: AppTheme.bangersStyle(
                                    fontSize: 22,
                                    letterSpacing: 1,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  _errorMessage!.contains('bad-app-id') || _errorMessage!.contains('FirebaseOptions')
                                      ? 'The Firebase configuration is invalid. Please verify the credentials in lib/firebase_options.dart.'
                                      : _errorMessage!.contains('network') || _errorMessage!.contains('offline') || _errorMessage!.contains('SocketException')
                                          ? 'Network connection failed. Please check your internet connection and try again.'
                                          : 'Setup error details:\n$_errorMessage',
                                  style: AppTheme.bodyMedium.copyWith(fontSize: 12),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 24),
                                NeoGlassButton(
                                  onPressed: _signInAndNavigate,
                                  accentColor: AppTheme.danger,
                                  height: 48,
                                  glowing: true,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Icon(Icons.refresh_rounded, color: Colors.white, size: 18),
                                      const SizedBox(width: 8),
                                      Text(
                                        'RETRY CONNECTION',
                                        style: AppTheme.bangersStyle(
                                          fontSize: 16,
                                          letterSpacing: 0.8,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}