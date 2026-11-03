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
 {
  const t=await setup(),p=t.page;t.hold();const req=p.waitForRequest(r=>new URL(r.url()).pathname==='/v1/models');await p.locator('#mic').click();await req;
  assert.ok(await p.evaluate(()=>V.starting&&!V.ws));
  await p.evaluate(()=>{window.owner=cur;deleteConv(cur)});
  assert.ok(await p.evaluate(()=>convs.includes(owner)&&cur===owner));
  await t.release();await p.waitForFunction(()=>sockets.length===1);await p.evaluate(()=>{sockets[0].open();sockets[0].ack()});
  assert.ok(await p.evaluate(()=>V.sessionReady&&convs.includes(V.conv)));
  await t.close();passed.push('pending call owner cannot be deleted');
 }
 {
  const t=await setup(),p=t.page;t.hold();const req=p.waitForRequest(r=>new URL(r.url()).pathname==='/v1/models');await p.locator('#mic').click();await req;await p.evaluate(()=>voiceStop());await t.release();await p.waitForTimeout(100);
  assert.equal(await p.evaluate(()=>sockets.length),0);await t.close();passed.push('hangup cancels delayed startup');
 }
 {
  const t=await setup(),p=t.page;await p.evaluate(()=>fastTimers=true);await p.locator('#mic').click();await p.waitForFunction(()=>sockets.length===1);
  for(let i=0;i<9;i++){
   await p.evaluate(()=>{sockets.at(-1).open();sockets.at(-1).close(1006)});
   if(i<8)await p.waitForFunction(n=>sockets.length===n,i+2);
  }
  assert.ok(await p.evaluate(()=>!V.ws&&!V.starting));assert.equal(await p.evaluate(()=>sockets.length),9);
  await p.waitForTimeout(100);assert.equal(await p.evaluate(()=>sockets.length),9);
  await t.close();passed.push('unconfirmed flapping stops after eight retries');
 }
 {
  const t=await setup(),p=t.page;await p.evaluate(()=>fastTimers=true);await p.locator('#mic').click();await p.waitForFunction(()=>sockets.length===2);
  assert.equal(await p.evaluate(()=>V.retries),1);await p.evaluate(()=>voiceStop());await p.waitForTimeout(450);assert.equal(await p.evaluate(()=>sockets.length),2);
  await t.close();passed.push('connection timeout retries and hangup cancels timers');
 }
 {
  const t=await setup(),p=t.page;await p.evaluate(()=>fastTimers=true);await p.locator('#mic').click();await p.waitForFunction(()=>sockets.length===1);await p.evaluate(()=>sockets[0].open());
  await p.waitForFunction(()=>sockets.length===2);assert.equal(await p.evaluate(()=>V.retries),1);
  await p.evaluate(()=>{sockets[1].open();sockets[1].ack()});assert.ok(await p.evaluate(()=>V.sessionReady&&V.retries===0));
  await p.waitForTimeout(450);assert.equal(await p.evaluate(()=>sockets.length),2);
  await t.close();passed.push('handshake timeout recovers; confirmation resets budget and clears timeout');
 }
 console.log(JSON.stringify({passed}));
}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});
