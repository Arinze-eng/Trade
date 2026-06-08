// HackerX v7 - Database layer using Supabase (Postgres) instead of SQLite
const { createClient } = require('@supabase/supabase-js');
const path = require('path');
const fs = require('fs');

// Hardcoded defaults for Supabase connection
// These are public anon keys (safe to embed) — actual secrets go in env vars
const DEFAULT_SUPABASE_URL = 'https://swskpsojexcktlwweqfz.supabase.co';
const DEFAULT_SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN3c2twc29qZXhja3Rsd3dlcWZ6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAzOTk0MTksImV4cCI6MjA5NTk3NTQxOX0.x67EmSn4UDe_3wnd1XKUrL0dn8GXWSPlhVK_fcoCZVo';

const SUPABASE_URL = process.env.SUPABASE_URL || DEFAULT_SUPABASE_URL;
const SUPABASE_SERVICE_KEY = process.env.SUPABASE_ANON_KEY || process.env.SUPABASE_SERVICE_KEY || DEFAULT_SUPABASE_ANON_KEY;

let supabase = null;

function getSupabase() {
  if (supabase) return supabase;
  supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
    auth: {
      autoRefreshToken: false,
      persistSession: false
    }
  });
  return supabase;
}

// ── Helper: normalize created_at to match old SQLite format ──
function nowISO() {
  return new Date().toISOString().replace('T', ' ').split('.')[0]; // "2026-06-02 12:30:00"
}

// ── User Operations ──

async function createUser({ id, email, password, username, role = 'user', subscription_status = 'trialing', trial_start, trial_end }) {
  const { data, error } = await getSupabase()
    .from('users')
    .insert({
      id, email, password, username, role,
      blocked: 0,
      subscription_status,
      trial_start: trial_start || nowISO(),
      trial_end,
      created_at: nowISO(),
      updated_at: nowISO()
    })
    .select()
    .single();
  if (error) throw new Error(error.message);
  return data;
}

async function getUserByEmail(email) {
  const { data, error } = await getSupabase()
    .from('users')
    .select('*')
    .ilike('email', email)
    .maybeSingle();
  if (error) throw new Error(error.message);
  return data;
}

async function getUserById(id) {
  const { data, error } = await getSupabase()
    .from('users')
    .select('*')
    .eq('id', id)
    .maybeSingle();
  if (error) throw new Error(error.message);
  return data;
}

async function getAllUsers() {
  const { data, error } = await getSupabase()
    .from('users')
    .select('id, email, username, role, blocked, subscription_status, subscription_plan, trial_end, created_at, last_seen')
    .order('created_at', { ascending: false });
  if (error) throw new Error(error.message);
  return data || [];
}

async function updateUser(id, updates) {
  const { data, error } = await getSupabase()
    .from('users')
    .update({ ...updates, updated_at: nowISO() })
    .eq('id', id)
    .select()
    .single();
  if (error) throw new Error(error.message);
  return data;
}

async function deleteUser(id) {
  const { error } = await getSupabase()
    .from('users')
    .delete()
    .eq('id', id);
  if (error) throw new Error(error.message);
  return true;
}

async function checkEmailExists(email) {
  const { data, error } = await getSupabase()
    .from('users')
    .select('id')
    .ilike('email', email)
    .maybeSingle();
  if (error) throw new Error(error.message);
  return !!data;
}

// ── IP Registry (anti-loot) ──

async function addIpRegistry({ ip_address, fingerprint, email, user_id }) {
  const { error } = await getSupabase()
    .from('ip_registry')
    .insert({ ip_address, fingerprint, email, user_id, created_at: nowISO() });
  if (error) throw new Error(error.message);
}

async function getIpCountByIp(ip_address) {
  const { count, error } = await getSupabase()
    .from('ip_registry')
    .select('*', { count: 'exact', head: true })
    .eq('ip_address', ip_address);
  if (error) throw new Error(error.message);
  return count;
}

async function getIpCountByFingerprint(fingerprint) {
  const { count, error } = await getSupabase()
    .from('ip_registry')
    .select('*', { count: 'exact', head: true })
    .eq('fingerprint', fingerprint);
  if (error) throw new Error(error.message);
  return count;
}

// ── Payments ──

