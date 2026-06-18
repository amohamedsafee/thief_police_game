import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

abstract class AppTheme {
  AppTheme._();

  // Premium Spatial Dark Color Palette
  static const Color primary = Color(0xFF070B12);      // Ultra Deep Space / Black Backdrop
  static const Color secondary = Color(0xFF0F1524);    // Sleek Dark Space Slate
  static const Color surface = Color(0xFF0F1524);      // Surface glass base
  static const Color surfaceSoft = Color(0xFF1E293B);  // Soft Slate Card Base
  
  // High-Contrast Accessible Neon Role Accents
  static const Color accent = Color(0xFF00E5FF);       // Police Tactical Cyan
  static const Color accentSoft = Color(0xFF00B0FF);   // Ocean Accent Blue
  static const Color thiefAccent = Color(0xFF39FF14);  // Thief Cyber Neon Green
  static const Color success = Color(0xFF00E676);      // Success Radiant Green
  static const Color danger = Color(0xFFFF0055);       // Danger Crimson Red
  static const Color warning = Color(0xFFFFB000);      // Tactical Warning Amber
  
  // Accessibility Typography Colors
  static const Color textPrimary = Color(0xFFF1F5F9);  // Ice White / Slate 100
  static const Color textSecondary = Color(0xFF94A3B8); // Cool Slate Grey / Slate 400
  static const Color textMuted = Color(0xFF64748B);     // Muted Grey / Slate 500
  
  static const Color overlay = Color(0x1AFFFFFF);      // Ice Glaze Overlay
  static const Color divider = Color(0x2B00E5FF);      // Cyan glow-infused border
  static const Color shadow = Color(0x99000000);       // Ambient black shadow

  // Typography Scale
  static TextStyle get h1 => GoogleFonts.outfit(
        fontSize: 32,
        fontWeight: FontWeight.bold,
        color: textPrimary,
        letterSpacing: -0.5,
      );

  static TextStyle get h2 => GoogleFonts.outfit(
        fontSize: 24,
        fontWeight: FontWeight.bold,
        color: textPrimary,
        letterSpacing: -0.2,
      );

  static TextStyle get h3 => GoogleFonts.outfit(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      );

  static TextStyle get bodyLarge => GoogleFonts.outfit(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: textPrimary,
      );

  static TextStyle get bodyMedium => GoogleFonts.outfit(
        fontSize: 14,
        fontWeight: FontWeight.normal,
        color: textSecondary,
      );

  static TextStyle get bodySmall => GoogleFonts.outfit(
        fontSize: 12,
        fontWeight: FontWeight.normal,
        color: textMuted,
      );

  static TextStyle get mono => GoogleFonts.spaceMono(
        fontSize: 14,
        fontWeight: FontWeight.bold,
        color: textPrimary,
      );

  static TextStyle bangersStyle({required double fontSize, double letterSpacing = 0, Color color = textPrimary}) {
    return GoogleFonts.bangers(
      fontSize: fontSize,
      letterSpacing: letterSpacing,
      color: color,
    );
  }

  // Gradients
  static LinearGradient mainGradient({Alignment begin = Alignment.topLeft, Alignment end = Alignment.bottomRight}) {
    return LinearGradient(
      begin: begin,
      end: end,
      colors: [primary, Color(0xFF0B1220), secondary],
    );
  }

  static LinearGradient surfaceGradient({Alignment begin = Alignment.topLeft, Alignment end = Alignment.bottomRight}) {
    return LinearGradient(
      begin: begin,
      end: end,
      colors: [
        Colors.white.withValues(alpha: 0.07),
        Colors.white.withValues(alpha: 0.02),
      ],
    );
  }

  static BoxDecoration surfaceCardDecoration({Color? baseColor, double borderRadius = 24}) {
    return BoxDecoration(
      gradient: surfaceGradient(),
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 1.5),
      boxShadow: [
        BoxShadow(
          color: shadow,
          blurRadius: 24,
          spreadRadius: -2,
          offset: const Offset(0, 12),
        ),
        // Liquid glow refraction highlight
        BoxShadow(
          color: accent.withValues(alpha: 0.03),
          blurRadius: 16,
          spreadRadius: -4,
          offset: const Offset(0, -6),
        ),
      ],
    );
  }
}

