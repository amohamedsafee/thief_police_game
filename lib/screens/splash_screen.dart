import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';
import '../core/app_theme.dart';
import '../core/app_router.dart';
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
        child: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => FadeTransition(
              opacity: _fadeAnim,
              child: ScaleTransition(scale: _scaleAnim, child: child),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, _) {
                    return Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: [
                            AppTheme.accent,
                            AppTheme.secondary,
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.accent.withValues(alpha: 0.25 + _pulseAnim.value * 0.15),
                            blurRadius: 25 + _pulseAnim.value * 15,
                            spreadRadius: 1 + _pulseAnim.value * 2,
                          ),
                          BoxShadow(
                            color: AppTheme.danger.withValues(alpha: 0.10 + _pulseAnim.value * 0.1),
                            blurRadius: 40,
                            offset: const Offset(0, 10),
                          ),
                        ],
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.12),
                          width: 1.5,
                        ),
                      ),
                      child: Transform.rotate(
                        angle: _pulseController.value * 2 * pi,
                        child: const Icon(
                          Icons.gps_fixed_rounded,
                          size: 90,
                          color: Colors.white,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 40),
                Shimmer.fromColors(
                  baseColor: AppTheme.textPrimary,
                  highlightColor: AppTheme.accent,
                  child: Text(
                    'THIEF & POLICE',
                    style: GoogleFonts.bangers(
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      shadows: [
                        Shadow(
                          offset: const Offset(2, 2),
                          blurRadius: 4,
                          color: Colors.black.withValues(alpha: 0.5),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'REAL-TIME LOCATION CHASE',
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textSecondary,
                    letterSpacing: 3.0,
                  ),
                ),
                const SizedBox(height: 40),
                if (_errorMessage == null) ...[
                  CircularProgressIndicator(
                    valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.accent),
                    backgroundColor: Colors.white.withValues(alpha: 0.05),
                    strokeWidth: 3.5,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _isRetrying ? 'Authenticating...' : 'Loading Game...',
                    style: GoogleFonts.poppins(
                      fontSize: 14,
                      color: Colors.white60,
                    ),
                  ),
                ] else ...[
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.all(20),
                    decoration: AppTheme.surfaceCardDecoration(),
                    child: Column(
                      children: [
                        const Icon(Icons.cloud_off, color: Colors.redAccent, size: 44),
                        const SizedBox(height: 12),
                        Text(
                          'CONNECTION / CONFIG ERROR',
                          style: GoogleFonts.bangers(
                            fontSize: 18,
                            color: Colors.white,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _errorMessage!.contains('bad-app-id') || _errorMessage!.contains('FirebaseOptions')
                              ? 'The Firebase configuration is invalid or missing the correct Android App credentials in lib/firebase_options.dart. Please run "flutterfire configure" or manually update it.'
                              : _errorMessage!.contains('network') || _errorMessage!.contains('offline') || _errorMessage!.contains('SocketException')
                                  ? 'Network connection failed. Please check your internet connection and try again.'
                                  : 'Setup error details:\n$_errorMessage',
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        ElevatedButton.icon(
                          onPressed: _signInAndNavigate,
                          icon: const Icon(Icons.refresh, color: AppTheme.primary),
                          label: Text(
                            'RETRY CONNECTION',
                            style: GoogleFonts.bangers(
                              fontSize: 16,
                              color: AppTheme.primary,
                              letterSpacing: 1,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.accentSoft,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}