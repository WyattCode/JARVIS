const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs=require('fs'),assert=require('assert/strict'),path=require('path');
const html=fs.readFileSync(process.env.VOICE_HTML||path.join(__dirname,'../src/voice/voice.html'),'utf8');
(async()=>{
const browser=await chromium.launch({headless:true,args:['--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream','--autoplay-policy=no-user-gesture-required']});
const passed=[];
async function setup(){
 const page=await browser.newPage({permissions:['microphone']});const errors=[];let pending=null,hold=false;
 page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/*',async route=>{
  const u=new URL(route.request().url());
  if(u.pathname==='/voice')return route.fulfill({contentType:'text/html',body:html});
  if(u.pathname==='/v1/models'){
   if(hold){hold=false;await new Promise(resolve=>pending=resolve);pending=null;}
   return route.fulfill({json:{data:[{id:'chat',kind:'chat',name:'Chat'},{id:'speech',kind:'speech',name:'Speech',voices:['kept','other'],default_voice:'kept',voice_default_revision:1}]}});
  }
  if(u.pathname==='/v1/tools')return route.fulfill({json:{data:[{id:'chat',state:'ready'},{id:'speech',state:'ready'}]}});
  return route.fulfill({json:{}});
 });
 await page.addInitScript(()=>{
  window.sockets=[];window.sent=[];window.fastTimers=false;
  const realTimeout=window.setTimeout.bind(window);
  window.setTimeout=(f,ms,...args)=>realTimeout(f,fastTimers?([1000,2000,4000,8000,15000].includes(ms)?15:ms===10000?200:ms===20000?400:ms):ms,...args);
  class WS {
   static CONNECTING=0;static OPEN=1;static CLOSING=2;static CLOSED=3;
   constructor(){this.readyState=0;sockets.push(this);}
   open(){this.readyState=1;this.onopen?.({});}
   send(raw){const v=JSON.parse(raw);sent.push(v);if(v.type==='session.update')this.settings=v.session;}
   close(code=1000){this.readyState=3;this.onclose?.({code,reason:''});}
   ack(){this.onmessage?.({data:JSON.stringify({type:'session.updated',session:this.settings})});}
  }window.WebSocket=WS;
 });
 await page.goto('http://127.0.0.1:8190/voice');await page.waitForFunction(()=>jarvis.ready);
 return {page,errors,hold(){hold=true},async release(){assert.ok(pending);pending();},async close(){await page.evaluate(()=>voiceStop());assert.deepEqual(errors,[]);await page.close();}};
}
try {
 const t=await setup(),p=t.page;
 await p.locator('#mic').click();await p.waitForFunction(()=>sockets.length===1);
 await p.evaluate(()=>{sockets[0].open();handle({type:'session.created',readiness:true,session:{}});sockets[0].ack()});
 assert.ok(await p.evaluate(()=>V.sessionReady&&!V.serverReady&&voiceState()==='warming'&&!voiceReady()));
 await p.evaluate(()=>handle({type:'localrouter.session.ready',voice:'stale',speech_model:'speech',speech:'warmed'}));
 assert.equal(await p.evaluate(()=>V.serverReady),false);
 await p.evaluate(()=>handle({type:'localrouter.session.ready',voice:V.expectedSession.voice,speech_model:V.expectedSession.speech_model,speech:'warmed'}));
 assert.ok(await p.evaluate(()=>V.serverReady&&voiceReady()));passed.push('config confirmation waits for actual selected-voice readiness');
 await p.evaluate(()=>{S.voices.speech='other';sessionUpdate();sockets[0].ack()});
 assert.equal(await p.evaluate(()=>V.serverReady),false);
 await p.evaluate(()=>handle({type:'localrouter.session.ready',voice:'kept',speech_model:'speech',speech:'warmed'}));
 assert.equal(await p.evaluate(()=>V.serverReady),false);
 await p.evaluate(()=>handle({type:'localrouter.session.ready',voice:'other',speech_model:'speech',speech:'warmed'}));
 assert.ok(await p.evaluate(()=>V.serverReady));passed.push('voice change ignores readiness for the previous voice');
 await p.evaluate(()=>{sessionUpdate();sockets[0].ack();handle({type:'localrouter.session.ready',voice:V.expectedSession.voice,speech_model:V.expectedSession.speech_model,speech:'failed'})});
 assert.ok(await p.evaluate(()=>!V.serverReady&&!voiceReady()&&voiceState()==='configError'));passed.push('failed warmup is not shown as ready');
 await t.close();
 const old=await setup();await old.page.locator('#mic').click();await old.page.waitForFunction(()=>sockets.length===1);await old.page.evaluate(()=>{sockets[0].open();handle({type:'session.created',session:{}});sockets[0].ack()});assert.ok(await old.page.evaluate(()=>V.serverReady&&voiceReady()));await old.close();passed.push('legacy servers remain usable during rollback');
 console.log(JSON.stringify({passed}));
}finally{await browser.close();}
})().catch(e=>{console.error(e.message.split('\n')[0]);process.exitCode=1});
