import 'package:flutter/material.dart';

/// Centralized brand colors for both dark and light themes.
/// [UPDATE 2026-06-10-P5] WhatsApp-exact light mode colors
class AppColors {
  // Dark mode — WhatsApp dark
  static const bgDark = Color(0xFF0B141A);
  static const surfaceDark = Color(0xFF111B21);
  static const appBarDark = Color(0xFF1F2C33);

  // Light mode — WhatsApp light (as of 2025/2026)
  static const bgLight = Color(0xFFFFFFFF);
  static const surfaceLight = Color(0xFFFFFFFF);
  static const appBarLight = Color(0xFFFFFFFF); // White app bar like current WhatsApp

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

  // Light mode UI colors (WhatsApp current)
  static const lightScaffoldBg = Color(0xFFEFEFEF); // Chat list bg
  static const lightSurface = Color(0xFFFFFFFF);     // Cards, drawers
  static const lightAppBarTitle = Color(0xFF00A884);  // WhatsApp green title
  static const lightSearchBg = Color(0xFFF0F2F5);     // Search field bg
  static const lightDivider = Color(0xFFE9EDEF);
  static const lightTabSelected = Color(0xFF00A884);  // WhatsApp green selected
  static const lightTabNormal = Color(0xFF667781);

  // Dark mode UI colors
  static const darkScaffoldBg = Color(0xFF0B141A);
  static const darkSurface = Color(0xFF111B21);
  static const darkAppBar = Color(0xFF1F2C33);

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