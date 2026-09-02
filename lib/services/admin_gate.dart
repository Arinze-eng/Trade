import 'package:flutter/foundation.dart';

/// [NEW 2026-09-02] Central gate for the Admin panel.
///
/// Only the owner account (allisonarinze@gmail.com) may see or open the admin
/// panel. This is enforced in two places:
///   1. The hamburger drawer hides the "• Admin" item entirely for everyone
///      else (see ChatListScreen._buildDrawer).
///   2. AdminScreen itself double-checks at build time and shows an access-
///      denied screen if opened by anyone else (deep-link safety).
class AdminGate {
  AdminGate._();

  /// The ONLY email allowed to see the admin panel.
  static const String ownerEmail = 'allisonarinze@gmail.com';

  /// Allow-list of emails with admin access (case-insensitive).
  static const List<String> _allowedEmails = [ownerEmail];

  /// Whether the given email may access the admin panel.
  /// In debug builds, a local override can be enabled via [debugForceEnabled]
  /// so development stays possible — it does nothing in release.
  static bool debugForceEnabled = false;

  static bool isAdmin(String? email) {
    if (kDebugMode && debugForceEnabled) return true;
    final e = (email ?? '').trim().toLowerCase();
    if (e.isEmpty) return false;
    return _allowedEmails.contains(e);
  }
}
