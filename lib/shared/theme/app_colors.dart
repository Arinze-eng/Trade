import 'package:flutter/material.dart';

/// Centralized brand colors for both dark and light themes.
/// [UPDATE 2026-06-08] Added light mode variants.
class AppColors {
  // Core — dark mode
  static const bg = Color(0xFF0B0F17);
  static const surface = Color(0xFF111827);
  static const surface2 = Color(0xFF0F172A);

  // Core — light mode
  static const bgLight = Color(0xFFF1F5F9);
  static const surfaceLight = Color(0xFFFFFFFF);
  static const surfaceLight2 = Color(0xFFF8FAFC);

  // Accents (shared)
  static const violet = Color(0xFF7C3AED);
  static const cyan = Color(0xFF22D3EE);
  static const green = Color(0xFF22C55E);
  static const red = Color(0xFFEF4444);

  // WhatsApp-style outgoing bubble colors
  static const outgoingBubbleDark = Color(0xFF075E54);
  static const outgoingBubbleLight = Color(0xFFD9FDD3);

  // Text
  static const textMuted = Color(0xFF94A3B8);
  static const textLight = Color(0xFF1E293B);
  static const textMutedLight = Color(0xFF64748B);

  /// Get background color based on brightness
  static Color bgFor(Brightness b) => b == Brightness.dark ? bg : bgLight;
  /// Get surface color based on brightness
  static Color surfaceFor(Brightness b) => b == Brightness.dark ? surface : surfaceLight;
  /// Get muted text color based on brightness
  static Color textMutedFor(Brightness b) => b == Brightness.dark ? textMuted : textMutedLight;

  static const LinearGradient accentGradient = LinearGradient(
    colors: [violet, cyan],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}