async function createPayment({ id, user_id, amount, currency, plan, status = 'pending' }) {
  const { data, error } = await getSupabase()
    .from('payments')
    .insert({ id, user_id, amount, currency, plan, status, created_at: nowISO() })
    .select()
    .single();
  if (error) throw new Error(error.message);
  return data;
}

async function getPaymentById(id) {
  const { data, error } = await getSupabase()
    .from('payments')
    .select('*')
    .eq('id', id)
    .maybeSingle();
  if (error) throw new Error(error.message);
  return data;
}

async function updatePayment(id, updates) {
  const { data, error } = await getSupabase()
    .from('payments')
    .update(updates)
    .eq('id', id)
    .select()
    .single();
  if (error) throw new Error(error.message);
  return data;
}

async function getAllPayments() {
  const { data, error } = await getSupabase()
    .from('payments')
    .select('*, users!inner(username, email)')
    .order('created_at', { ascending: false });
  if (error) throw new Error(error.message);
  return data || [];
}

// ── API Keys ──

async function seedApiKeys(keysArray) {
  for (const key of keysArray) {
    const trimmed = key.trim();
    if (!trimmed) continue;
    const { error } = await getSupabase()
      .from('api_keys')
      .insert({ key_value: trimmed, provider: 'cloudflare', is_active: 1, total_requests: 0, created_at: nowISO() })
      .maybeSingle(); // ignore conflicts
    if (error && !error.message.includes('duplicate')) {
      console.error('Seed key error:', error.message);
    }
  }
}

async function getNextApiKey() {
  const now = nowISO();
  const { data, error } = await getSupabase()
    .from('api_keys')
    .select('*')
    .eq('is_active', 1)
    .or(`rate_limited_until.is.null,rate_limited_until.lt.${now}`)
    .order('total_requests', { ascending: true })
    .limit(1)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) {
    const { data: fb } = await getSupabase()
      .from('api_keys')
      .select('*')
      .eq('is_active', 1)
      .limit(1)
      .maybeSingle();
    return fb ? fb.key_value : null;
  }
  await getSupabase()
    .from('api_keys')
    .update({ total_requests: (data.total_requests || 0) + 1, last_used: nowISO() })
    .eq('id', data.id);
  return data.key_value;
}

async function markApiKeyRateLimited(keyValue, cooldownMinutes = 1) {
  const until = new Date(Date.now() + cooldownMinutes * 60 * 1000).toISOString();
  const { error } = await getSupabase()
    .from('api_keys')
    .update({ rate_limited_until: until })
    .eq('key_value', keyValue);
  if (error) console.error('Mark rate limited error:', error.message);
}

async function getAllApiKeys() {
  const { data, error } = await getSupabase()
    .from('api_keys')
    .select('*')
    .order('created_at', { ascending: true });
  if (error) throw new Error(error.message);
  return data || [];
}

async function toggleApiKey(id, active) {
  const { error } = await getSupabase()
    .from('api_keys')
    .update({ is_active: active ? 1 : 0 })
    .eq('id', id);
  if (error) throw new Error(error.message);
}

async function addApiKey(keyValue, provider = 'cloudflare') {
  const { error } = await getSupabase()
    .from('api_keys')
    .insert({ key_value: keyValue, provider, is_active: 1, total_requests: 0, created_at: nowISO() });
  if (error && !error.message.includes('duplicate')) throw new Error(error.message);
}

// ── Chat History ──

async function saveChatMessage({ id, user_id, role, content }) {
  const { error } = await getSupabase()
    .from('chat_history')
    .insert({ id, user_id, role, content, created_at: nowISO() });
  if (error) console.error('Save chat error:', error.message);
}

// ── Image Generation Daily Count ──

async function saveImageGeneration(user_id) {
  const { error } = await getSupabase()
    .from('image_generations')
    .insert({ user_id, created_at: nowISO() });
  if (error) console.error('Save image gen error:', error.message);
}

async function getImageCountToday(user_id) {
  const today = new Date().toISOString().split('T')[0]; // YYYY-MM-DD
  const { count, error } = await getSupabase()
    .from('image_generations')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', user_id)
    .gte('created_at', today);
  if (error) {
    console.error('Image count error:', error.message);
    return 0;
  }
  return count || 0;
}

// ── Terminal Files ──

