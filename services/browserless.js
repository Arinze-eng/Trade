// HackerX v7 - Browserless.io integration for real web browsing
// Uses Browserless.io headless browser API to take screenshots and scrape content
// Falls back to cheerio-based scraping when Browserless is unavailable
const fetch = require('node-fetch');
const cheerio = require('cheerio');

const BROWSERLESS_API_KEY = process.env.BROWSERLESS_API_KEY || '3CuFr4R7KmBjj3HsGJj7Fs4ItJL_5YkbuyRLURaAANesSLgrT';
const BROWSERLESS_ENDPOINT = 'https://chrome.browserless.io';

let _browserlessAvailable = null;

/**
 * Check if Browserless API is available (has valid paid key)
 */
async function isAvailable() {
  if (_browserlessAvailable !== null) return _browserlessAvailable;
  try {
    const payload = {
      url: 'https://example.com',
      options: { waitFor: 1000, rejectResourceTypes: ['image', 'media', 'font', 'stylesheet'] },
    };
    const resp = await fetch(`${BROWSERLESS_ENDPOINT}/scrape?token=${BROWSERLESS_API_KEY}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      timeout: 10000,
    });
    if (resp.ok) {
      _browserlessAvailable = true;
    } else {
      const text = await resp.text().catch(() => '');
      if (text.includes('sign-up') || text.includes('paid account')) {
        _browserlessAvailable = false;
      } else if (resp.status === 401 || resp.status === 403) {
        _browserlessAvailable = false;
      } else {
        _browserlessAvailable = true;
      }
    }
  } catch (e) {
    _browserlessAvailable = false;
  }
  return _browserlessAvailable;
}

/**
 * Fallback: scrape using cheerio (no browserless)
 */
async function fallbackScrape(url) {
  const targetUrl = url.startsWith('http') ? url : `https://${url}`;
  const resp = await fetch(targetUrl, {
    headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      'Accept-Language': 'en-US,en;q=0.9',
    },
    timeout: 15000,
  });
  const html = await resp.text();
  const $ = cheerio.load(html);

  const title = $('title').text().trim();
  const description = $('meta[name="description"]').attr('content') || '';
  $('script, style, nav, footer, header, aside, noscript').remove();
  const bodyText = $('body').text().replace(/\s+/g, ' ').trim().slice(0, 6000);

  const links = [];
  $('a[href]').each((i, el) => {
    const href = $(el).attr('href');
    const text = $(el).text().trim().slice(0, 80);
    if (href && !href.startsWith('#') && !href.startsWith('javascript:')) {
      try {
        const fullUrl = href.startsWith('http') ? href : new URL(href, targetUrl).href;
        links.push({ text, href: fullUrl });
      } catch(e) {}
    }
  });

  return { title, description, text: bodyText, links: links.slice(0, 20) };
}

/**
 * Fallback: Bing web search via cheerio
 */
async function fallbackWebSearch(query) {
  const resp = await fetch(`https://www.bing.com/search?q=${encodeURIComponent(query)}&setlang=en`, {
    headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept-Language': 'en-US,en;q=0.9'
    },
    timeout: 15000,
  });
  const html = await resp.text();
  const $ = cheerio.load(html);
  let results = '';
  $('.b_algo').slice(0, 5).each((i, el) => {
    const title = $(el).find('h2 a').text().trim();
    const snippet = $(el).find('.b_caption p').text().trim();
    if (title) results += `- ${title}\n`;
    if (snippet) results += `  ${snippet}\n\n`;
  });
  return results || 'No search results found';
}

/**
 * Take a full-page screenshot of a URL using Browserless.io
 */
async function screenshotUrl(url, options = {}) {
  const available = await isAvailable();
  if (!available) throw new Error('Browserless screenshots require a paid Browserless plan');

  const { width = 1280, height = 800 } = options;
  const payload = {
    url: url.startsWith('http') ? url : `https://${url}`,
    options: { type: 'jpeg', quality: 85, fullPage: true, omitBackground: true },
    viewport: { width, height },
  };

  const resp = await fetch(`${BROWSERLESS_ENDPOINT}/screenshot?token=${BROWSERLESS_API_KEY}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
    timeout: 30000,
  });

  if (!resp.ok) {
    const text = await resp.text().catch(() => '');
    throw new Error(`Browserless screenshot error (${resp.status}): ${text.slice(0, 200)}`);
  }

  const buffer = await resp.buffer();
  return `data:image/jpeg;base64,${buffer.toString('base64')}`;
}

/**
 * Scrape content from a URL (Browserless preferred, fallback to cheerio)
 */
async function scrapeUrl(url) {
  const available = await isAvailable();
  if (!available) return await fallbackScrape(url);

  const targetUrl = url.startsWith('http') ? url : `https://${url}`;
  const payload = {
    url: targetUrl,
    options: {
      waitFor: 2000,
      rejectResourceTypes: ['image', 'media', 'font', 'stylesheet'],
      setExtraHTTPHeaders: {
        'Accept-Language': 'en-US,en;q=0.9',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
      },
    },
  };

  const resp = await fetch(`${BROWSERLESS_ENDPOINT}/scrape?token=${BROWSERLESS_API_KEY}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
    timeout: 30000,
  });

  if (!resp.ok) {
    return await fallbackScrape(url);
  }

  return await resp.json();
}

/**
 * Web search (Browserless preferred, fallback to cheerio)
 */
async function webSearchViaBrowserless(query) {
  const searchUrl = `https://www.bing.com/search?q=${encodeURIComponent(query)}&setlang=en`;

  try {
    const scrapedData = await scrapeUrl(searchUrl);
    let results = '';
    if (scrapedData && scrapedData.text) {
      const lines = scrapedData.text.split('\n');
      for (const line of lines) {
        const trimmed = line.trim();
        if (trimmed.length > 15) results += trimmed + '\n';
      }
    }
    if (results.length > 50) return results.slice(0, 6000);
  } catch (e) {}

  return await fallbackWebSearch(query);
}

/**
 * Browse a URL: scrape + screenshot
 */
async function browseUrl(url) {
  const scrapedData = await scrapeUrl(url);

  let screenshot = null;
  try {
    screenshot = await screenshotUrl(url);
  } catch (e) {}

  let content = '';
  if (scrapedData) {
    if (scrapedData.title) content += `# ${scrapedData.title}\n\n`;
    if (scrapedData.description) content += `Description: ${scrapedData.description}\n\n`;
    if (scrapedData.text) content += scrapedData.text.slice(0, 8000);
    if (scrapedData.links && Array.isArray(scrapedData.links) && scrapedData.links.length > 0) {
      content += '\n\n--- Links ---\n';
      scrapedData.links.slice(0, 20).forEach(link => {
        if (link.text || link.href) content += `- ${link.text || ''}: ${link.href}\n`;
      });
    }
  }

  return { text: content || '(No content extracted)', screenshot };
}

module.exports = { screenshotUrl, scrapeUrl, webSearchViaBrowserless, browseUrl, isAvailable };