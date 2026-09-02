/// [NEW 2026-09-02] Agora RTC configuration for Netchat calls.
///
/// App ID is a public project identifier (safe to ship in the client — it is
/// not a secret). The certificate / primary-key material stays on the Agora
/// console side; with "App ID only" security mode no token is required for
/// channel joins, which matches how the provided credentials are issued.
class AgoraConfig {
  AgoraConfig._();

  /// Agora project App ID (from console.agora.io → your project).
  static const String appId = '68f4ed7143f84b6f80bb5f0899e7f581';

  /// Optional temp/RTC token. Leave empty when the project uses "App ID"
  /// authentication mode. If you later enable "App ID + Token", set this or
  /// wire a token endpoint and pass its value into joinChannel.
  static const String rtcToken = '';

  /// Deterministic 1:1 channel name from the two user ids.
  /// Both peers compute the same name independently.
  static String channelFor(String a, String b) {
    final pair = [a, b]..sort();
    return 'netchat_${pair[0]}_${pair[1]}';
  }
}
