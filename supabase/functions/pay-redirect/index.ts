// Flutterwave payment callback / verifier for CDN-NETCHAT.
//
// Behaviour:
//   GET  /pay-redirect?plan=<basic|premium>&tx_ref=<...>&transaction_id=<...>&status=<...>
//        Browser-friendly redirect target — verifies tx with Flutterwave,
//        activates the subscription, evaluates referral milestones, then
//        returns a small HTML page telling the user to return to the app.
//
//   POST /pay-redirect (Flutterwave webhook)
//        Verifies signature header `verif-hash`, then verifies + activates.
//
// Environment variables (set via `supabase secrets set`):
//   FLW_SECRET_KEY          – Flutterwave secret key (FLWSECK-…)
//   FLW_WEBHOOK_HASH        – the secret hash you configure in Flutterwave dashboard
//   SUPABASE_URL            – auto-injected
//   SUPABASE_SERVICE_ROLE_KEY – auto-injected
//
// Public URLs (set these in your Flutterwave payment links):
//   Premium (Pro): https://tlmyxuyqngkgwgjepeed.functions.supabase.co/pay-redirect?plan=premium
//   Basic:         https://tlmyxuyqngkgwgjepeed.functions.supabase.co/pay-redirect?plan=basic

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const FLW_SECRET = Deno.env.get("FLW_SECRET_KEY") ?? "";
const FLW_WEBHOOK_HASH = Deno.env.get("FLW_WEBHOOK_HASH") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, verif-hash",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function planToTier(plan: string | null): "basic_premium" | "pro" {
  const p = (plan ?? "").toLowerCase();
  if (p === "basic" || p === "basic_premium") return "basic_premium";
  return "pro";
}

async function verifyWithFlutterwave(transactionId: string) {
  const r = await fetch(
    `https://api.flutterwave.com/v3/transactions/${transactionId}/verify`,
    {
      headers: {
        Authorization: `Bearer ${FLW_SECRET}`,
        "Content-Type": "application/json",
      },
    },
  );
  if (!r.ok) {
    return { ok: false, error: `flw http ${r.status}` };
  }
  const body = await r.json().catch(() => null);
  if (!body || body.status !== "success" || !body.data) {
    return { ok: false, error: "flw bad body" };
  }
  const d = body.data;
  if (d.status !== "successful") {
    return { ok: false, error: `flw tx status: ${d.status}` };
  }
  return { ok: true, data: d };
}

async function findUserId({
  metaUserId,
  email,
}: { metaUserId?: string; email?: string }): Promise<string | null> {
  if (metaUserId) return metaUserId;
  if (!email) return null;
  const { data } = await admin
    .from("profiles")
    .select("id")
    .eq("email", email.toLowerCase())
    .limit(1)
    .maybeSingle();
  return data?.id ?? null;
}

async function activate({
  userId,
  tier,
  amount,
  reference,
  days,
}: {
  userId: string;
  tier: "basic_premium" | "pro";
  amount: number;
  reference: string;
  days: number;
}) {
  const { data, error } = await admin.rpc(
    "activate_subscription_after_payment",
    {
      p_user_id: userId,
      p_tier: tier,
      p_amount: amount,
      p_payment_reference: reference,
      p_days: days,
    },
  );
  if (error) return { ok: false, error: error.message };
  // Best-effort: nudge referral milestones for the user (their own milestones
  // are evaluated, harmless for non-referrers).
  try {
    await admin.rpc("evaluate_referral_milestones", { p_referrer_id: userId });
  } catch (_) {}
  return { ok: true, data };
}

function html(body: string, ok = true) {
  const color = ok ? "#16a34a" : "#dc2626";
  return new Response(
    `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>CDN-NETCHAT Payment</title>
<style>
  body{font-family:-apple-system,Segoe UI,Roboto,sans-serif;background:#0F2027;color:#fff;
       display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;padding:24px}
  .card{background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.1);
        padding:28px;border-radius:18px;max-width:420px;text-align:center}
  h1{color:${color};margin:0 0 12px;font-size:22px}
  p{color:#cbd5e1;line-height:1.5}
  .btn{display:inline-block;background:#6366F1;color:#fff;text-decoration:none;
       padding:12px 22px;border-radius:12px;margin-top:14px;font-weight:600}
</style>
<div class="card">${body}</div>`,
    {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "text/html; charset=utf-8" },
    },
  );
}

