// Isolated streaming regressions: simultaneous conversations, tool continuations and a background voice call.
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('fs'),path=require('path'),assert=require('assert');
(async()=>{
 const browser=await chromium.launch({headless:true,args:['--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream']});
 try {
  const context=await browser.newContext({permissions:['microphone']});const page=await context.newPage();const errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('**/*',async route=>{
   const u=new URL(route.request().url()),reply=data=>route.fulfill({contentType:'application/json',body:JSON.stringify(data)});
   if(u.pathname==='/voice')return route.fulfill({contentType:'text/html',body:fs.readFileSync(path.join(__dirname,'../src/voice/voice.html'),'utf8')});
   if(u.pathname==='/v1/models')return reply({data:[{id:'chat',kind:'chat'},{id:'speech',kind:'speech',voices:['Mae'],default_voice:'Mae',default_for:['text_to_speech']},{id:'image',kind:'image'}]});
   if(u.pathname==='/v1/tools')return reply({data:[{id:'chat',state:'ready',keep_loaded:true},{id:'speech',state:'ready',keep_loaded:true},{id:'image',state:'ready'}],mem_available_bytes:24000000000});
   if(u.pathname==='/v1/skills/model-manager')return reply({enabled:false,text:''});return reply({});
  });
  await page.addInitScript(()=>{
   const realFetch=window.fetch.bind(window);window.__requests=[];window.__images=[];window.__sockets=[];window.__sent=[];
   window.fetch=async(url,opts={})=>{
    if(String(url).endsWith('/v1/chat/completions')){
     let controller;const stream=new ReadableStream({start(c){controller=c;}});
     const req={body:JSON.parse(opts.body),signal:opts.signal,done:false,
      chunk(delta){controller.enqueue(new TextEncoder().encode('data: '+JSON.stringify({choices:[{delta}]})+'\n\n'));},
      end(){if(this.done)return;this.done=true;controller.enqueue(new TextEncoder().encode('data: [DONE]\n\n'));controller.close();}};
     opts.signal?.addEventListener('abort',()=>{if(!req.done){req.done=true;controller.error(new DOMException('aborted','AbortError'));}},{once:true});
     __requests.push(req);return new Response(stream,{headers:{'Content-Type':'text/event-stream'}});
    }
    if(String(url).endsWith('/v1/images/generations'))return new Promise(resolve=>__images.push({body:JSON.parse(opts.body),finish(){resolve(new Response(JSON.stringify({data:[{url:'/result.png'}]}),{headers:{'Content-Type':'application/json'}}));}}));
    return realFetch(url,opts);
   };
   class Socket{static OPEN=1;static CONNECTING=0;constructor(){this.readyState=0;__sockets.push(this);}open(){this.readyState=1;this.onopen?.({});}send(s){__sent.push(JSON.parse(s));}close(code=1000,reason=''){this.readyState=3;this.onclose?.({code,reason});}event(e){this.onmessage?.({data:JSON.stringify(e)});}}
   window.WebSocket=Socket;
  });
  await page.goto('http://127.0.0.1:8190/voice');await page.waitForFunction(()=>jarvis.ready);
  const a=await page.evaluate(()=>{jarvis.say('话题A');return cur.id});await page.waitForFunction(()=>__requests.length===1);
  await page.evaluate(()=>__requests[0].chunk({content:'A第一段'}));
  await page.locator('#newChat').click();const b=await page.evaluate(()=>cur.id);assert.notEqual(a,b);
  await page.evaluate(()=>{S.think=true;jarvis.say('话题B')});await page.waitForFunction(()=>__requests.length===2);
  assert.equal(await page.evaluate(()=>chats.size),2);
  await page.evaluate(()=>{__requests[0].chunk({content:'A后台续写'});__requests[1].chunk({content:'B第一段'});});
  await page.waitForFunction(()=>cur.msgs.some(m=>m.text==='B第一段'));
  assert(!(await page.locator('#log').innerText()).includes('A后台续写'));
  await page.evaluate(()=>{$('text').value='B草稿';onInput();sendText()});assert.equal(await page.locator('#text').inputValue(),'B草稿');
  await page.evaluate(id=>openConv(id),a);assert.equal(await page.locator('#text').inputValue(),'');
  assert((await page.locator('#log').innerText()).includes('A后台续写'));
  await page.evaluate(id=>openConv(id),b);assert.equal(await page.locator('#text').inputValue(),'B草稿');
  // Stopping B does not abort A.
  await page.locator('#send').click();await page.waitForFunction(()=>chats.size===1);
  assert.equal(await page.evaluate(()=>__requests[0].signal.aborted),false);
  assert.equal(await page.evaluate(()=>__requests[1].signal.aborted),true);
  // A calls an image tool in the background; the continuation must keep A's history and settings.
  await page.evaluate(()=>{__requests[0].chunk({tool_calls:[{index:0,id:'image-a',function:{name:'generate_image',arguments:'{"prompt":"A image"}'}}]});__requests[0].end();});
  await page.waitForFunction(()=>__images.length===1);
  assert.equal(await page.evaluate(()=>cur.msgs.some(m=>m.role==='tool')),false);
  await page.locator('#newChat').click();const c=await page.evaluate(()=>{jarvis.say('话题C');return cur.id});
  await page.waitForFunction(()=>__requests.length===3);
  await page.evaluate(()=>__images[0].finish());await page.waitForFunction(()=>__requests.length===4);
  const continuation=await page.evaluate(()=>__requests[3].body);
  assert.equal(continuation.chat_template_kwargs.enable_thinking,false);
  assert(continuation.messages.some(m=>m.role==='user'&&m.content==='话题A'));
  assert(!continuation.messages.some(m=>m.content==='话题B'||m.content==='话题C'));
  assert(continuation.messages.some(m=>m.role==='tool'&&m.tool_call_id==='image-a'));
  await page.evaluate(()=>{__requests[3].chunk({content:'A图片完成'});__requests[3].end();__requests[2].chunk({content:'C完成'});__requests[2].end();});
  await page.waitForFunction(()=>chats.size===0);
  const saved=await page.evaluate(()=>JSON.parse(localStorage.getItem('jarvis.convs')));
  assert(saved.find(x=>x.id===a).msgs.some(m=>m.media?.length));assert(!saved.find(x=>x.id===c).msgs.some(m=>m.role==='tool'));
  // Voice response continues after creating a new topic; its events never enter that topic.
  await page.locator('#mic').click();await page.waitForFunction(()=>V.mic&&__sockets.length===1);
  await page.evaluate(()=>{__sockets[0].open();__sockets[0].event({type:'session.created',session:{instructions:''}});__sockets[0].event({type:'session.updated',session:{reasoning:true}});__sockets[0].event({type:'response.created',response:{id:'voice-active'}});});
  await page.locator('#vmMin').click();await page.locator('#newChat').click();const d=await page.evaluate(()=>cur.id);assert.notEqual(c,d);
  await page.evaluate(()=>{__sockets[0].event({type:'response.text.delta',item_id:'voice-bot',delta:'C后台语音回复'});__sockets[0].event({type:'response.done',response:{status:'completed',output:[{id:'voice-bot'}]}});jarvis.say('话题D');});
  await page.waitForFunction(()=>__requests.length===5);
  assert.equal(await page.evaluate(()=>__sockets[0].readyState),1);
  assert.equal(await page.evaluate(()=>cur.msgs.some(m=>m.text==='C后台语音回复')),false);
  assert.equal(await page.evaluate(id=>convs.find(x=>x.id===id).msgs.some(m=>m.text==='C后台语音回复'),c),true);
  assert(!(await page.locator('#log').innerText()).includes('C后台语音回复'));
  await page.evaluate(()=>{__requests[4].chunk({content:'D完成'});__requests[4].end();});await page.waitForFunction(()=>chats.size===0);
  await page.evaluate(()=>voiceStop());assert.deepEqual(errors,[]);
  console.log(JSON.stringify({pass:true,checks:['overlapping streams','background deltas isolated','switching and draft preservation','stop only selected task','background image generation','original tool continuation history','per-task settings snapshot','background persistence','voice call survives new topic','voice events owned by original conversation'],errors}));
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});
