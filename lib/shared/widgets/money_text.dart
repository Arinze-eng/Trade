import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// [UPDATE 2026-06-11-NAIRA] Currency rendering helper.
///
/// The Naira sign ₦ (U+20A6) is NOT present in the Poppins glyph set bundled
/// by `google_fonts`, so anywhere we drew "₦123" with Poppins it rendered as a
/// tofu box (□). This helper renders the ₦ sign with a font that DOES contain
/// it (Roboto / system fallback) while keeping the digits in the requested
/// style, so the whole app shows a proper Naira sign in both light and dark
/// mode.
class Money {
  /// Build a TextStyle whose fallback chain guarantees the ₦ glyph resolves.
  static TextStyle style({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
    double? letterSpacing,
  }) {
    return GoogleFonts.poppins(
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      letterSpacing: letterSpacing,
    ).copyWith(
      // These fonts ship with Android/iOS and contain ₦ (U+20A6).
      fontFamilyFallback: const ['Roboto', 'NotoSans', 'sans-serif'],
    );
  }

  /// A formatted amount widget like "₦1,234.50".
  static Widget text(
    String amountText, {
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
    TextAlign? textAlign,
  }) {
    return Text(
      amountText,
      textAlign: textAlign,
      style: style(color: color, fontSize: fontSize, fontWeight: fontWeight),
    );
  }
}
