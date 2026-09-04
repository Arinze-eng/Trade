import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:zego_express_engine/zego_express_engine.dart';

/// [FIX 2026-09-03] ZegoCloud Express RTC configuration for Netchat calls.
///
/// Replaces the former Agora integration. ZegoCloud uses two credentials:
///   • AppID   (int)   — project identifier
///   • AppSign (string)— 64-char hex signing secret
///
/// Unlike Agora "App ID + Token (certificate)" auth, ZegoCloud's basic mode
/// uses appID + appSign directly — NO per-call token minting. This removes the
/// whole agora-token Edge Function / RTC token expiry problem entirely.
///
/// The values can be overridden at runtime from the Admin panel (stored in
/// Supabase `app_settings` under keys `zego_app_id` and `zego_app_sign`), so
/// the credentials can be changed without shipping a new build.
///
/// Resolution order for the active config:
///   app_settings override  →  compiled defaults below.
class ZegoConfig {
  ZegoConfig._();

  /// ZegoCloud project App ID (from console.zegocloud.com → your project).
  static const int defaultAppId = 1113839402;

  /// ZegoCloud project App Sign (64-char hex secret).
  /// [UPDATE 2026-09-04] Using the project's active App Sign supplied by owner.
  static const String defaultAppSign =
      'aec83fd5a924460c8fb842ddee588549';

  /// [NEW] Load the active Zego credentials from Supabase `app_settings`,
  /// falling back to [defaultAppId] / [defaultAppSign] when not overridden.
  ///
  /// Called lazily before creating the engine (i.e. right before a call), so
  /// admin changes take effect without requiring an app restart.
  static Future<({int appId, String appSign})> resolveConfig() async {
    var appId = defaultAppId;
    var appSign = defaultAppSign;
    try {
      final rows = await Supabase.instance.client
          .from('app_settings')
          .select('key,value')
          .inFilter('key', ['zego_app_id', 'zego_app_sign']);
      for (final r in rows) {
        final key = (r['key'] ?? '').toString();
        var val = (r['value'] ?? '').toString();
        val = val.replaceAll(RegExp(r'^"|"$'), '').trim();
        if (key == 'zego_app_id') {
          final parsed = int.tryParse(val);
          if (parsed != null && parsed > 0) appId = parsed;
        } else if (key == 'zego_app_sign' && val.isNotEmpty) {
          appSign = val;
        }
      }
    } catch (_) {
      // fall back to defaults
    }
    return (appId: appId, appSign: appSign);
  }

  /// [NEW] Admin: persist Zego AppID + AppSign into `app_settings`.
  /// Uses INSERT...ON CONFLICT so it works even if the rows are missing.
  static Future<void> saveAdminConfig({required int appId, required String appSign}) async {
    final rows = [
      {'key': 'zego_app_id', 'value': appId.toString()},
      {'key': 'zego_app_sign', 'value': appSign},
    ];
    final res = await Supabase.instance.client.from('app_settings').upsert(rows, onConflict: 'key').select('key');
    if ((res as List).isEmpty) {
      throw Exception('Failed to write ZegoCloud config.');
    }
  }

  /// Deterministic 1:1 room name from the two user ids.
  /// Both peers compute the same name independently.
  static String roomFor(String a, String b) {
    final pair = [a, b]..sort();
    return 'netchat_${pair[0]}_${pair[1]}';
  }

  /// Build a stable Zego user object for the local user.
  static ZegoUser localUser(String userId) {
    // ZegoUser(userID, userName) — both positional.
    final short = userId.length > 20 ? userId.substring(0, 20) : userId;
    return ZegoUser(userId, short);
  }

  /// Zego stream ID for a given channel + local user (publisher stream id).
  /// Must be unique per publisher; derive from room + a short hash of userId.
  static String streamIdFor(String roomId, String userId) {
    final h = userId.hashCode & 0x7fffffff;
    return '${roomId}_$h';
  }
}