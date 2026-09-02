import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/auth/screens/login_screen.dart';
import '../services/supabase_service.dart';
import '../services/vpn_manager.dart';
import 'main_shell.dart';

/// [REWRITE 2026-09-02] WhatsApp-style auth gate (ported from cdnNetChat).
///
/// Previous behavior (broken): the shell only appeared after a successful
/// `getProfile()` network round-trip — so whenever Supabase was slow or down,
/// users were stuck on a blank/brown screen with a spinner and chat NEVER
/// loaded.
///
/// New behavior:
///   1. Auth state is read SYNCHRONOUSLY from the locally persisted session.
///      If a session exists → render MainShell IMMEDIATELY. Zero network.
///   2. The profile is hydrated from a local SharedPreferences cache instantly,
///      then refreshed in the background when the network cooperates.
///   3. A blocked/signed-out decision can only be made from a FRESH server
///      response; while offline we optimistically stay in the app (WhatsApp
///      does exactly this).
class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper>
    with WidgetsBindingObserver {
  final SupabaseService _supabaseService = SupabaseService();
  StreamSubscription<AuthState>? _authSub;

  static const String _kProfileCacheKey = 'auth_profile_cache_v1';
  static const String _kProfileUidKey = 'auth_profile_cache_uid_v1';

  // Latest known-good profile (server or local cache). Never blocks the UI.
  Map<String, dynamic>? _profile;

  /// Guard so the block-check runs at most once per session id.
  String? _checkedBlockedFor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((event) {
      if (mounted) setState(() {});
    });

    // Hydrate the cached profile without waiting for anything.
    _restoreCachedProfile();
  }

  Future<void> _restoreCachedProfile() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final uid = Supabase.instance.client.auth.currentSession?.user.id;
      if (uid == null) return;
      if (sp.getString(_kProfileUidKey) != uid) return;
      final raw = sp.getString(_kProfileCacheKey);
      if (raw == null) return;
      final map = Map<String, dynamic>.from(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
      if (mounted && _profile == null) {
        setState(() => _profile = map);
      }
    } catch (_) {}
  }

  Future<void> _cacheProfile(Map<String, dynamic> profile) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kProfileUidKey, profile['id']?.toString() ?? '');
      await sp.setString(_kProfileCacheKey, jsonEncode(profile));
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // User left the app — auto-disconnect VPN (lifecycle stop)
      VpnManager.instance.stopForLifecycle();
    } else if (state == AppLifecycleState.resumed) {
      // User came back — auto-reconnect VPN (only if not already starting)
      if (!VpnManager.instance.isStarting) {
        VpnManager.instance.autoStartOnAppOpen(ignoreAccessCheck: true);
      }
    }
  }

  /// Background block/access check. Only acts on a DEFINITIVE server answer.
  Future<void> _checkBlockedInBackground(String userId) async {
    if (_checkedBlockedFor == userId) return;
    _checkedBlockedFor = userId;
    try {
      final profile = await _supabaseService
          .getProfile(userId)
          .timeout(const Duration(seconds: 15));

      if (profile == null) {
        // Session invalid/expired and couldn't refresh → go to login.
        if (mounted &&
            Supabase.instance.client.auth.currentSession == null) {
          setState(() {});
        }
        return;
      }

      if (profile['is_blocked'] == true) {
        await _supabaseService.signOut();
        if (mounted) {
          final reason = (profile['blocked_reason'] ??
                  'Your account has been blocked by admin.')
              .toString();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(reason),
              backgroundColor: Colors.redAccent,
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      // Fresh profile from server: update state + cache for next cold start.
      if (mounted) {
        setState(() => _profile = profile);
        unawaited(_cacheProfile(profile));
      }
    } catch (_) {
      // Network hiccup — keep using whatever we have. Reset guard so the next
      // resume/retry can attempt again.
      _checkedBlockedFor = null;
    }
  }

  Map<String, dynamic> _fallbackProfile(String userId) {
    final user = Supabase.instance.client.auth.currentUser;
    final usernameFromMeta =
        (user?.userMetadata?['username'] ?? '').toString();
    final displayNameFromMeta =
        (user?.userMetadata?['display_name'] ?? '').toString();
    return {
      'id': userId,
      'email': user?.email,
      'username': usernameFromMeta.isNotEmpty
          ? usernameFromMeta
          : userId.substring(0, 8).toUpperCase(),
      'display_name': displayNameFromMeta,
    };
  }

  @override
  Widget build(BuildContext context) {
    final session = Supabase.instance.client.auth.currentSession;

    if (session != null) {
      final uid = session.user.id;

      // Kick off (non-blocking) server verification — returns immediately,
      // updates state later.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _checkBlockedInBackground(uid);
      });

      // Decide what profile data to hand the shell RIGHT NOW:
      // cached/server profile > metadata fallback. NEVER null-blocked on net.
      final profile = _profile ?? _fallbackProfile(uid);

      return MainShell(profile: profile);
    }

    return const LoginScreen();
  }
}
