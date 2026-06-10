import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Provides light/dark theme mode switching across the entire app.
/// [UPDATE 2026-06-10-P4] WhatsApp-like colors for both modes across all sections
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

  /// WhatsApp-like light theme
  static ThemeData get lightTheme => ThemeData(
    brightness: Brightness.light,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF075E54),
      brightness: Brightness.light,
      surface: Colors.white,
      primary: const Color(0xFF075E54),
      secondary: const Color(0xFF25D366),
    ),
    scaffoldBackgroundColor: const Color(0xFFF0FAFA),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF075E54),
      foregroundColor: Colors.white,
      centerTitle: false,
      elevation: 0,
    ),
    cardColor: Colors.white,
    dialogBackgroundColor: Colors.white,
    dividerColor: const Color(0xFFE0E0E0),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF323232),
      contentTextStyle: TextStyle(color: Colors.white),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.white,
    ),
    drawerTheme: const DrawerThemeData(
      backgroundColor: Colors.white,
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: Colors.white,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: const Color(0xFF075E54).withOpacity(0.1),
      labelStyle: const TextStyle(color: Color(0xFF075E54)),
    ),
    // WhatsApp green for FABs and primary actions
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Color(0xFF25D366),
      foregroundColor: Colors.white,
    ),
  );

  /// WhatsApp-like dark theme  
  static ThemeData get darkTheme => ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF075E54),
      brightness: Brightness.dark,
      surface: const Color(0xFF111B21),
      primary: const Color(0xFF075E54),
      secondary: const Color(0xFF25D366),
    ),
    scaffoldBackgroundColor: const Color(0xFF0B141A),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF1F2C33),
      foregroundColor: Colors.white,
      centerTitle: false,
      elevation: 0,
    ),
    cardColor: const Color(0xFF1F2C33),
    dialogBackgroundColor: const Color(0xFF1F2C33),
    dividerColor: const Color(0xFF313D45),
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
      backgroundColor: const Color(0xFF075E54).withOpacity(0.2),
      labelStyle: const TextStyle(color: Color(0xFF25D366)),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Color(0xFF25D366),
      foregroundColor: Colors.white,
    ),
  );
}