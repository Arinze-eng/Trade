// WormGPT powered by aichatting.net free API
// No API key needed — uses the free tier
const fetch = require('node-fetch');
const https = require('https');

const AICHATTING_API = 'https://aga-api.aichatting.net';
const CHAT_ENDPOINT = `${AICHATTING_API}/aigc/chat`;

async function chatWormGPT(message, history = []) {
  const payload = { content: message };
  
  try {
    // Use AbortController for timeout (Node 18+)
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 60000);
    
    const resp = await fetch(CHAT_ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal: controller.signal,
      agent: new https.Agent({ rejectUnauthorized: false })
    });
    
    clearTimeout(timeoutId);

    const data = await resp.json();
    
    if (data.code !== 0 || data.message !== 'success') {
      throw new Error(`Aichatting API error: ${JSON.stringify(data)}`);
    }

    return {
      reply: data.data.replyContent,
      sessionId: data.data.sessionId
    };
  } catch (err) {
    if (err.name === 'AbortError') {
      throw new Error('Request timed out after 60s');
    }
    console.error('WormGPT chat error:', err.message);
    throw err;
  }
}

async function checkFreeCredits() {
  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 10000);
    
    const resp = await fetch(`${AICHATTING_API}/aigc/chat/user/free-count`, {
      signal: controller.signal
    });
    clearTimeout(timeoutId);
    
    const data = await resp.json();
    return data.data || 0;
  } catch (err) {
    console.error('Check credits error:', err.message);
    return 0;
  }
}

module.exports = { chatWormGPT, checkFreeCredits };
