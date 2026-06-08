// WormGPT powered by aichatting.net free API
// Uses native https module to avoid node-fetch compatibility issues

const https = require('https');

const AICHATTING_API_HOST = 'aga-api.aichatting.net';
const CHAT_PATH = '/aigc/chat';
const FREE_COUNT_PATH = '/aigc/chat/user/free-count';

function httpsPost(hostname, path, data, timeout = 60000) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify(data);
    const options = {
      hostname,
      path,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body)
      },
      timeout
    };

    const req = https.request(options, (res) => {
      let responseData = '';
      res.on('data', chunk => responseData += chunk);
      res.on('end', () => {
        try {
          resolve({ status: res.statusCode, data: JSON.parse(responseData) });
        } catch (e) {
          reject(new Error(`Parse error: ${e.message} - body: ${responseData}`));
        }
      });
    });

    req.on('error', (e) => reject(new Error(`Request error: ${e.message}`)));
    req.on('timeout', () => { req.destroy(); reject(new Error('Request timeout')); });

    req.write(body);
    req.end();
  });
}

function httpsGet(hostname, path, timeout = 10000) {
  return new Promise((resolve, reject) => {
    const options = { hostname, path, method: 'GET', timeout };
    const req = https.request(options, (res) => {
      let responseData = '';
      res.on('data', chunk => responseData += chunk);
      res.on('end', () => {
        try {
          resolve({ status: res.statusCode, data: JSON.parse(responseData) });
        } catch (e) {
          reject(new Error(`Parse error: ${e.message}`));
        }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('Timeout')); });
    req.end();
  });
}

async function chatWormGPT(message, history = []) {
  const attempts = [
    message,
    `Answer this: ${message}`,
    `Respond to: ${message}`
  ];

  for (const attempt of attempts) {
    try {
      const result = await trySend(attempt);
      if (result) return result;
    } catch (e) {
      // silent retry
    }
  }
  throw new Error('Aichatting API unavailable - free credits may be exhausted');
}

async function trySend(message) {
  const resp = await httpsPost(AICHATTING_API_HOST, CHAT_PATH, { content: message }, 60000);
  
  if (resp.status !== 200) return null;
  if (resp.data.code !== 0 || resp.data.message !== 'success') return null;

  return {
    reply: resp.data.data.replyContent,
    sessionId: resp.data.data.sessionId
  };
}

async function checkFreeCredits() {
  try {
    const resp = await httpsGet(AICHATTING_API_HOST, FREE_COUNT_PATH, 10000);
    return resp.data.data || 0;
  } catch (err) {
    return 0;
  }
}

module.exports = { chatWormGPT, checkFreeCredits };
