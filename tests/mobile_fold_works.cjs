// Mobile-only fold layout, gallery navigation and ongoing call isolation.
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('fs'),path=require('path'),assert=require('assert');
const ROOT=path.resolve(__dirname,'..');
(async()=>{const browser=await chromium.launch({headless:true});const results=[];try{
 for(const profile of [
  ['Xiaomi cover Chrome',425,501,'android'],['Xiaomi cover full',425,623,'android'],
  ['Xiaomi inner landscape Chrome',860,502,'android'],['Xiaomi inner portrait Chrome',608,738,'android'],
  ['iPhone cover profile',466,578,'apple'],['iPhone inner landscape profile',951,557,'apple'],['iPhone inner portrait profile',669,851,'apple'],
  ['narrow phone',360,510,'android'],['Windows PC',1440,900,'desktop'],['Windows touch PC',1440,900,'pc-touch']]){
  const [name,width,height,kind]=profile,mobile=['android','apple'].includes(kind);
  const context=await browser.newContext({viewport:{width,height},hasTouch:kind!=='desktop',isMobile:mobile,reducedMotion:'reduce',serviceWorkers:'block',userAgent:kind==='apple'?'Mozilla/5.0 (iPhone; CPU iPhone OS 27_1 like Mac OS X) AppleWebKit/605.1.15 Version/27.1 Mobile/15E148 Safari/604.1':mobile?'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 Chrome/144 Mobile Safari/537.36':'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/144 Safari/537.36'});
  const p=await context.newPage(),errors=[];p.on('pageerror',e=>errors.push(e.message));
  await p.route('**/*',r=>{const n=new URL(r.request().url()).pathname;
   if(n==='/voice')return r.fulfill({contentType:'text/html',body:fs.readFileSync(path.join(ROOT,'src/voice/voice.html'),'utf8')});
   if(n.startsWith('/auth-assets/')){const f=path.join(ROOT,'src/voice/auth',n.slice(13));if(fs.existsSync(f))return r.fulfill({path:f});}
   if(n==='/v1/models')return r.fulfill({json:{data:[{id:'chat',kind:'chat'},{id:'speech',kind:'speech',voices:['Atlas'],default_voice:'Atlas'}]}});
   if(n==='/v1/tools')return r.fulfill({json:{data:[{id:'chat',kind:'chat',state:'ready'},{id:'speech',kind:'speech',state:'ready'}]}});
   if(n==='/v1/files/audit/image.png')return r.fulfill({path:path.join(ROOT,'src/voice/icon.png'),contentType:'image/png'});
   return r.fulfill({json:{enabled:false}});
  });
  await p.goto('https://jarvis.test/voice');await p.waitForFunction(()=>jarvis.ready);await p.evaluate(()=>document.fonts.ready);
  const geometry=await p.evaluate(()=>{const r=s=>document.querySelector(s).getBoundingClientRect().toJSON();return{canvas:r('.empty .stellar-canvas'),mark:r('.empty .mark'),title:r('.empty h2'),hint:r('.empty p'),box:r('.box'),sugg:r('.sugg'),pageWidth:document.documentElement.scrollWidth,viewport:innerWidth}});
  assert.equal(await p.evaluate(()=>document.documentElement.dataset.uiSurface),mobile?'mobile':'desktop');
  if(!mobile){assert.equal(await p.locator('#mobileTabs').count(),0);assert.equal(await p.locator('#vm > #reel').count(),1);await context.close();results.push({name,desktopUntouched:true});continue;}
  assert.equal(await p.locator('#mobileTabs').count(),0);
  const g=geometry;
  assert(g.pageWidth<=width+1,`${name}: horizontal document overflow`);
  const sideBySide=g.title.left>=g.mark.right;
  assert(sideBySide?g.title.left-g.canvas.right>=10:g.title.top-g.canvas.bottom>=10,`${name}: avatar paint overlaps heading ${JSON.stringify(g)}`);
  assert(g.hint.top>=g.title.bottom-1,`${name}: heading overlaps subtitle`);
  assert(g.sugg.bottom<=g.box.top-6,`${name}: suggestions hidden behind composer ${JSON.stringify(g)}`);
  await p.evaluate(()=>showVoice(true));
  const q=await p.evaluate(()=>{const r=s=>document.querySelector(s).getBoundingClientRect().toJSON();return{canvas:r('#orb .stellar-canvas'),labels:r('.voice-labels'),wave:r('#wave')}});
  assert(q.labels.top>=q.canvas.bottom+10,`${name}: voice avatar overlaps labels`);
  assert(q.wave.top>=q.labels.bottom+2,`${name}: waveform overlaps labels`);
  await p.evaluate(()=>{cur.msgs.push({id:'audit-image',role:'tool',name:'generate_image',kind:'image',text:'测试作品'});renderReel()});
  assert(await p.locator('#vm > #reel .rc').isVisible());assert(await p.evaluate(()=>V.open));
  assert(await p.evaluate(()=>document.querySelector('#vm .controls').getBoundingClientRect().bottom<=document.querySelector('#reel').getBoundingClientRect().top+1));
  assert.deepEqual(errors,[],`${name}: page errors`);
  results.push({name,homeClear:true,voiceClear:true,inlineWorks:true});await context.close();
 }
 console.log(JSON.stringify({pass:true,physicalSafariTested:false,results}));
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1});
