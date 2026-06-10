import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../shared/theme/app_colors.dart';

/// Provides light/dark theme mode switching across the entire app.
/// [UPDATE 2026-06-10-P5] WhatsApp-exact light mode — white surfaces, green accents only where WhatsApp uses them
class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.dark;

  ThemeMode get themeMode => _themeMode;
  bool get isDarkMode => _themeMode == ThemeMode.dark;

  void toggleTheme() {
    _themeMode = isDarkMode ? ThemeMode.light : ThemeMode.dark;
    _updateStatusBar();
    notifyListeners();
  }

  void setThemeMode(ThemeMode mode) {
    if (_themeMode != mode) {
      _themeMode = mode;
      _updateStatusBar();
      notifyListeners();
    }
  }

  void _updateStatusBar() {
    SystemChrome.setSystemUIOverlayStyle(
      isDarkMode
          ? const SystemUiOverlayStyle(
              statusBarIconBrightness: Brightness.light,
              statusBarBrightness: Brightness.dark,
            )
          : const SystemUiOverlayStyle(
              statusBarIconBrightness: Brightness.dark,
              statusBarBrightness: Brightness.light,
            ),
    );
  }

  /// WhatsApp-exact light theme (2025/2026 current design)
  static ThemeData get lightTheme => ThemeData(
    brightness: Brightness.light,
    useMaterial3: true,
    // [UPDATE 2026-06-11-NAIRA] Guarantee the ₦ (U+20A6) glyph resolves
    // app-wide. Poppins lacks it, so without a fallback it renders as a tofu
    // box. Roboto/Noto (bundled on Android/iOS) contain it.
    fontFamilyFallback: const ['Roboto', 'NotoSans', 'sans-serif'],
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.lightTabSelected,
      brightness: Brightness.light,
      surface: AppColors.lightSurface,
      primary: AppColors.lightTabSelected,
      secondary: AppColors.whatsappGreen,
    ),
    scaffoldBackgroundColor: AppColors.lightScaffoldBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.lightSurface,
      foregroundColor: AppColors.textLight,
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    cardColor: AppColors.lightSurface,
    dialogBackgroundColor: AppColors.lightSurface,
    dividerColor: AppColors.lightDivider,
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF323232),
      contentTextStyle: TextStyle(color: Colors.white),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.lightSurface,
    ),
    drawerTheme: const DrawerThemeData(
      backgroundColor: AppColors.lightSurface,
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: AppColors.lightSurface,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.lightTabSelected.withOpacity(0.1),
      labelStyle: const TextStyle(color: AppColors.lightTabSelected),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: AppColors.whatsappGreen,
      foregroundColor: Colors.white,
    ),
    // WhatsApp uses a very light grey for the chat list tile backgrounds
    // The divider is very subtle
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.lightDivider,
      thickness: 0.5,
      space: 0,
    ),
    // Text theme for readability
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: AppColors.textLight),
      bodyMedium: TextStyle(color: AppColors.textLight),
      bodySmall: TextStyle(color: AppColors.textMutedLight),
    ),
  );

  /// WhatsApp-like dark theme
  static ThemeData get darkTheme => ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    // [UPDATE 2026-06-11-NAIRA] Same ₦ glyph fallback for dark mode.
    fontFamilyFallback: const ['Roboto', 'NotoSans', 'sans-serif'],
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.whatsappTeal,
      brightness: Brightness.dark,
      surface: AppColors.surfaceDark,
      primary: AppColors.whatsappTeal,
      secondary: AppColors.whatsappGreen,
    ),
    scaffoldBackgroundColor: AppColors.bgDark,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.appBarDark,
      foregroundColor: Colors.white,
      centerTitle: false,
      elevation: 0,
    ),
    cardColor: AppColors.appBarDark,
    dialogBackgroundColor: AppColors.appBarDark,
    dividerColor: Color(0xFF313D45),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF1F2C33),
      contentTextStyle: TextStyle(color: Colors.white),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Color(0xFF1F2C33),
    ),
    drawerTheme: const DrawerThemeData(
      backgroundColor: Color(0xFF111B21),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: Color(0xFF1F2C33),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.whatsappTeal.withOpacity(0.2),
      labelStyle: const TextStyle(color: Color(0xFF25D366)),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Color(0xFF25D366),
      foregroundColor: Colors.white,
    ),
  );
}