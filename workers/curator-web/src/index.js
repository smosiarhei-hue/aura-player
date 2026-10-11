const MAX_BYTES = 256_000;
const CACHE_MS = 15 * 60_000;
const json = (value, status = 200) => Response.json(value, {status, headers: {
  'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff'
}});

export function publicURL(value) {
  try {
    const url = new URL(value);
    const host = url.hostname.toLowerCase();
    if (url.protocol !== 'https:' || url.username || url.password || url.port ||
        !host.includes('.') || host.includes(':') || /^\d+(\.\d+){3}$/.test(host) ||
        /(^|\.)(localhost|local|internal|test|invalid)$/.test(host)) return null;
    url.hash = '';
    return url.href;
  } catch { return null; }
}
async function boundedText(response, maximum) {
  const reader = response.body?.getReader();
  if (!reader) return '';
  const chunks = []; let length = 0;
  try {
    for (;;) {
      const {value, done} = await reader.read();
      if (done) break;
      length += value.length;
      if (length > maximum) throw new Error('too_large');
      chunks.push(value);
    }
  } catch (error) { await reader.cancel(); throw error; }
  const bytes = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return new TextDecoder().decode(bytes);
}
export async function queryFirecrawl(query, key, transport = fetch) {
  const response = await transport('https://api.firecrawl.dev/v2/search', {
    method: 'POST', signal: AbortSignal.timeout(18_000), redirect: 'error',
    headers: {'Authorization': `Bearer ${key}`, 'Content-Type': 'application/json'},
    body: JSON.stringify({query, limit: 3, sources: ['web'], safe: true, timeout: 15000,
      scrapeOptions: {formats: ['markdown'], onlyMainContent: true}})
  });
  // Never forward upstream headers, keys, raw error body or billable debug fields.
  if (response.status === 429 || response.status === 402) return json({error:'quota'}, 429);
  if (!response.ok) return json({error:'upstream_unavailable'}, 502);
  const raw = JSON.parse(await boundedText(response, MAX_BYTES));
  if (raw.success !== true || !raw.data || !Array.isArray(raw.data.web)) return json({error:'invalid_upstream'}, 502);
  const seen = new Set(); const sources = [];
  for (const item of raw.data.web) {
    if (!item || typeof item !== 'object') continue;
    const url = publicURL(item.url);
    if (!url || seen.has(url)) continue;
    seen.add(url);
    sources.push({url, title: typeof item.title === 'string' ? item.title.slice(0,180) : new URL(url).hostname,
      excerpt: String(typeof item.markdown === 'string' ? item.markdown : (typeof item.description === 'string' ? item.description : '')).slice(0,3000)});
    if (sources.length === 3) break;
  }
  return json({sources});
}

export default {
  async fetch(request, env) {
    if (new URL(request.url).pathname !== '/search') return json({error:'not_found'}, 404);
    if (request.method !== 'POST') return json({error:'method_not_allowed'}, 405);
    if (!env.FIRECRAWL_API_KEY || !env.CURATOR_ACCESS_TOKEN || env.CURATOR_ACCESS_TOKEN.length < 32 || !env.SEARCH_GATE) {
      return json({error:'not_configured'}, 503);
    }
    const supplied = request.headers.get('Authorization') ?? '';
    // Compare fixed-length hashes, not a potentially leaking prefix comparison.
    const digest = async text => new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(text)));
    const [a,b] = await Promise.all([digest(supplied),digest(`Bearer ${env.CURATOR_ACCESS_TOKEN}`)]);
    let different = 0; for (let i=0;i<a.length;i++) different |= a[i] ^ b[i];
    if (different) return json({error:'unauthorized'}, 401);
    if (!(request.headers.get('Content-Type') ?? '').startsWith('application/json')) return json({error:'json_required'}, 415);
    let query;
    try {
      const raw = JSON.parse(await boundedText(request, 8000));
      if (Object.keys(raw).some(key => key !== 'query') || typeof raw.query !== 'string') throw new Error('invalid');
      query = raw.query.trim();
      if (!query || query.length > 1000) throw new Error('invalid');
    } catch { return json({error:'invalid_query'}, 400); }
    // Single personal deployment gate owns persistent budget/cache. No Yandex/AI credentials accepted.
    return env.SEARCH_GATE.get(env.SEARCH_GATE.idFromName('personal')).fetch(new Request('https://gate/search', {
      method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({query})
    }));
  }
};

export class SearchGate {
  constructor(state, env) { this.state = state; this.env = env; }
  async fetch(request) {
    try {
      const {query} = await request.json();
      if (typeof query !== 'string' || !query.trim() || query.length > 1000) return json({error:'invalid_query'},400);
      const now = Date.now();
      const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(query))))
        .map(byte => byte.toString(16).padStart(2,'0')).join('');
      const key = 'cache:' + hash;
      const reservation = await this.state.storage.transaction(async tx => {
        const cached = await tx.get(key);
        if (cached && now - cached.at < CACHE_MS) return {cached:cached.result};
        const day = Math.floor(now/86400000), minute = Math.floor(now/60000);
        const budget = await tx.get('budget') ?? {};
        const daily = budget.day === day ? budget.daily : 0;
        const burst = budget.minute === minute ? budget.burst : 0;
        if (daily >= 60 || burst >= 12) return {limited:true};
        await tx.put('budget',{day, minute, daily:daily+1, burst:burst+1});
        return {};
      });
      if (reservation.cached) return json(reservation.cached);
      if (reservation.limited) return json({error:'quota'},429);
      const result = await queryFirecrawl(query, this.env.FIRECRAWL_API_KEY);
      if (result.ok) {
        const body = await result.json();
        // Keep cache strictly bounded to 60 entries even over multiple days.
        await this.state.storage.transaction(async tx => {
          const entries = [...(await tx.list({prefix:'cache:'})).entries()].sort((a,b)=>a[1].at-b[1].at);
          for (const [oldKey, old] of entries) {
            if (now-old.at >= CACHE_MS) await tx.delete(oldKey);
          }
          const live = [...(await tx.list({prefix:'cache:'})).entries()].sort((a,b)=>a[1].at-b[1].at);
          if (live.length >= 60 && !live.some(([k])=>k === key)) await tx.delete(live[0][0]);
          await tx.put(key,{at:now,result:body});
        });
        return json(body);
      }
      return result;
    } catch { return json({error:'search_unavailable'},502); }
  }
}
