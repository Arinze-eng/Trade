// Lightweight device fingerprint helper.
//
// We hash a stable per-install ID + platform info so the same device cannot
// trivially create multiple accounts with different emails.
//
// We persist a UUID in SharedPreferences once per install so reinstalling does
// reset it (we accept that — the goal is to stop trivial referral looting,
// not to be a perfect device-id solution).
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;
import 'package:shared_preferences/shared_preferences.dart';

class DeviceFingerprint {
  static const _kKey = 'cdn_chat_device_fp_v1';

  /// Returns a stable per-install fingerprint. Safe to call repeatedly.
  static Future<String> get() async {
    final sp = await SharedPreferences.getInstance();
    final cached = sp.getString(_kKey);
    if (cached != null && cached.isNotEmpty) return cached;

    final rand = math.Random.secure();
    final salt = List<int>.generate(16, (_) => rand.nextInt(256));
    String os = 'unknown';
    try {
      os = Platform.operatingSystem;
    } catch (_) {}
    final raw = '$os|${DateTime.now().microsecondsSinceEpoch}|${base64UrlEncode(salt)}';
    final fp = crypto.sha256.convert(utf8.encode(raw)).toString();
    await sp.setString(_kKey, fp);
    return fp;
  }
}