async function handleVerify(req: Request, plan: string | null,
  txRef: string | null, transactionId: string | null, status: string | null,
  emailHint?: string,
): Promise<Response> {
  if (!transactionId && !txRef) {
    return html(
      `<h1>Missing transaction</h1><p>No transaction id received from Flutterwave.</p>`,
      false,
    );
  }
  if (status && status !== "successful" && status !== "completed") {
    return html(
      `<h1>Payment ${status}</h1><p>Your payment was not completed. You can try again from the app.</p>`,
      false,
    );
  }

  const idForVerify = transactionId ?? txRef!;
  const verified = await verifyWithFlutterwave(idForVerify);
  if (!verified.ok || !verified.data) {
    return html(
      `<h1>Verification failed</h1><p>${verified.error ?? "Unable to verify payment."}</p>`,
      false,
    );
  }
  const d = verified.data;
  const tier = planToTier(plan ?? d?.meta?.plan ?? null);
  const meta = d.meta ?? {};
  const userId = await findUserId({
    metaUserId: meta.user_id ?? meta.userId,
    email: emailHint ?? d.customer?.email,
  });
  if (!userId) {
    return html(
      `<h1>User not found</h1><p>We could not match this payment to a user account. Please contact support.</p>`,
      false,
    );
  }
  const result = await activate({
    userId,
    tier,
    amount: Number(d.amount ?? 0),
    reference: String(d.tx_ref ?? d.id ?? idForVerify),
    days: 30,
  });
  if (!result.ok) {
    return html(`<h1>Activation failed</h1><p>${result.error}</p>`, false);
  }
  return html(
    `<h1>Payment successful 🎉</h1>
     <p>Your <b>${tier === "pro" ? "Premium (Pro)" : "Basic"}</b> plan is now active for 30 days.</p>
     <p>Return to CDN-NETCHAT to continue.</p>`,
    true,
  );
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  const url = new URL(req.url);

  // ---------- POST: webhook ----------
  if (req.method === "POST") {
    // 1) Webhook signature check (Flutterwave sends `verif-hash`)
    const verifHash = req.headers.get("verif-hash") ?? "";
    if (FLW_WEBHOOK_HASH && verifHash !== FLW_WEBHOOK_HASH) {
      // Could be an authenticated client invocation (from Flutter app) — only
      // accept when caller has a valid JWT.
      const auth = req.headers.get("authorization") ?? "";
      if (!auth.toLowerCase().startsWith("bearer ")) {
        return new Response(
          JSON.stringify({ verified: false, error: "Bad signature" }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
    }
    let body: any = null;
    try { body = await req.json(); } catch (_) {}
    const data = body?.data ?? body ?? {};
    const transactionId = data.id ?? data.transaction_id ?? null;
    const txRef = data.tx_ref ?? null;
    const plan = url.searchParams.get("plan") ?? data?.meta?.plan ?? null;
    const status = data.status ?? "successful";
    const emailHint = data.customer?.email;
    if (!transactionId && !txRef) {
      return new Response(JSON.stringify({ verified: false, error: "missing_tx" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }
    const verified = await verifyWithFlutterwave(String(transactionId ?? txRef));
    if (!verified.ok || !verified.data) {
      return new Response(JSON.stringify({ verified: false, error: verified.error }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }
    const d = verified.data;
    const tier = planToTier(plan ?? d?.meta?.plan ?? null);
    const userId = await findUserId({
      metaUserId: d?.meta?.user_id ?? d?.meta?.userId,
      email: emailHint ?? d.customer?.email,
    });
    if (!userId) {
      return new Response(JSON.stringify({ verified: false, error: "no_user" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }
    const result = await activate({
      userId,
      tier,
      amount: Number(d.amount ?? 0),
      reference: String(d.tx_ref ?? d.id ?? transactionId ?? ""),
      days: 30,
    });
    return new Response(
      JSON.stringify({ verified: result.ok, tier, error: (result as any).error }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  // ---------- GET: browser callback ----------
  const plan = url.searchParams.get("plan");
  const txRef = url.searchParams.get("tx_ref");
  const transactionId = url.searchParams.get("transaction_id");
  const status = url.searchParams.get("status");
  return await handleVerify(req, plan, txRef, transactionId, status);
});
