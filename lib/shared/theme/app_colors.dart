import 'package:flutter/material.dart';

/// Centralized brand colors for both dark and light themes.
/// [UPDATE 2026-06-10-WA] WhatsApp-exact light mode — flat, solid colors,
/// no gradients, no glass / blur effects in light mode. Mirrors WhatsApp's
/// 2025/2026 light-theme look so text is always readable.
class AppColors {
  // ───────────────────────────── Dark mode ─────────────────────────────
  static const bgDark = Color(0xFF0B141A);
  static const surfaceDark = Color(0xFF111B21);
  static const appBarDark = Color(0xFF1F2C33);

  // ───────────────────────────── Light mode (WhatsApp 2025/26) ─────────
  // [UPDATE 2026-06-11-SOFT-LIGHT] Reduced light-mode contrast for eye comfort.
  // Pure #FFFFFF on large surfaces strains the eyes; we use a soft, warm
  // off-white instead (the same trick Telegram/WhatsApp use — they are NOT
  // pure white). Text stays dark so readability is unchanged.
  // Chat list / scaffold background — soft off-white instead of pure white
  static const bgLight = Color(0xFFF2F3F5);
  // Chat *room* background — WhatsApp's beige doodle paper (already soft)
  static const chatRoomBgLight = Color(0xFFE9E2D8);
  static const surfaceLight = Color(0xFFF7F8FA);
  static const appBarLight = Color(0xFFF2F3F5);

  // ───────────────────────────── Accents (shared) ──────────────────────
  static const whatsappGreen = Color(0xFF25D366);
  static const whatsappTeal = Color(0xFF075E54);
  static const violet = Color(0xFF7C3AED);
  static const cyan = Color(0xFF22D3EE);

  // ───────────────────────────── Bubble colors ─────────────────────────
  // Outgoing (sent by me)
  static const outgoingBubbleDark = Color(0xFF005C4B);
  static const outgoingBubbleLight = Color(0xFFD9FDD3); // WhatsApp light green

  // Incoming
  static const incomingBubbleDark = Color(0xFF1F2C33);
  static const incomingBubbleLight = Color(0xFFFCFCFB); // soft white (not pure)

  // ───────────────────────────── Text colors ───────────────────────────
  // Light mode message text — DARK so it's always readable on green/white
  static const textLight = Color(0xFF111B21);
  static const textDark = Color(0xFFE9EDEF);
  static const textMutedDark = Color(0xFF8696A0);
  static const textMutedLight = Color(0xFF667781);

  // Light mode UI colors (WhatsApp current) — softened for eye comfort
  static const lightScaffoldBg = Color(0xFFF2F3F5);
  static const lightChatRoomBg = Color(0xFFE9E2D8);
  static const lightSurface = Color(0xFFF7F8FA);
  static const lightAppBarTitle = Color(0xFF008069); // WA dark green title
  static const lightSearchBg = Color(0xFFE8EBED);
  static const lightDivider = Color(0xFFDDE2E5);
  static const lightTabSelected = Color(0xFF008069);
  static const lightTabNormal = Color(0xFF667781);
  static const lightReplyBg = Color(0xFFE8EBED);
  static const lightInputBg = Color(0xFFF7F8FA);
  static const lightBubbleShadow = Color(0x0F000000); // 6% black — subtler shadow

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
  /// Bubble color for outgoing message
  static Color outgoingBubbleFor(Brightness b) => b == Brightness.dark ? outgoingBubbleDark : outgoingBubbleLight;
  /// Bubble color for incoming message
  static Color incomingBubbleFor(Brightness b) => b == Brightness.dark ? incomingBubbleDark : incomingBubbleLight;
  /// Text color on bubble (always dark in light mode for readability)
  static Color bubbleTextFor(Brightness b) => b == Brightness.dark ? Colors.white : textLight;

  static const LinearGradient accentGradient = LinearGradient(
    colors: [violet, cyan],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
