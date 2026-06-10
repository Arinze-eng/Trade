// Supabase Edge Function: send-push-notification
// [UPDATE 2026-06-10] Fixed: proper Firebase auth, mark delivered, TTL cleanup
// Deploy with: supabase functions deploy send-push-notification
// Required secrets: FIREBASE_PRIVATE_KEY (from Firebase service account)

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const FIREBASE_PROJECT_ID = "cdnnetchat-7db90";

interface PushPayload {
  receiver_id?: string;
  group_id?: string;
  sender_id: string;
  message_type: string;
  content: string;
  type: string;
}

// Firebase OAuth2 access token cache
let _cachedToken: { token: string; expiry: number } | null = null;

Deno.serve(async (req: Request) => {
  try {
    const payload: PushPayload = await req.json();
    const { receiver_id, group_id, sender_id, message_type, content, type } = payload;

    if (!sender_id || !content) {
      return new Response(JSON.stringify({ error: "Missing required fields" }), { status: 400 });
    }

    // Initialize Supabase client with service role key
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    // Get sender's display name
    const { data: senderProfile } = await supabase
      .from("profiles")
      .select("display_name, username")
      .eq("id", sender_id)
      .single();

    const senderName = senderProfile?.display_name || senderProfile?.username || "CDN-NETCHAT";

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
      return new Response(JSON.stringify({ success: true, sent: 0 }));
    }

    // Get FCM tokens for target users
    const { data: tokens } = await supabase
      .from("fcm_tokens")
      .select("user_id, fcm_token")
      .in("user_id", targetUserIds);

    if (!tokens || tokens.length === 0) {
      return new Response(JSON.stringify({ success: true, sent: 0, reason: "no_tokens" }));
    }

    // Get Firebase OAuth2 access token
    const accessToken = await getFirebaseAccessToken();

    // Send FCM notifications
    let sentCount = 0;
    for (const tokenRow of tokens) {
      try {
        const notificationTitle = type === "call" ? "Incoming Call" : senderName;
        const notificationBody = type === "call" ? content : content;

        const fcmPayload = {
          message: {
            token: tokenRow.fcm_token,
            notification: {
              title: notificationTitle,
              body: notificationBody,
            },
            data: {
              type: type,
              sender_id: sender_id,
              message_type: message_type,
              ...(group_id ? { group_id } : {}),
              ...(receiver_id ? { chat_id: receiver_id } : {}),
              priority: "high",
            },
            android: {
              priority: "HIGH",
              ttl: "86400s",
              notification: {
                channel_id: type === "call" ? "incoming_calls" : "messages",
                sound: "default",
                click_action: "FLUTTER_NOTIFICATION_CLICK",
                default_sound: true,
                default_vibrate_timings: true,
                default_light_settings: true,
                notification_priority: type === "call" ? "PRIORITY_MAX" : "PRIORITY_HIGH",
                visibility: "PUBLIC",
              },
              direct_boot_ok: true,
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
          console.error(`FCM send failed for user ${tokenRow.user_id}:`, errorBody);

          if (response.status === 404 || response.status === 410) {
            await supabase.from("fcm_tokens").delete().eq("user_id", tokenRow.user_id);
          }
        }
      } catch (err) {
        console.error(`Error sending to user ${tokenRow.user_id}:`, err);
      }
    }

    return new Response(
      JSON.stringify({ success: true, sent: sentCount, total: tokens.length }),
      { headers: { "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("Edge function error:", error);
    return new Response(
      JSON.stringify({ error: error.message || "Internal server error" }),
      { status: 500 }
    );
  }
});

// Get Firebase OAuth2 access token using service account (with caching)
async function getFirebaseAccessToken(): Promise<string> {
  // Return cached token if still valid (with 5 min grace)
  if (_cachedToken && _cachedToken.expiry > Date.now() + 300000) {
    return _cachedToken.token;
  }

  const privateKey = Deno.env.get("FIREBASE_PRIVATE_KEY")?.replace(/\\n/g, "\n");
  if (!privateKey) {
    throw new Error("FIREBASE_PRIVATE_KEY not set");
  }

  const clientEmail = "firebase-adminsdk-fbsvc@cdnnetchat-7db90.iam.gserviceaccount.com";
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

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(privateKey),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(signatureInput)
  );

  const jwt = `${signatureInput}.${base64urlEncode(signature)}`;

  const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn%3Aietf%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${jwt}`,
  });

  const tokenData = await tokenResponse.json();
  
  if (!tokenData.access_token) {
    console.error("Firebase token exchange failed:", tokenData);
    throw new Error("Failed to get Firebase access token");
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
    .replace(/-----BEGIN.*?-----/g, "")
    .replace(/-----END.*?-----/g, "")
    .replace(/\s/g, "");
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}