import 'package:flutter/material.dart';

abstract class AppTheme {
  AppTheme._();

  static const Color primary = Color(0xFF0D1117);      // Deep Space / Dark Background
  static const Color secondary = Color(0xFF161B22);    // Soft Dark Slate
  static const Color surface = Color(0xFF0D1117);      // Surface glass base
  static const Color surfaceSoft = Color(0xFF21262D);  // Card background
  static const Color accent = Color(0xFF58A6FF);       // Bright Cobalt Blue
  static const Color accentSoft = Color(0xFF58A6FF);   // Secondary blue accent
  static const Color success = Color(0xFF58A6FF);      // Success cobalt
  static const Color danger = Color(0xFFF85149);       // Vibrant Coral Red
  static const Color warning = Color(0xFFE3B341);      // Warning Gold
  static const Color textPrimary = Color(0xFFC9D1D9);  // Light Silver
  static const Color textSecondary = Color(0xFF8B949E); // Muted Grey
  static const Color overlay = Color(0x13FFFFFF);
  static const Color divider = Color(0x1F58A6FF);      // Cobalt glow-infused border
  static const Color shadow = Color(0x7F000000);       // Deeper ambient dropshadow

  static LinearGradient mainGradient({Alignment begin = Alignment.topLeft, Alignment end = Alignment.bottomRight}) {
    return LinearGradient(
      begin: begin,
      end: end,
      colors: [primary, secondary],
    );
  }

  static LinearGradient surfaceGradient({Alignment begin = Alignment.topLeft, Alignment end = Alignment.bottomRight}) {
    return LinearGradient(
      begin: begin,
      end: end,
      colors: [
        Colors.white.withValues(alpha: 0.04),
        Colors.white.withValues(alpha: 0.01),
      ],
    );
  }

  static BoxDecoration surfaceCardDecoration({Color? baseColor}) {
    return BoxDecoration(
      gradient: surfaceGradient(),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: divider, width: 1.5),
      boxShadow: [
        BoxShadow(
          color: shadow,
          blurRadius: 20,
          spreadRadius: 1,
          offset: const Offset(0, 10),
        ),
        // Liquid glow refraction highlight
        BoxShadow(
          color: accent.withValues(alpha: 0.04),
          blurRadius: 14,
          spreadRadius: -2,
          offset: const Offset(0, -6),
        ),
      ],
    );
  }
}