async function saveTerminalFile({ id, user_id, filename, filepath, filesize, mime_type }) {
  const { error } = await getSupabase()
    .from('terminal_files')
    .insert({ id, user_id, filename, filepath, filesize, mime_type, created_at: nowISO() });
  if (error) console.error('Save terminal file error:', error.message);
}

async function getTerminalFilesByUser(user_id) {
  const { data, error } = await getSupabase()
    .from('terminal_files')
    .select('id, filename, filesize, mime_type, created_at')
    .eq('user_id', user_id)
    .order('created_at', { ascending: false })
    .limit(50);
  if (error) throw new Error(error.message);
  return data || [];
}

async function getAllTerminalFilenames() {
  const { data, error } = await getSupabase()
    .from('terminal_files')
    .select('filename');
  if (error) throw new Error(error.message);
  return (data || []).map(r => r.filename);
}

async function seedAdmin() {
  const existing = await getUserByEmail('admin@hackerx.io');
  if (existing) return;
  const bcrypt = require('bcryptjs');
  const { v4: uuidv4 } = require('uuid');
  const hash = bcrypt.hashSync('admin123', 10);
  const id = uuidv4();
  await createUser({
    id,
    email: 'admin@hackerx.io',
    password: hash,
    username: 'Admin',
    role: 'admin',
    subscription_status: 'active',
    trial_start: nowISO(),
    trial_end: new Date(Date.now() + 999 * 365 * 24 * 60 * 60 * 1000).toISOString()
  });
  console.log('✅ Admin user seeded');
}

// ── Uptime Monitor ──

async function createUptimeMonitor({ id, user_id, url, interval_seconds }) {
  const { error } = await getSupabase()
    .from('url_monitors')
    .insert({ id, user_id, url, interval_seconds, paused: false, ping_count: 0, created_at: nowISO() });
  if (error) throw new Error(error.message);
}

async function getUptimeMonitors(user_id) {
  const { data, error } = await getSupabase()
    .from('url_monitors')
    .select('*')
    .eq('user_id', user_id)
    .order('created_at', { ascending: false });
  if (error) throw new Error(error.message);
  return data || [];
}

async function getUptimeMonitorById(id) {
  const { data, error } = await getSupabase()
    .from('url_monitors')
    .select('*')
    .eq('id', id)
    .maybeSingle();
  if (error) throw new Error(error.message);
  return data;
}

async function updateUptimeMonitor(id, updates) {
  const { error } = await getSupabase()
    .from('url_monitors')
    .update({ ...updates, updated_at: nowISO() })
    .eq('id', id);
  if (error) throw new Error(error.message);
}

async function deleteUptimeMonitor(id) {
  const { error } = await getSupabase()
    .from('url_monitors')
    .delete()
    .eq('id', id);
  if (error) throw new Error(error.message);
}

async function getAllActiveMonitors() {
  const { data, error } = await getSupabase()
    .from('url_monitors')
    .select('*')
    .eq('paused', false);
  if (error) throw new Error(error.message);
  return data || [];
}

// ── Uptime Monitor Logs ──

async function saveUptimeLog({ monitor_id, user_id, url, status, response_ms, status_code }) {
  const { error } = await getSupabase()
    .from('url_monitor_logs')
    .insert({ monitor_id, user_id, url, status, response_ms, status_code, created_at: nowISO() });
  if (error) throw new Error(error.message);
}

async function getUptimeLogs(user_id, limit = 50) {
  const { data, error } = await getSupabase()
    .from('url_monitor_logs')
    .select('*')
    .eq('user_id', user_id)
    .order('created_at', { ascending: false })
    .limit(limit);
  if (error) throw new Error(error.message);
  return data || [];
}

async function getRecentUptimeEvents(sinceId = 0, user_id = null) {
  let query = getSupabase()
    .from('url_monitor_logs')
    .select('*')
    .gt('id', sinceId)
    .order('created_at', { ascending: false })
    .limit(20);
  if (user_id) query = query.eq('user_id', user_id);
  const { data, error } = await query;
  if (error) throw new Error(error.message);
  return data || [];
}

async function getActiveMonitorCount(user_id) {
  const { count, error } = await getSupabase()
    .from('url_monitors')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', user_id)
    .eq('paused', false);
  if (error) throw new Error(error.message);
  return count || 0;
}

// ── API Key Test helpers (stored in Supabase) ──

