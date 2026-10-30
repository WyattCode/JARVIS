// Slow document delivery must not expose the uninitialized shell or move restored controls.
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('fs'),path=require('path'),http=require('http'),assert=require('assert');
(async()=>{
 const html=fs.readFileSync(path.join(__dirname,'../src/voice/voice.html'),'utf8'),split=html.indexOf("<script>\n'use strict';\nconst $ =");
 assert(split>=0,'main application bootstrap must exist');
 let releaseDocument;const server=http.createServer(async(req,res)=>{
  if(req.url==='/voice'){
   const gate=new Promise(r=>releaseDocument=r);
   res.writeHead(200,{'Content-Type':'text/html; charset=utf-8','Content-Length':Buffer.byteLength(html)});
   res.write(html.slice(0,split));await gate;res.end(html.slice(split));return;
  }
  res.writeHead(200,{'Content-Type':'application/json'});res.end('{}');
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const b=await chromium.launch({headless:true});const checks=[];
 try{
  for(const [width,height,theme,draft] of [[1440,900,'light',''],[416,740,'dark',''],[1440,900,'dark','保留的草稿\n'.repeat(12)],[416,740,'light','保留的草稿\n'.repeat(12)]]){
   const p=await b.newPage({viewport:{width,height}}),errors=[];let releaseMeta;const gate=new Promise(r=>releaseMeta=r);
   p.on('pageerror',e=>errors.push(e.message));
   await p.addInitScript(({theme,draft})=>{
    localStorage.setItem('jarvis.appearance',theme);
    if(draft){localStorage.setItem('jarvis.current',JSON.stringify('draft'));localStorage.setItem('jarvis.convs',JSON.stringify([{id:'draft',updated:Date.now(),msgs:[],draft}]))}
   },{theme,draft});
   await p.route('**/v1/**',async r=>{
    const name=new URL(r.request().url()).pathname;
    if(name==='/v1/models'||name==='/v1/tools')await gate;
    return r.fulfill({json:name==='/v1/models'?{data:[{id:'chat',kind:'chat'}]}:name==='/v1/tools'?{data:[{id:'chat',state:'ready',keep_loaded:true}]}:{enabled:false}});
   });
   await p.goto(`http://127.0.0.1:${server.address().port}/voice`,{waitUntil:'commit'});
   await p.locator('#app').waitFor({state:'attached'});
   assert.equal(await p.locator('#app').evaluate(e=>getComputedStyle(e).visibility),'hidden');
   assert.equal(await p.evaluate(()=>document.documentElement.dataset.theme),theme);
   releaseDocument();await p.waitForFunction(()=>window.jarvis&&!document.documentElement.classList.contains('app-booting'));
   assert.equal(await p.evaluate(()=>jarvis.ready),false,'local interface must not wait for metadata');
   assert.equal(await p.locator('#app').evaluate(e=>getComputedStyle(e).visibility),'visible');
   assert.equal(await p.locator('.sugg button').count(),4);
   assert.equal(await p.locator('.brand .mark').getAttribute('data-stellar'),'live');
   assert.equal(await p.locator('#text').inputValue(),draft);
   const snapshot=()=>p.evaluate(()=>Object.fromEntries(['#statusPill','.composer .box','#empty .mark','#empty h2','.sugg','.brand'].map(s=>{
    const r=document.querySelector(s).getBoundingClientRect();return[s,[r.x,r.y,r.width,r.height]];
   })));
   const before=await snapshot();
   if(!draft)assert.equal(await p.locator('.sugg button').first().evaluate(e=>getComputedStyle(e).opacity),'1');
   releaseMeta();await p.waitForFunction(()=>jarvis.ready);
   const frames=await p.evaluate(()=>new Promise(resolve=>{const all=[];function sample(){all.push(Object.fromEntries(['#statusPill','.composer .box','#empty .mark','#empty h2','.sugg','.brand'].map(s=>{const r=document.querySelector(s).getBoundingClientRect();return[s,[r.x,r.y,r.width,r.height]]})));if(all.length<12)requestAnimationFrame(sample);else resolve(all)}requestAnimationFrame(sample)}));
   for(const after of frames)for(const s of Object.keys(before))for(let i=0;i<4;i++)assert(Math.abs(before[s][i]-after[s][i])<.5,`${width} ${s} moved during readiness`);
   if(!draft)assert.equal(await p.locator('.sugg button').first().evaluate(e=>getComputedStyle(e).opacity),'1');
   assert.deepEqual(errors,[]);checks.push({width,height,theme,draftRestored:!!draft,stable:true});await p.close();
  }
  console.log(JSON.stringify({pass:true,checks}));
 }finally{releaseDocument?.();await b.close();await new Promise(r=>server.close(r))}
})().catch(e=>{console.error(e);process.exitCode=1});
