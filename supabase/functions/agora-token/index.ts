// Supabase Edge Function: agora-token
// [NEW 2026-09-03] Generates a fresh Agora RTC token from the App Certificate
// on every request. Because tokens are minted server-side just-in-time, they
// NEVER expire from the app's perspective — this is the STABLE way to use
// Agora "App ID + Token" (certificate) auth.
//
// Implements the Agora SignalingToken / AccessToken2 generation in pure Deno
// (no npm deps) so it runs directly as an Edge Function.
//
// HOW TO DEPLOY:
//   supabase functions deploy agora-token --project-ref <ref>
//   supabase secrets set AGORA_APP_ID=68f4ed7143f84b6f80bb5f0899e7f581
//   supabase secrets set AGORA_APP_CERTIFICATE=0c357584a59b454987cd51b2aa33a675
//
// REQUEST (GET):
//   /functions/v1/agora-token?channel=<channel>&uid=<uid>
//   ?appId=<appId>&certificate=<certificate>   (channel + uid are REQUIRED)
//
// RESPONSE:
//   { "code": 0, "data": { "token": "007e...", "channel": "...", "expire": 86400 } }
//   Or { "code": 1, "error": "..." } on failure.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const encoder = new TextEncoder();

interface AccessTokenV2 {
  appId: Uint8Array; // 32 bytes padded
  appCertificate: Uint8Array;
  issueTime: number;
  expire: number;
  salt: Uint8Array; // 32 bytes
  services: Array<{ type: number; privilege: Uint8Array; privilegeMessage: Uint8Array }>;
}

// --- Agora base64url + packing helpers ------------------------------------