async function saveApiKeyTest(userId, provider) {
  const sb = getSupabase();
  const { error } = await sb.from('api_key_tests').insert({
    user_id: userId,
    provider: provider || 'unknown',
    created_at: nowISO()
  });
  if (error) throw new Error(error.message);
}

async function getApiKeyTestCountToday(userId) {
  const sb = getSupabase();
  const todayStart = new Date();
  todayStart.setHours(0, 0, 0, 0);
  const todayISO = todayStart.toISOString();
  const { data, error } = await sb.from('api_key_tests')
    .select('id', { count: 'exact' })
    .eq('user_id', userId)
    .gte('created_at', todayISO);
  if (error) throw new Error(error.message);
  return data.length || 0;
}

// ── Image Detection helpers ──
async function saveImageDetection(userId) {
  const sb = getSupabase();
  const { error } = await sb.from('image_detections').insert({
    user_id: userId,
    created_at: nowISO()
  });
  if (error) throw new Error(error.message);
}

async function getImageDetectionCountToday(userId) {
  const sb = getSupabase();
  const todayStart = new Date();
  todayStart.setHours(0, 0, 0, 0);
  const todayISO = todayStart.toISOString();
  const { data, error } = await sb.from('image_detections')
    .select('id', { count: 'exact' })
    .eq('user_id', userId)
    .gte('created_at', todayISO);
  if (error) throw new Error(error.message);
  return data.length || 0;
}

// ── Telegram Channel Joiner (1 per day) ──

async function saveTelegramJoin(userId, username) {
  const sb = getSupabase();
  const { error } = await sb.from('telegram_joins').insert({
    user_id: userId,
    username: username,
    created_at: nowISO()
  });
  if (error) throw new Error(error.message);
}

async function getTelegramJoinCountToday(userId) {
  const sb = getSupabase();
  const todayStart = new Date();
  todayStart.setHours(0, 0, 0, 0);
  const todayISO = todayStart.toISOString();
  const { data, error } = await sb.from('telegram_joins')
    .select('id', { count: 'exact' })
    .eq('user_id', userId)
    .gte('created_at', todayISO);
  if (error) throw new Error(error.message);
  return data.length || 0;
}

async function getTelegramJoinCountAll(userId) {
  const sb = getSupabase();
  const { data, error } = await sb.from('telegram_joins')
    .select('id', { count: 'exact' })
    .eq('user_id', userId);
  if (error) throw new Error(error.message);
  return data.length || 0;
}

// ── EvilGPT Usage (15/day free, unlimited for premium/pro) ──

async function saveEvilGptUsage(userId) {
  const sb = getSupabase();
  const { error } = await sb.from('evilgpt_usage').insert({
    user_id: userId,
    created_at: nowISO()
  });
  if (error) throw new Error(error.message);
}

async function getEvilGptUsageCountToday(userId) {
  const sb = getSupabase();
  const todayStart = new Date();
  todayStart.setHours(0, 0, 0, 0);
  const todayISO = todayStart.toISOString();
  const { data, error } = await sb.from('evilgpt_usage')
    .select('id', { count: 'exact' })
    .eq('user_id', userId)
    .gte('created_at', todayISO);
  if (error) throw new Error(error.message);
  return data.length || 0;
}


module.exports = {
  getSupabase,
  createUser, getUserByEmail, getUserById, getAllUsers, updateUser, deleteUser, checkEmailExists,
  addIpRegistry, getIpCountByIp, getIpCountByFingerprint,
  createPayment, getPaymentById, updatePayment, getAllPayments,
  seedApiKeys, getNextApiKey, markApiKeyRateLimited, getAllApiKeys, toggleApiKey, addApiKey,
  saveChatMessage, saveTerminalFile, getTerminalFilesByUser, getAllTerminalFilenames,
  saveImageGeneration, getImageCountToday,
  seedAdmin, nowISO,
  createUptimeMonitor, getUptimeMonitors, getUptimeMonitorById, updateUptimeMonitor, deleteUptimeMonitor, getAllActiveMonitors,
  saveUptimeLog, getUptimeLogs, getRecentUptimeEvents, getActiveMonitorCount,
  saveApiKeyTest, getApiKeyTestCountToday,
  saveImageDetection, getImageDetectionCountToday,
  saveTelegramJoin, getTelegramJoinCountToday, getTelegramJoinCountAll,
  saveEvilGptUsage, getEvilGptUsageCountToday,
};