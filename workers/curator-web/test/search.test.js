import test from 'node:test';
import assert from 'node:assert/strict';
import worker, {publicURL, queryFirecrawl, SearchGate} from '../src/index.js';
const secret = 'fixture-not-real-'.repeat(3);
const req = (query='new jazz', authorization=`Bearer ${secret}`) => new Request('https://proxy.example.com/search',{
  method:'POST',headers:{Authorization:authorization,'Content-Type':'application/json'},body:JSON.stringify({query})});
const env = {FIRECRAWL_API_KEY:'fixture-upstream',CURATOR_ACCESS_TOKEN:secret,
  SEARCH_GATE:{idFromName:n=>n,get:()=>({fetch:async()=>Response.json({sources:[]})})}};
class Storage {
  data = new Map(); chain = Promise.resolve();
  async get(k){return this.data.get(k);} async put(k,v){this.data.set(k,v);} async delete(k){this.data.delete(k);}
  async list({prefix}){return new Map([...this.data].filter(([k])=>k.startsWith(prefix)));}
  transaction(fn){const pending=this.chain.then(()=>fn(this));this.chain=pending.catch(()=>{});return pending;}
}
const raw = {success:true,data:{web:[{url:'https://music.example.com/release',title:'Artist',markdown:'Actual content'}]}};
test('public links reject secrets, schemes and private addresses',()=>{
 for(const url of ['http://example.com','javascript:alert(1)','https://u:p@example.com','https://127.0.0.1','https://[::1]','https://host.local','https://localhost','https://host.internal','https://example.com:8443']) assert.equal(publicURL(url),null,url);
 assert.equal(publicURL('https://music.example.com/release#part'),'https://music.example.com/release');
});
test('auth before upstream and strict body',async()=>{
 assert.equal((await worker.fetch(req('q','wrong'),env)).status,401);
 assert.equal((await worker.fetch(req(''),env)).status,400);
 assert.equal((await worker.fetch(req('x'.repeat(1001)),env)).status,400);
 const extra=new Request('https://proxy.example.com/search',{method:'POST',headers:{Authorization:`Bearer ${secret}`,'Content-Type':'application/json'},body:JSON.stringify({query:'jazz',token:'yandex',url:'https://private.local'})});
 assert.equal((await worker.fetch(extra,env)).status,400);
 assert.equal((await worker.fetch(req(),{...env,FIRECRAWL_API_KEY:''})).status,503);
 assert.equal((await worker.fetch(req(),env)).status,200);
});
test('fixed Firecrawl contract, bounded and deduplicated excerpts',async()=>{
 const response=await queryFirecrawl('new jazz','fixture',async(url,options)=>{
  assert.equal(url,'https://api.firecrawl.dev/v2/search'); assert.equal(options.redirect,'error');
  const b=JSON.parse(options.body);assert.equal(b.limit,3);assert.deepEqual(b.sources,['web']);
  assert.deepEqual(b.scrapeOptions.formats,['markdown']); assert.equal(b.safe,true);
  return Response.json({success:true,data:{web:[...raw.data.web,...raw.data.web,{url:'https://localhost',markdown:'bad'},{url:'https://second.example.com/',markdown:'x'.repeat(6000)}]}});
 });
 const b=await response.json();assert.equal(b.sources.length,2);assert.equal(b.sources[1].excerpt.length,3000);
 assert.ok(!JSON.stringify(b).includes('fixture'));
});
test('upstream errors sanitized, billable quota mapped, oversized response rejected',async()=>{
 for(const code of [401,500,402,429]) {
  const response=await queryFirecrawl('q','fixture',async()=>new Response('secret raw upstream',{status:code}));
  assert.equal(response.status,[402,429].includes(code)?429:502);
  assert.ok(!(await response.text()).includes('secret'));
 }
 assert.equal((await queryFirecrawl('q','fixture',async()=>Response.json({success:false}))).status,502);
 await assert.rejects(queryFirecrawl('q','fixture',async()=>new Response('x'.repeat(256001))),/too_large/);
});
test('persistent cache, atomic daily/minute caps and bounded cache',async()=>{
 const storage=new Storage();const gate=new SearchGate({storage},env);const original=globalThis.fetch;let requests=0;
 globalThis.fetch=async()=>{requests++;return Response.json(raw);};
 try {
  const call=q=>gate.fetch(new Request('https://gate/search',{method:'POST',body:JSON.stringify({query:q})}));
  assert.equal((await call('cached')).status,200);assert.equal((await call('cached')).status,200);assert.equal(requests,1);
  await Promise.all(Array.from({length:11},(_,i)=>call('q'+i)));
  assert.equal(requests,12);assert.equal((await call('over-minute')).status,429);
  const now=Date.now();await storage.put('budget',{day:Math.floor(now/86400000),daily:60,minute:Math.floor(now/60000)-1,burst:0});
  assert.equal((await call('over-day')).status,429);assert.equal((await call('cached')).status,200);
  await storage.put('budget',{});
  for(let i=0;i<80;i++)await storage.put('cache:old'+i,{at:now-CACHE_MS-1,result:{sources:[]}});
  assert.equal((await call('new')).status,200);assert.ok((await storage.list({prefix:'cache:'})).size<=60);
 } finally {globalThis.fetch=original;}
});
const CACHE_MS=15*60000;
