// Hackers Ai Everywhere v8 - Auth routes using Supabase backend
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { v4: uuidv4 } = require('uuid');
const fetch = require('node-fetch');
const db = require('../db');

const JWT_SECRET = process.env.JWT_SECRET || 'change_me_jwt_secret';
const TRIAL_DAYS = parseInt(process.env.TRIAL_DAYS || '2');
const ANTI_LOOT_FP_LIMIT = 1;

// ── Flutterwave config ──
const FLW_SECRET_KEY = process.env.FLW_SECRET_KEY || '';
const FLW_PUBLIC_KEY = process.env.FLW_PUBLIC_KEY || '';
const FLW_BASIC_LINK = process.env.FLW_BASIC_LINK || 'https://flutterwave.com/pay/hhpuddzjsfrf';
const FLW_PRO_LINK = process.env.FLW_PRO_LINK || 'https://flutterwave.com/pay/xhceft1fdei1';

function getBaseUrl(req) {
  const proto = req.headers['x-forwarded-proto'] || req.protocol || 'https';
  const host = req.headers['x-forwarded-host'] || req.headers.host || 'localhost:10000';
  return `${proto}://${host}`;
}

// Plan pricing (in Naira)
const PLAN_PRICES = {
  basic: { amount: 20000, currency: 'NGN', label: 'Basic' },
  pro: { amount: 40000, currency: 'NGN', label: 'Pro' }
};

function normalizeEmail(email) {
  return (email || '').toLowerCase().trim();
}

function getClientIP(req) {
  return req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress || '0.0.0.0';
}

function isValidGmail(email) {
  return /^[a-zA-Z0-9._%+-]+@gmail\.com$/i.test(email);
}

// ── Signup ──
async function signup(req, res) {
  try {
    const { email, password, username, fingerprint } = req.body;
    if (!email || !password || !username) {
      return res.status(400).json({ error: 'Email, password, and username required' });
    }
    const normalizedEmail = normalizeEmail(email);
    if (!isValidGmail(normalizedEmail)) {
      return res.status(400).json({ error: 'Only Gmail addresses (@gmail.com) are allowed' });
    }
    if (password.length < 6) {
      return res.status(400).json({ error: 'Password must be at least 6 characters' });
    }
    if (username.length < 2) {
      return res.status(400).json({ error: 'Username must be at least 2 characters' });
    }

    // Check existing
    const existing = await db.getUserByEmail(normalizedEmail);
    if (existing) {
      return res.status(409).json({ error: 'Email already registered. Please sign in instead.' });
    }

    // Anti-loot check: one account per device (fingerprint) + IP fallback
    const clientIP = getClientIP(req);
    if (fingerprint) {
      const fpCount = await db.getIpCountByFingerprint(fingerprint);
      if (fpCount >= ANTI_LOOT_FP_LIMIT) {
        return res.status(429).json({ error: 'You already have an account on this device. Please sign in instead.' });
      }
    } else {
      // Fallback: check IP — limit 3 accounts per IP
      const ipCount = await db.getIpCountByIp(clientIP);
      if (ipCount >= 3) {
        return res.status(429).json({ error: 'Too many accounts from this network. Please sign in instead.' });
      }
    }

    const id = uuidv4();
    const hash = bcrypt.hashSync(password, 10);
    const trialEnd = new Date(Date.now() + TRIAL_DAYS * 24 * 60 * 60 * 1000).toISOString();

    const user = await db.createUser({
      id, email: normalizedEmail, password: hash, username,
      role: 'user', subscription_status: 'trialing',
      trial_start: new Date().toISOString(),
      trial_end: trialEnd
    });

    await db.addIpRegistry({ ip_address: clientIP, fingerprint: fingerprint || null, email: normalizedEmail, user_id: id });

    const token = jwt.sign({ id, email: normalizedEmail, username, role: 'user' }, JWT_SECRET, { expiresIn: '30d' });
    res.json({
      ok: true, token,
      user: { id, email: normalizedEmail, username, role: 'user', subscription_status: 'trialing', trial_end: trialEnd, blocked: 0 }
    });
  } catch (err) {
    console.error('Signup error:', err.message);
    res.status(500).json({ error: 'Signup failed. Please try again.' });
  }
}