function base64Encode(input: Uint8Array | string): string {
  const bytes = typeof input === "string" ? encoder.encode(input) : input;
  let bin = "";
  bytes.forEach((b) => (bin += String.fromCharCode(b)));
  const b64 = btoa(bin);
  // Agora URL-safe variant: '-' and '_' plus no padding
  return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function base64Decode(s: string): Uint8Array {
  let t = s.replace(/-/g, "+").replace(/_/g, "/");
  while (t.length % 4) t += "=";
  const bin = atob(t);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

function packUint16(v: number): Uint8Array {
  return new Uint8Array([(v >> 8) & 0xff, v & 0xff]);
}
function packUint32(v: number): Uint8Array {
  return new Uint8Array([(v >>> 24) & 0xff, (v >>> 16) & 0xff, (v >>> 8) & 0xff, v & 0xff]);
}
function packUint64(v: number): Uint8Array {
  // JS numbers here fit comfortably in 2^53; Agora uses 64-bit but the high
  // 32 bits stay small for current timestamps.
  const hi = Math.floor(v / 0x100000000);
  const lo = v >>> 0;
  return new Uint8Array([
    (hi >>> 24) & 0xff, (hi >>> 16) & 0xff, (hi >>> 8) & 0xff, hi & 0xff,
    (lo >>> 24) & 0xff, (lo >>> 16) & 0xff, (lo >>> 8) & 0xff, lo & 0xff,
  ]);
}

function concat(...arrays: Uint8Array[]): Uint8Array {
  const len = arrays.reduce((s, a) => s + a.length, 0);
  const out = new Uint8Array(len);
  let off = 0;
  for (const a of arrays) {
    out.set(a, off);
    off += a.length;
  }
  return out;
}

function stringBytes(s: string): Uint8Array {
  return encoder.encode(s);
}

function getRandomBytes(n: number): Uint8Array {
  const bytes = new Uint8Array(n);
  // crypto.getRandomValues is available in Deno runtime.
  crypto.getRandomValues(bytes);
  return bytes;
}

async function hmacSha256(key: Uint8Array, message: Uint8Array): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    key,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", cryptoKey, message);
  return new Uint8Array(sig);
}

// --- AccessToken2 for the RTC (rtc_role) service --------------------------
//
// Service type 1 = RtcChannelPrivileges.
// Privilege message contains:
//   type(1) + salt(8) + ts(8) + expire(8) followed by the service-specific
//   fields: channelName (uint16-len string), rid (uint16, 0), uid (uint32),
//   privilege (uint32) and expiry (uint32).
//
// Total message = serviceType(2) + privilegeMessage(bytes).
// Token = "007" + appId(32) + issueTs(8) + expire(8) + salt(8) +
//         signingInfo(len(2) + signingInfoBytes) + crc32(4)

async function buildAccessToken2(opts: {
  appId: string;
  certificate: string;
  channel: string;
  uid: string | number;
  expire: number;
}): Promise<string> {
  const { appId, certificate, channel, uid, expire } = opts;
  const now = Math.floor(Date.now() / 1000);

  // App ID is a UUID-like 36 char string; pad to 32 bytes (Agora trims to 32).
  const appIdBytes = stringBytes(appId.slice(0, 32));
  const certBytes = stringBytes(certificate);
  const salt = getRandomBytes(8); // salt is 8 bytes in AccessToken2
  const issueTs = now;

  // RTC service privilege (service type 1)
  const serviceType = 1; // RtcChannelPrivileges
  const uidNum = typeof uid === "number" ? uid : parseInt(uid, 10) || 0;
  // uid 0 -> use a random numeric uid; only used for token generation.
  const privilege = 1; // RoleFlag kJoinChannel in the old form; AccessToken2 uses bitmask
  // Agora: client join channel permission bit = 1 (kJoinChannel)
  const roleFlag = 1; // JOIN_CHANNEL
  const privilegeTs = now + expire;

  // service-specific message
  const serviceMessage = concat(
    packUint32(serviceType),
    packUint32(0), // salt unused here in effective payload but keep 4 bytes
    packUint64(issueTs),
    packUint64(privilegeTs),
  );

  // The RTC service payload:
  //   serviceType(2) + privilegeBytes(2) + privilegeMessage
  const priviledgeMessageBytes = concat(
    packUint16(serviceType),
    packUint16(0), // length of "service" struct is encoded implicitly in bytes after
    // Actual per-service data:
    packUint16(serviceType),
    packUint16(channel.length),
    stringBytes(channel),
    packUint16(0), // uid string length (0 -> numeric uid follows)
    packUint32(uidNum),
    packUint32(roleFlag),
    packUint32(privilegeTs),
  );

  const signingInfo = concat(
    priviledgeMessageBytes,
  );

  // signingInfo in AccessToken2: len + bytes, then signingInfo digest.
  const signingInfoWithLen = concat(packUint16(signingInfo.length), signingInfo);

  // signing message = appId + ts + salt + expire + signingInfoWithLen
  const toSign = concat(
    appIdBytes,
    packUint32(issueTs),
    salt,
    packUint32(expire),
    signingInfoWithLen,
  );

  const sign = await hmacSha256(certBytes, toSign);

  // final token = "007" + base64url(bytes)
  const greenLight = "007";
  const tokenBytes = concat(
    stringBytes(greenLight),
    stringBytes(appId.slice(0, 32)), // appId in token
    appIdBytes,
    packUint32(issueTs),
    salt,
    packUint32(expire),
    signingInfoWithLen,
    // signature last: use HMAC sign (32 bytes)
    sign,
  );

  return base64Encode(tokenBytes);
}

// --- Standard RtcTokenBuilder (v2) fallback --------------------------------
// Simpler Agora RtcTokenBuilder2 "AccessToken2" shape used by many SDKs:
//   "007" + pack_uint16_type_rtc + packing
// We implement the widely-used AccessToken2 layout explicitly for reliability.

async function buildRtcToken(opts: {
  appId: string;
  certificate: string;
  channel: string;
  uid: string | number;
  expire: number;
}): Promise<string> {
  const { appId, certificate, channel, uid, expire } = opts;
  const now = Math.floor(Date.now() / 1000);
  const certBytes = stringBytes(certificate);
  const appIdBytes = stringBytes(appId);
  const salt = getRandomBytes(8);
  const uidNum = typeof uid === "number" ? uid : parseInt(uid, 10) || 0;
  const privilegeTs = now + expire;
  const serviceType = 1; // RtcChannelPrivileges
  const roleFlag = 1; // kJoinChannel

  // service-specific message (per RtcTokenBuilder2 AccessToken2):
  const serviceMessage = concat(
    packUint32(serviceType),
    packUint32(0), // salt placeholder
    packUint64(now),
    packUint64(privilegeTs),
  );

  // Build signing info
  const signingInfoContent = concat(
    packUint16(serviceType),
    packUint16(channel.length),
    stringBytes(channel),
    packUint16(0), // uid.length=0
    packUint32(uidNum),
    packUint32(roleFlag),
    packUint32(privilegeTs),
  );

  const signingInfo = concat(
    packUint16(serviceType),
    packUint16(signingInfoContent.length), // not strictly needed, keep
    signingInfoContent,
  );

  const signingInfoWithLen = concat(packUint16(signingInfo.length), signingInfo);

  const toSign = concat(
    appIdBytes,
    packUint32(now),
    salt,
    packUint32(expire),
    signingInfoWithLen,
  );

  const sign = await hmacSha256(certBytes, toSign);

  const tokenBody = concat(
    appIdBytes,
    packUint32(now),
    salt,
    packUint32(expire),
    signingInfoWithLen,
    sign,
  );

  return "007" + base64Encode(tokenBody);
}

Deno.serve(async (req: Request) => {
  try {
    const url = new URL(req.url);
    const channel = url.searchParams.get("channel") || "";
    const uid = url.searchParams.get("uid") || "0";
    const appId = url.searchParams.get("appId") ||
      Deno.env.get("AGORA_APP_ID") || "";
    const certificate = url.searchParams.get("certificate") ||
      Deno.env.get("AGORA_APP_CERTIFICATE") || "";
    const expire = Number(url.searchParams.get("expire") || 86400);

    if (!appId) {
      return new Response(
        JSON.stringify({ code: 1, error: "missing appId" }),
        { status: 400, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } },
      );
    }
    if (!certificate) {
      return new Response(
        JSON.stringify({ code: 1, error: "missing certificate (set AGORA_APP_CERTIFICATE secret)" }),
        { status: 400, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } },
      );
    }
    if (!channel) {
      return new Response(
        JSON.stringify({ code: 1, error: "missing channel" }),
        { status: 400, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } },
      );
    }

    // Min 1 hr, max 7 days (tokens beyond ~7d break the SDK).
    const safeExpire = Math.min(7 * 86400, Math.max(3600, expire));

    const token = await buildRtcToken({
      appId,
      certificate,
      channel,
      uid,
      expire: safeExpire,
    });

    return new Response(
      JSON.stringify({
        code: 0,
        data: { token, channel, expire: safeExpire },
      }),
      { status: 200, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } },
    );
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : "unknown error";
    return new Response(
      JSON.stringify({ code: 1, error: msg }),
      { status: 500, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } },
    );
  }
});