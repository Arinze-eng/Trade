import 'package:supabase_flutter/supabase_flutter.dart';

/// Small helper utilities for Supabase auth flows.
abstract final class AuthHelpers {
  static bool isEmailNotConfirmed(Object e) {
    if (e is AuthException) {
      final msg = e.message.toLowerCase();
      return msg.contains('email not confirmed') ||
          (msg.contains('confirm') && msg.contains('email'));
    }
    final msg = e.toString().toLowerCase();
    return msg.contains('email not confirmed') || (msg.contains('confirm') && msg.contains('email'));
  }

  static bool isAlreadyRegistered(Object e) {
    if (e is AuthException) {
      final msg = e.message.toLowerCase();
      return msg.contains('already registered') || msg.contains('user already registered');
    }
    final msg = e.toString().toLowerCase();
    return msg.contains('already registered') || msg.contains('user already registered');
  }
}
