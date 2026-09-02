# 2026-06 Feature Pack — Operator Notes

This commit adds:

- **Tiered referral rewards** — 1 / 5 / 10 successful referrals
- **Anti-abuse signup gate** — email + device fingerprint (no phone, no IP-only blocking)
- **Pro/Basic-only Discover Users** — free users must enter UUID manually
- **Admin Grant Basic** — alongside the existing Grant/Revoke Premium controls
- **Flutterwave callback** Edge Function (`pay-redirect`) — handles both Basic & Premium

## Required Supabase secrets

You **MUST** set these via the Supabase dashboard (`Project Settings → Edge Functions → Secrets`)
or via CLI:

```bash
supabase secrets set FLW_SECRET_KEY=FLWSECK-xxxxxxxx
supabase secrets set FLW_WEBHOOK_HASH=your-webhook-secret-hash
# SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are auto-injected.
```

## Flutterwave configuration

In your Flutterwave dashboard:

1. Open each Payment Link (one for Basic, one for Premium).
2. Set **Redirect URL** to:
   - Premium → `https://tlmyxuyqngkgwgjepeed.functions.supabase.co/pay-redirect?plan=premium`
   - Basic   → `https://tlmyxuyqngkgwgjepeed.functions.supabase.co/pay-redirect?plan=basic`
3. Optionally set the **Webhook URL** (`Settings → Webhooks`) to:
   `https://tlmyxuyqngkgwgjepeed.functions.supabase.co/pay-redirect`
   and configure the secret hash to match `FLW_WEBHOOK_HASH`.
4. When initiating Flutterwave checkout, include `meta = { user_id: "<uuid>", plan: "premium" }`
   so the callback can match the payment to the right account. If `meta.user_id` is absent
   the callback falls back to matching by customer email.

## Referral rules (implemented)

A referred user "counts" once they have sent **≥10 messages**.

| Successful referrals | Reward |
|---------------------:|--------|
| 1                    | ₦100 wallet credit |
| 5                    | ₦500 wallet credit |
| 10                   | 7-day Basic Premium subscription |

Milestones are evaluated whenever:
- The referred user opens chat / sends a message (streak RPC fires).
- The referrer opens the Wallet screen (`refresh_my_referral_status`).

## Anti-abuse rules (implemented)

A signup is **rejected** if any of these matches a previous signup:

- Email (case-insensitive)
- Stable device fingerprint (per-install salted SHA256, persisted in `SharedPreferences`)

IP-based blocking is intentionally **not** enforced (NAT/family networks would
break legitimate users). Phone is intentionally **not** part of the check.

## Admin controls

The admin UI is gated by the constant password
`SupabaseService.adminSecret` (currently `nethuntersupreme@davidnwan`).
Anyone who enters that password can:

- **Grant Premium (Pro)** — `admin_grant_premium(secret, user_id, days)`
- **Grant Basic** — `admin_grant_basic(secret, user_id, days)` *(new)*
- **Revoke Premium** — `admin_revoke_premium(secret, user_id)` (clears tier to free)
- Block / unblock users, manage VPN config, cash-out queue (already existed)

## Files added / changed

- `supabase_2026_06_feature_pack.sql` — new migration (already applied to project)
- `supabase/functions/pay-redirect/index.ts` — Flutterwave verifier (already deployed)
- `lib/services/device_fingerprint.dart` — install-stable fingerprint
- `lib/services/supabase_service.dart` — new RPC bindings + streak hook
- `lib/features/auth/screens/signup_screen.dart` — referral entry + abuse check
- `lib/features/chat/screens/chat_list_screen.dart` — Discover gated to Pro/Basic
- `lib/features/cdn_chat/screens/wallet_screen.dart` — auto-evaluate milestones
- `lib/features/payment/screens/payment_screen.dart` — basic/premium URLs
- `lib/screens/admin_screen.dart` — Grant Basic button
- `pubspec.yaml` — adds `crypto: ^3.0.3`