// ── Login ──
async function login(req, res) {
  try {
    const { email, password } = req.body;
    if (!email || !password) return res.status(400).json({ error: 'Email and password required' });

    const normalizedEmail = normalizeEmail(email);
    const user = await db.getUserByEmail(normalizedEmail);
    if (!user) {
      return res.status(401).json({ error: 'No account found with this email. Did you sign up?' });
    }
    if (!bcrypt.compareSync(password, user.password)) {
      return res.status(401).json({ error: 'Incorrect password. Try again or reset your password.' });
    }
    if (user.blocked) return res.status(403).json({ error: 'Account blocked. Contact support.' });

    const token = jwt.sign(
      { id: user.id, email: user.email, username: user.username, role: user.role },
      JWT_SECRET, { expiresIn: '30d' }
    );
    res.json({
      ok: true, token,
      user: {
        id: user.id, email: user.email, username: user.username,
        role: user.role, subscription_status: user.subscription_status,
        trial_end: user.trial_end, subscription_plan: user.subscription_plan, blocked: user.blocked
      }
    });
  } catch (err) {
    console.error('Login error:', err.message);
    res.status(500).json({ error: 'Login failed. Please try again.' });
  }
}

// ── Get current user ──
async function me(req, res) {
  try {
    const user = await db.getUserById(req.user.id);
    if (!user) {
      // User exists in JWT but not in DB — could be DB issue
      return res.json({ user: { id: req.user.id, email: req.user.email, username: req.user.username, role: req.user.role, subscription_status: 'trialing', blocked: 0 } });
    }
    if (user.blocked) return res.status(403).json({ error: 'Account blocked' });
    res.json({ user });
  } catch (err) {
    console.error('me error:', err.message);
    // DB error — return cached JWT data so user stays logged in
    res.json({ user: { id: req.user.id, email: req.user.email, username: req.user.username, role: req.user.role, subscription_status: 'trialing', blocked: 0 } });
  }
}

// ── Helper: check if subscription has expired (>30 days from payment) ──
async function checkAndRevertExpiredSub(user) {
  if (!user) return;
  // Already free — nothing to do
  if (user.subscription_status !== 'active' && user.subscription_status !== 'trialing') return;

  // Check trial expiry
  if (user.subscription_status === 'trialing' && user.trial_end) {
    if (new Date(user.trial_end) <= new Date()) {
      console.log(`⏰ Trial expired for user ${user.id}, reverting to free`);
      await db.updateUser(user.id, { subscription_status: 'free', subscription_plan: null }).catch(() => {});
      user.subscription_status = 'free';
      user.subscription_plan = null;
    }
    return;
  }

  // Check subscription expiry (30 days from subscription_start, or from last_seen, or from user.created_at)
  if (user.subscription_status === 'active') {
    const subStart = user.subscription_start ? new Date(user.subscription_start) : null;
    const created = user.created_at ? new Date(user.created_at.replace(' ', 'T') + 'Z') : null;
    const refDate = subStart || created;
    if (refDate) {
      const daysSince = (Date.now() - refDate.getTime()) / (1000 * 60 * 60 * 24);
      if (daysSince >= 30) {
        console.log(`⏰ Subscription expired for user ${user.id} (${Math.round(daysSince)} days), reverting to free`);
        await db.updateUser(user.id, { subscription_status: 'free', subscription_plan: null }).catch(() => {});
        user.subscription_status = 'free';
        user.subscription_plan = null;
      }
    }
  }
}

// ── Check if user has premium features ──
async function checkPremium(userId) {
  try {
    const user = await db.getUserById(userId);
    if (!user || user.blocked) return false;
    await checkAndRevertExpiredSub(user);
    if (user.role === 'admin') return true;
    if (user.subscription_status === 'active') return true;
    if (user.subscription_status === 'trialing' && user.trial_end) {
      if (new Date(user.trial_end) > new Date()) return true;
      await db.updateUser(user.id, { subscription_status: 'free', subscription_plan: null }).catch(() => {});
      return false;
    }
    return false;
  } catch (e) {
    console.error('checkPremium error:', e.message);
    return true;
  }
}

