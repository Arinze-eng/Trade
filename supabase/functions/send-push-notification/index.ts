// Supabase Edge Function: send-push-notification
// [UPDATE 2026-06-10-FIX] Robust Firebase auth + better error logs + delivery confirmation
// Deploy with: supabase functions deploy send-push-notification --no-verify-jwt
// Required secrets (one of):
//   - FIREBASE_SERVICE_ACCOUNT (full JSON string from Firebase console - PREFERRED)
//   - FIREBASE_PRIVATE_KEY (just the private key in PEM format) + FIREBASE_CLIENT_EMAIL

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const FIREBASE_PROJECT_ID = "cdnnetchat-7db90";
const DEFAULT_CLIENT_EMAIL = "firebase-adminsdk-fbsvc@cdnnetchat-7db90.iam.gserviceaccount.com";

interface PushPayload {
  receiver_id?: string;
  group_id?: string;
  sender_id: string;
  message_type: string;
  content: string;
  type: string;
  /** Optional: a sender-side message id so the server can mark it delivered after FCM. */
  message_id?: number;
  /** Optional: title shown in the notification (defaults to sender display name). */
  title?: string;
}

// Firebase OAuth2 access token cache
let _cachedToken: { token: string; expiry: number } | null = null;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const payload: PushPayload = await req.json();
    const { receiver_id, group_id, sender_id, message_type, content, type, message_id, title } = payload;

    if (!sender_id || !content) {
      return jsonResp({ error: "Missing required fields: sender_id, content" }, 400);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    // Get sender's display name (best effort)
    const { data: senderProfile } = await supabase
      .from("profiles")
      .select("display_name, username")
      .eq("id", sender_id)
      .single();

    const senderName = title || senderProfile?.display_name || senderProfile?.username || "CDN-NETCHAT";

    // Determine target user IDs
    let targetUserIds: string[] = [];

    if (type === "group_message" && group_id) {
      const { data: members } = await supabase
        .from("group_members")
        .select("user_id")
        .eq("group_id", group_id);
      targetUserIds = (members || [])
        .map((m: { user_id: string }) => m.user_id)
        .filter((id: string) => id !== sender_id);
    } else if (receiver_id) {
      targetUserIds = [receiver_id];
    }

    if (targetUserIds.length === 0) {
      return jsonResp({ success: true, sent: 0, reason: "no_targets" });
    }

    // Get FCM tokens for target users
    const { data: tokens } = await supabase
      .from("fcm_tokens")
      .select("user_id, fcm_token")
      .in("user_id", targetUserIds);

    if (!tokens || tokens.length === 0) {
      return jsonResp({ success: true, sent: 0, reason: "no_tokens" });
    }

    // Get Firebase OAuth2 access token (throws on misconfig — bubble up as 500)
    let accessToken: string;
    try {
      accessToken = await getFirebaseAccessToken();
    } catch (e) {
      console.error("[send-push] Firebase auth FAILED:", e);
      return jsonResp({
        error: "Firebase auth failed",
        detail: String(e?.message || e),
        hint: "Set FIREBASE_SERVICE_ACCOUNT env var to the full service-account JSON string.",
      }, 500);
    }

    // Send FCM notifications
    let sentCount = 0;
    const errors: any[] = [];

    for (const tokenRow of tokens) {
      try {
        const isCall = type === "call";
        const notificationTitle = isCall ? "📞 Incoming Call" : senderName;
        const notificationBody = content;

        const fcmPayload = {
          message: {
            token: tokenRow.fcm_token,
            // For Android, send DATA-only when isCall (so we can render full-screen via FlutterLocalNotifications)
            // For normal messages, send BOTH so OS can render even if app killed
            notification: {
              title: notificationTitle,
              body: notificationBody,
            },
            data: {
              type: type,
              sender_id: sender_id,
              msg_type: message_type,  // 'message_type' is reserved by FCM
              title: notificationTitle,
              body: notificationBody,
              ...(group_id ? { group_id } : {}),
              ...(receiver_id ? { chat_id: receiver_id } : {}),
              ...(message_id ? { message_id: String(message_id) } : {}),
              priority: "high",
            },
            android: {
              priority: "HIGH",
              ttl: "86400s",
              notification: {
                channel_id: isCall ? "incoming_calls" : "messages",
                sound: "default",
                click_action: "FLUTTER_NOTIFICATION_CLICK",
                default_sound: true,
                default_vibrate_timings: true,
                default_light_settings: true,
                notification_priority: isCall ? "PRIORITY_MAX" : "PRIORITY_HIGH",
                visibility: "PUBLIC",
                tag: receiver_id || group_id || sender_id,  // dedupe
              },
              direct_boot_ok: true,
            },
            apns: {
              payload: {
                aps: {
                  sound: "default",
                  "content-available": 1,
                  "mutable-content": 1,
                  category: isCall ? "call" : "message",
                },
              },
              headers: {
                "apns-priority": "10",
                "apns-push-type": "alert",
              },
            },
          },
        };

        const response = await fetch(
          `https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`,
          {
            method: "POST",
            headers: {
              Authorization: `Bearer ${accessToken}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify(fcmPayload),
          }
        );

        if (response.ok) {
          sentCount++;
        } else {
          const errorBody = await response.text();
          console.error(`[send-push] FCM send FAILED for user ${tokenRow.user_id}: status=${response.status} body=${errorBody}`);
          errors.push({ user_id: tokenRow.user_id, status: response.status, body: errorBody });

          // Token is invalid/expired — only remove on UNREGISTERED (real expiry)
          if (response.status === 404 || response.status === 410) {
            try {
              await supabase.from("fcm_tokens").delete().eq("user_id", tokenRow.user_id);
            } catch (_) {}
          } else if (response.status === 400) {
            try {
              const errJson = JSON.parse(errorBody);
              const errCode = errJson?.error?.details?.[0]?.errorCode || errJson?.error?.status;
              if (errCode === "UNREGISTERED") {
                await supabase.from("fcm_tokens").delete().eq("user_id", tokenRow.user_id);
              }
            } catch (_) {}
          }
        }
      } catch (err) {
        console.error(`[send-push] Error sending to user ${tokenRow.user_id}:`, err);
        errors.push({ user_id: tokenRow.user_id, error: String(err) });
      }
    }

    // ── If FCM succeeded for at least one recipient and message_id provided,
    //    mark the message as delivered server-side. This drives the "double tick".
    if (sentCount > 0 && message_id) {
      try {
        await supabase
          .from("messages")
          .update({
            is_delivered: true,
            delivered_at: new Date().toISOString(),
          })
          .eq("id", message_id);
      } catch (e) {
        console.error("[send-push] mark delivered failed:", e);
      }
    }

    return jsonResp({
      success: true,
      sent: sentCount,
      total: tokens.length,
      errors: errors.length > 0 ? errors : undefined,
    });
  } catch (error: any) {
    console.error("[send-push] Edge function error:", error);
    return jsonResp({ error: error?.message || "Internal server error" }, 500);
  }
});

function jsonResp(body: any, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// ──────────────────────────────────────────────────────────────────────
// Get Firebase OAuth2 access token using a service account.
// Accepts EITHER:
//   1. FIREBASE_SERVICE_ACCOUNT  (full JSON string — recommended)
//   2. FIREBASE_PRIVATE_KEY + FIREBASE_CLIENT_EMAIL (legacy split form)
// ──────────────────────────────────────────────────────────────────────
async function getFirebaseAccessToken(): Promise<string> {
  if (_cachedToken && _cachedToken.expiry > Date.now() + 300000) {
    return _cachedToken.token;
  }

  let privateKey: string | null = null;
  let clientEmail: string = DEFAULT_CLIENT_EMAIL;

  // ── Method 1: full service account JSON ──
  const sa = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
  if (sa) {
    try {
      const parsed = JSON.parse(sa);
      privateKey = (parsed.private_key || "").replace(/\\n/g, "\n");
      if (parsed.client_email) clientEmail = parsed.client_email;
    } catch (e) {
      throw new Error("FIREBASE_SERVICE_ACCOUNT is not valid JSON: " + (e as Error).message);
    }
  }

  // ── Method 2: split form (legacy) ──
  if (!privateKey) {
    const rawKey = Deno.env.get("FIREBASE_PRIVATE_KEY");
    if (!rawKey) {
      throw new Error("Neither FIREBASE_SERVICE_ACCOUNT nor FIREBASE_PRIVATE_KEY is set.");
    }
    privateKey = rawKey.replace(/\\n/g, "\n");
    const e = Deno.env.get("FIREBASE_CLIENT_EMAIL");
    if (e) clientEmail = e;
  }

  if (!privateKey || !privateKey.includes("BEGIN")) {
    throw new Error(
      "Private key is malformed (no BEGIN marker). Length=" +
        (privateKey?.length || 0) +
        ". Make sure to paste the FULL key including the BEGIN/END PRIVATE KEY lines."
    );
  }

  const now = Math.floor(Date.now() / 1000);
  const expiry = now + 3600;

  const header = base64urlEncode(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claimSet = base64urlEncode(
    JSON.stringify({
      iss: clientEmail,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: expiry,
    })
  );

  const signatureInput = `${header}.${claimSet}`;

  let key: CryptoKey;
  try {
    key = await crypto.subtle.importKey(
      "pkcs8",
      pemToArrayBuffer(privateKey),
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"]
    );
  } catch (e) {
    throw new Error("importKey failed (private key not valid PKCS#8 PEM): " + (e as Error).message);
  }

  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(signatureInput)
  );

  const jwt = `${signatureInput}.${base64urlEncode(signature)}`;

  const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }).toString(),
  });

  const tokenData = await tokenResponse.json();

  if (!tokenData.access_token) {
    console.error("[send-push] Firebase token exchange failed:", JSON.stringify(tokenData));
    throw new Error(
      "Firebase token exchange returned no access_token. Response: " +
        JSON.stringify(tokenData)
    );
  }

  _cachedToken = {
    token: tokenData.access_token,
    expiry: Date.now() + (tokenData.expires_in || 3600) * 1000,
  };

  return tokenData.access_token;
}

function base64urlEncode(data: string | ArrayBuffer): string {
  let binary = "";
  if (typeof data === "string") {
    binary = btoa(data);
  } else {
    const bytes = new Uint8Array(data);
    for (let i = 0; i < bytes.length; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    binary = btoa(binary);
  }
  return binary.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN[^-]+-----/g, "")
    .replace(/-----END[^-]+-----/g, "")
    .replace(/\s/g, "");
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}
