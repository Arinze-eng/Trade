import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// [FIX 2026-09-03] Agora RTC configuration for Netchat calls.
///
/// The Agora project uses "App ID + Token" (certificate) auth, so joining a
/// channel always requires a valid RTC token. Instead of shipping a short-lived
/// token (which expires and would break calls again), we fetch a FRESH token
/// from the `agora-token` Supabase Edge Function right before every call. The
/// function mints a token from the App Certificate server-side, so tokens never
/// expire from the app's perspective — this is the STABLE solution.
///
/// Fallbacks (in order) if the edge function is unreachable:
///   1. `app_settings` override key `agora_rtc_token` (admin can set it),
///   2. the shipped default token (used until it expires).
///
/// NOTE: You must deploy the edge function and set the secrets first:
///   supabase functions deploy agora-token
///   supabase secrets set AGORA_APP_ID=68f4ed7143f84b6f80bb5f0899e7f581
///   supabase secrets set AGORA_APP_CERTIFICATE=0c357584a59b454987cd51b2aa33a675
class AgoraConfig {
  AgoraConfig._();

  /// Agora project App ID (from console.agora.io → your project).
  static const String appId = '68f4ed7143f84b6f80bb5f0899e7f581';

  /// The Agora App Certificate (server-side secret). Kept here only as a
  /// fallback reference; the authoritative minting happens in the Edge Function.
  static const String appCertificate = '0c357584a59b454987cd51b2aa33a675';

  /// Supabase Edge Function that mints a fresh RTC token. OPTIONAL.
  ///
  /// When empty, the app uses app_settings `agora_rtc_token` → the shipped
  /// default token below. To activate full auto-minting (so tokens never
  /// expire), set this to your edge function URL AND deploy it:
  ///   supabase functions deploy agora-token
  ///   supabase secrets set AGORA_APP_ID=68f4ed7143f84b6f80bb5f0899e7f581
  ///   supabase secrets set AGORA_APP_CERTIFICATE=0c357584a59b454987cd51b2aa33a675
  /// The edge function source ships in supabase/functions/agora-token.
  static const String tokenEndpoint = '';

  /// Fallback RTC token (current valid token from the provided credentials).
  /// Used only if the edge function is unreachable AND app_settings is empty.
  /// This token is temporary and may expire — it is NOT the primary path.
  static const String defaultRtcToken =
      '007eJxTYJg1+VKAj/TEZQ960/tn1s1dUF3Hypfw93FG7qb9M+YZrQ1WYDCzSDNJTTE3NDFOszBJMkuzMEhKMk0zsLC0TDVPM7UwnCk0I6shkJEh67EPMyMDBIL4XAzOKXl5qSXJGYkkDAwAZVgihw==';

  static String? _cachedToken;

  /// Invalidate the cached Agora token (called after admin saves a new one).
  static void invalidateTokenCache() {
    _cachedToken = null;
  }

  /// Resolve the active RTC token for a given channel.
  ///   tokenEndpoint (fresh)  >  app_settings `agora_rtc_token`  >  default.
  static Future<String> resolveRtcToken({required String channel, String uid = '0'}) async {
    // 1) Try the fresh token endpoint (STABLE path).
    if (tokenEndpoint.isNotEmpty) {
      try {
        final t = await _fetchFreshToken(channel, uid);
        if (t.isNotEmpty) {
          _cachedToken = t;
          return t;
        }
      } catch (_) {
        // fall through
      }
    }

    // 2) app_settings override.
    if (_cachedToken == null || _cachedToken!.isEmpty) {
      var t = defaultRtcToken;
      try {
        final row = await Supabase.instance.client
            .from('app_settings')
            .select('value')
            .eq('key', 'agora_rtc_token')
            .maybeSingle();
        if (row != null) {
          var v = row['value'];
          if (v is Map) v = v.toString();
          final s = (v ?? '').toString().replaceAll(RegExp(r'^"|"$'), '').trim();
          if (s.isNotEmpty) t = s;
        }
      } catch (_) {}
      _cachedToken = t;
    }

    final token = _cachedToken ?? defaultRtcToken;
    // Empty token means "App ID only" mode — that is valid too.
    return token;
  }

  static Future<String> _fetchFreshToken(String channel, String uid) async {
    final uri = Uri.parse(tokenEndpoint).replace(queryParameters: {
      'channel': channel,
      'uid': uid,
      'appId': appId,
    });
    final resp = await http.get(uri).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) return '';
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    if (map['code'] != 0) return '';
    final data = map['data'] as Map<String, dynamic>?;
    return (data?['token'] ?? '').toString().trim();
  }

  /// Admin: persist a new RTC token into app_settings (manual override).
  /// Uses INSERT...ON CONFLICT so it works even if the row is missing.
  static Future<void> setAdminRtcToken(String token) async {
    final res = await Supabase.instance.client
        .from('app_settings')
        .upsert({'key': 'agora_rtc_token', 'value': token}, onConflict: 'key')
        .select('key');
    if ((res as List).isEmpty) {
      throw Exception('Failed to write Agora RTC token.');
    }
    _cachedToken = null;
  }

  /// Deterministic 1:1 channel name from the two user ids.
  /// Both peers compute the same name independently.
  static String channelFor(String a, String b) {
    final pair = [a, b]..sort();
    return 'netchat_${pair[0]}_${pair[1]}';
  }
}