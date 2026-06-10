import 'package:flutter/material.dart';

/// Centralized brand colors for both dark and light themes.
/// [UPDATE 2026-06-10-P4] WhatsApp-like colors for both modes
class AppColors {
  // Dark mode — WhatsApp dark
  static const bgDark = Color(0xFF0B141A);
  static const surfaceDark = Color(0xFF111B21);
  static const appBarDark = Color(0xFF1F2C33);

  // Light mode — WhatsApp light
  static const bgLight = Color(0xFFF0FAFA);
  static const surfaceLight = Color(0xFFFFFFFF);
  static const appBarLight = Color(0xFF075E54);

  // Accents (shared)
  static const whatsappGreen = Color(0xFF25D366);
  static const whatsappTeal = Color(0xFF075E54);
  static const violet = Color(0xFF7C3AED);
  static const cyan = Color(0xFF22D3EE);

  // Outgoing bubble colors (WhatsApp-style)
  static const outgoingBubbleDark = Color(0xFF005C4B);
  static const outgoingBubbleLight = Color(0xFFD9FDD3);

  // Incoming bubble colors
  static const incomingBubbleDark = Color(0xFF1F2C33);
  static const incomingBubbleLight = Color(0xFFFFFFFF);

  // Text
  static const textLight = Color(0xFF1E293B);
  static const textDark = Color(0xFFE9EDEF);
  static const textMutedDark = Color(0xFF8696A0);
  static const textMutedLight = Color(0xFF667781);

  /// Get background color based on brightness
  static Color bgFor(Brightness b) => b == Brightness.dark ? bgDark : bgLight;
  /// Get surface color based on brightness
  static Color surfaceFor(Brightness b) => b == Brightness.dark ? surfaceDark : surfaceLight;
  /// Get muted text color based on brightness
  static Color textMutedFor(Brightness b) => b == Brightness.dark ? textMutedDark : textMutedLight;
  /// Get app bar color based on brightness
  static Color appBarFor(Brightness b) => b == Brightness.dark ? appBarDark : appBarLight;

  static const LinearGradient accentGradient = LinearGradient(
    colors: [violet, cyan],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}