// ── Check if user has Pro features ──
async function checkPro(userId) {
  try {
    const user = await db.getUserById(userId);
    if (!user || user.blocked) return false;
    await checkAndRevertExpiredSub(user);
    if (user.role === 'admin') return true;
    if (user.subscription_status === 'active' && user.subscription_plan === 'pro') return true;
    return false;
  } catch (e) {
    console.error('checkPro error:', e.message);
    return false;
  }
}

// ── Create Flutterwave payment ──
async function createPayment(req, res) {
  try {
    const { plan } = req.body;
    if (!plan || !['basic', 'pro'].includes(plan)) {
      return res.status(400).json({ error: 'Plan must be "basic" or "pro"' });
    }

    const config = PLAN_PRICES[plan];
    const txRef = uuidv4();
    const paymentId = uuidv4();
    const user = await db.getUserById(req.user.id);

    await db.createPayment({
      id: paymentId, user_id: req.user.id,
      amount: config.amount, currency: config.currency,
      plan, status: 'pending'
    });

    const redirectUrl = `${getBaseUrl(req)}/api/payment/callback?payment_id=${paymentId}&tx_ref=${txRef}`;

    let checkoutUrl = plan === 'pro' ? FLW_PRO_LINK : FLW_BASIC_LINK;
    const separator = checkoutUrl.includes('?') ? '&' : '?';
    checkoutUrl = `${checkoutUrl}${separator}payment_id=${paymentId}&tx_ref=${txRef}`;

    res.json({
      ok: true,
      payment_id: paymentId,
      tx_ref: txRef,
      amount: config.amount,
      currency: config.currency,
      plan,
      checkout_url: checkoutUrl,
      flw_public_key: FLW_PUBLIC_KEY
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
}

// ── Flutterwave payment callback ──
async function paymentCallback(req, res) {
  try {
    const { payment_id, tx_ref, transaction_id, status, simulate } = req.query;
    let payment = null;

    if (payment_id) {
      payment = await db.getPaymentById(payment_id);
    }
    if (!payment) {
      return res.status(404).send(`
        <html><body style="font-family:monospace;background:#0f0f0f;color:#ff3355;display:flex;align-items:center;justify-content:center;height:100vh">
        <h1>❌ Payment not found</h1></body></html>
      `);
    }

    let verified = false;
    // SECURITY: Must verify through Flutterwave — no simulate bypass
    if (transaction_id) {
      try {
        const verifyResp = await fetch(`https://api.flutterwave.com/v3/transactions/${transaction_id}/verify`, {
          headers: { 'Authorization': `Bearer ${FLW_SECRET_KEY}` }
        });
        const verifyData = await verifyResp.json();
        if (verifyData.status === 'success' && verifyData.data?.status === 'successful') {
          verified = true;
        }
      } catch (e) {
        console.error('Flutterwave verify error:', e.message);
      }
    }

    if (verified) {
      await db.updatePayment(payment.id, { status: 'completed' });
      await db.updateUser(payment.user_id, {
        subscription_status: 'active',
        subscription_plan: payment.plan,
        trial_end: null,
        subscription_start: db.nowISO()
      });

      if (tx_ref) {
        await db.updatePayment(payment.id, { stripe_payment_intent_id: tx_ref });
      }

      return res.send(`
        <html><head><title>Payment Complete - HackerX</title>
        <style>body{font-family:monospace;background:#212121;color:#00ff41;display:flex;align-items:center;justify-content:center;height:100vh;flex-direction:column;margin:0}
        h1{font-size:28px} p{color:#9e9e9e;font-size:14px} .btn{background:#10a37f;border:none;padding:12px 28px;border-radius:8px;color:#fff;cursor:pointer;font-family:monospace;font-size:15px;text-decoration:none;margin-top:20px;display:inline-block}
        .card{background:#2f2f2f;border:1px solid #424242;border-radius:16px;padding:32px;max-width:400px;text-align:center}</style></head>
        <body><div class="card">
        <div style="font-size:48px;margin-bottom:10px">✅</div>
        <h1>Payment Successful!</h1>
        <p>Upgraded to <strong>HackerX ${payment.plan === 'pro' ? 'Pro' : 'Basic'}</strong></p>
        <p style="font-size:12px;color:#6e6e6e">You can close this tab and return to HackerX.</p>
        <a class="btn" href="/">⬅ Back to HackerX</a>
        <script>setTimeout(()=>{try{window.opener?.postMessage({type:'payment_done',plan:'${payment.plan}'},'*')}catch(e){}window.close()},1500)</script>
        </div></body></html>
      `);
    } else {
      return res.send(`
        <html><body style="font-family:monospace;background:#212121;color:#ff3355;display:flex;align-items:center;justify-content:center;height:100vh;flex-direction:column">
        <h1>❌ Payment verification failed</h1>
        <p style="color:#9e9e9e">Please try again or contact support.</p>
        <a class="btn" href="/" style="background:#ff3355;margin-top:16px">⬅ Back to HackerX</a>
        </body></html>
      `);
    }
  } catch (err) {
    res.status(500).send('Payment error: ' + err.message);
  }
}

// ── Confirm payment ──
async function confirmPayment(req, res) {
  try {
    const { payment_id, transaction_id } = req.body;
    const payment = await db.getPaymentById(payment_id);
    if (!payment) return res.status(404).json({ error: 'Payment not found' });

    let verified = false;
    if (transaction_id) {
      try {
        const verifyResp = await fetch(`https://api.flutterwave.com/v3/transactions/${transaction_id}/verify`, {
          headers: { 'Authorization': `Bearer ${FLW_SECRET_KEY}` }
        });
        const verifyData = await verifyResp.json();
        if (verifyData.status === 'success' && verifyData.data?.status === 'successful') {
          verified = true;
        }
      } catch (e) {}
    }

    if (verified) {
      await db.updatePayment(payment_id, { status: 'completed' });
      await db.updateUser(payment.user_id, {
        subscription_status: 'active',
        subscription_plan: payment.plan,
        trial_end: null,
        subscription_start: db.nowISO()
      });
      return res.json({ ok: true, message: `Upgraded to HackerX ${payment.plan === 'pro' ? 'Pro' : 'Basic'}` });
    }

    return res.status(400).json({ error: 'Payment not verified' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
}

// ── Admin: List users ──
async function listUsers(req, res) {
  try {
    const users = await db.getAllUsers();
    res.json({ users });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
}

// ── Admin: List payments ──
async function listPayments(req, res) {
  try {
    const payments = await db.getAllPayments();
    res.json({ payments });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
}

// ── Admin: Update user subscription ──
async function updateUserSubscription(req, res) {
  try {
    const { user_id, status, plan } = req.body;
    const updates = {};
    if (status) updates.subscription_status = status;
    if (plan) updates.subscription_plan = plan;
    if (status === 'active') {
      updates.trial_end = null;
      updates.subscription_start = db.nowISO();
    }
    if (status === 'free') {
      updates.subscription_plan = null;
      updates.subscription_start = null;
    }
    if (Object.keys(updates).length) {
      await db.updateUser(user_id, updates);
    }
    res.json({ ok: true, message: 'User updated' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
}

// ── Admin: Block/unblock user ──
async function blockUser(req, res) {
  try {
    const { user_id, blocked } = req.body;
    await db.updateUser(user_id, { blocked: blocked ? 1 : 0 });
    res.json({ ok: true, message: blocked ? 'User blocked' : 'User unblocked' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
}

// ── Admin: Delete user ──
async function deleteUser(req, res) {
  try {
    const { user_id } = req.body;
    if (!user_id) return res.status(400).json({ error: 'User ID required' });
    await db.deleteUser(user_id);
    res.json({ ok: true, message: 'User deleted' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
}

module.exports = { signup, login, me, checkPremium, checkPro, createPayment, paymentCallback, confirmPayment, listUsers, listPayments, updateUserSubscription, blockUser, deleteUser, isValidGmail };