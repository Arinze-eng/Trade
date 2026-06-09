import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Provides light/dark theme mode switching across the entire app.
/// Used via ChangeNotifierProvider at the root level.
class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.dark;

  ThemeMode get themeMode => _themeMode;
  bool get isDarkMode => _themeMode == ThemeMode.dark;

  void toggleTheme() {
    _themeMode = isDarkMode ? ThemeMode.light : ThemeMode.dark;
    SystemChrome.setSystemUIOverlayStyle(
      isDarkMode
          ? const SystemUiOverlayStyle(
              statusBarIconBrightness: Brightness.dark,
              statusBarBrightness: Brightness.light,
            )
          : const SystemUiOverlayStyle(
              statusBarIconBrightness: Brightness.light,
              statusBarBrightness: Brightness.dark,
            ),
    );
    notifyListeners();
  }

  void setThemeMode(ThemeMode mode) {
    if (_themeMode != mode) {
      _themeMode = mode;
      final isLight = mode == ThemeMode.light;
      SystemChrome.setSystemUIOverlayStyle(
        isLight
            ? const SystemUiOverlayStyle(
                statusBarIconBrightness: Brightness.dark,
                statusBarBrightness: Brightness.light,
              )
            : const SystemUiOverlayStyle(
                statusBarIconBrightness: Brightness.light,
                statusBarBrightness: Brightness.dark,
              ),
      );
      notifyListeners();
    }
  }

  /// Get the light theme for the app
  static ThemeData get lightTheme => ThemeData(
    brightness: Brightness.light,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF7C3AED),
      brightness: Brightness.light,
      surface: const Color(0xFFF8FAFC),
    ),
    scaffoldBackgroundColor: const Color(0xFFF1F5F9),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFFF8FAFC),
      foregroundColor: Color(0xFF1E293B),
      centerTitle: false,
      elevation: 0,
    ),
    cardColor: const Color(0xFFFFFFFF),
    dialogBackgroundColor: const Color(0xFFFFFFFF),
    dividerColor: const Color(0xFFE2E8F0),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF1E293B),
      contentTextStyle: TextStyle(color: Colors.white),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Color(0xFFFFFFFF),
    ),
    drawerTheme: const DrawerThemeData(
      backgroundColor: Color(0xFFFFFFFF),
    ),
  );

  /// Get the dark theme for the app  
  static ThemeData get darkTheme => ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF7C3AED),
      brightness: Brightness.dark,
      surface: const Color(0xFF111827),
    ),
    scaffoldBackgroundColor: const Color(0xFF0B0F17),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      centerTitle: false,
      elevation: 0,
    ),
    cardColor: const Color(0xFF111827),
    dialogBackgroundColor: const Color(0xFF1E293B),
    dividerColor: Colors.white12,
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF1E293B),
      contentTextStyle: TextStyle(color: Colors.white),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Color(0xFF1E293B),
    ),
    drawerTheme: const DrawerThemeData(
      backgroundColor: Color(0xFF0F1F28),
    ),
  );
}