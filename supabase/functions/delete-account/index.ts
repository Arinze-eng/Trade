// Supabase Edge Function: delete-account
// Deletes the currently authenticated user and cleans up related rows.
//
// Deploy with:
//   supabase functions deploy delete-account
//
// Requires secrets:
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY
//
// Client must call with Authorization: Bearer <user_jwt>

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey);

    // Build a user-scoped client from the incoming JWT to identify caller
    const authHeader = req.headers.get("Authorization") || "";
    const jwt = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : null;
    if (!jwt) {
      return new Response(JSON.stringify({ error: "Missing Authorization bearer token" }), { status: 401 });
    }

    // Identify the caller from the JWT.
    const { data: userData, error: userErr } = await supabaseAdmin.auth.getUser(jwt);
    if (userErr || !userData?.user) {
      return new Response(JSON.stringify({ error: "Invalid user session" }), { status: 401 });
    }

    const userId = userData.user.id;

    // Cleanup related rows (best effort).
    // NOTE: Ensure tables exist in your schema; errors are ignored per-table.
    const cleanupOps = [
      () => supabaseAdmin.from('user_blocks').delete().or(`blocker_id.eq.${userId},blocked_id.eq.${userId}`),
      () => supabaseAdmin.from('group_members').delete().eq('user_id', userId),
      () => supabaseAdmin.from('group_messages').delete().eq('sender_id', userId),
      () => supabaseAdmin.from('messages').delete().or(`sender_id.eq.${userId},receiver_id.eq.${userId}`),
      () => supabaseAdmin.from('fcm_tokens').delete().eq('user_id', userId),
      () => supabaseAdmin.from('status').delete().eq('user_id', userId),
      () => supabaseAdmin.from('status_likes').delete().eq('user_id', userId),
      () => supabaseAdmin.from('status_replies').delete().eq('user_id', userId),
      () => supabaseAdmin.from('profiles').delete().eq('id', userId),
    ];

    for (const op of cleanupOps) {
      try { await op(); } catch (_) {}
    }

    // Finally delete auth user
    const { error: delErr } = await supabaseAdmin.auth.admin.deleteUser(userId);
    if (delErr) {
      return new Response(JSON.stringify({ error: delErr.message }), { status: 500 });
    }

    return new Response(JSON.stringify({ success: true }));
  } catch (e) {
    return new Response(JSON.stringify({ error: (e as Error).message }), { status: 500 });
  }
});
