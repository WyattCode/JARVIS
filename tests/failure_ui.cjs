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
      raw(s){controller.enqueue(new TextEncoder().encode(s));},
      truncate(){this.done=true;controller.close();},
      fail(){this.done=true;controller.error(new Error('network reset injected'));},
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

  // A partial reply cannot look complete or execute an incomplete tool call.
  await page.evaluate(()=>{S.tools=true;jarvis.say('中途断开的任务')});await page.waitForFunction(()=>__requests.length===1);
  await page.evaluate(()=>{__requests[0].chunk({content:'已收到的半句话',tool_calls:[{index:0,id:'partial-tool',function:{name:'generate_image',arguments:'{"prompt":"partial"}'}}]});__requests[0].truncate()});
  await page.waitForFunction(()=>chats.size===0);
  let m=await page.evaluate(()=>cur.msgs.find(m=>m.role==='assistant'));
  assert.equal(m.text,'已收到的半句话');assert(m.error.includes('不完整'));assert.equal(m.streaming,false);assert.equal(m.interrupted,true);assert.equal(await page.evaluate(()=>__images.length),0);
  // A network read error finalizes the original message in its own background conversation.
  const failedOwner=await page.evaluate(()=>{openConv(newConv().id);jarvis.say('网络读取失败');return cur.id});await page.waitForFunction(()=>__requests.length===2);
  await page.evaluate(()=>{__requests[1].chunk({content:'读取失败前的文字'});openConv(newConv().id);__requests[1].fail()});
  await page.waitForFunction(()=>chats.size===0);
  m=await page.evaluate(id=>convs.find(c=>c.id===id).msgs.find(m=>m.role==='assistant'),failedOwner);
  assert.equal(m.streaming,false);assert.equal(m.interrupted,true);assert(m.error.includes('network reset'));assert.equal(await page.evaluate(()=>cur.msgs.length),0);
  // A valid finish_reason is sufficient at EOF; CRLF SSE may split across network chunks.
  await page.evaluate(()=>jarvis.say('正常结束'));await page.waitForFunction(()=>__requests.length===3);
  await page.evaluate(()=>{__requests[2].raw('data: {"choices":[{"delta":{"content":"完整回复"}}]}\r');__requests[2].raw('\n\r\ndata: {"choices":[{"delta":{},"finish_reason":"stop"}]}\r\n\r\n');__requests[2].truncate()});await page.waitForFunction(()=>chats.size===0);
  m=await page.evaluate(()=>cur.msgs.find(m=>m.role==='assistant'));assert.equal(m.text,'完整回复');assert(!m.error);assert(!m.interrupted);
  // Storage failures must not delete a running conversation, even repeatedly.
  const quotaOwner=await page.evaluate(()=>{
   openConv(newConv().id);jarvis.say('存储失败仍继续生成');const original=cur;original.updated=1;
   openConv(newConv().id);addMsg({role:'user',text:'另一个会话'});window.__setItem=Storage.prototype.setItem;
   Storage.prototype.setItem=function(k,v){if(k==='jarvis.convs')throw new DOMException('full','QuotaExceededError');return __setItem.call(this,k,v)};
   saveConv();saveConv();return original.id;
  });
  assert.equal(await page.evaluate(id=>convs.some(c=>c.id===id)&&chats.has(id),quotaOwner),true);
  assert.equal(await page.locator('#storageAlert').isVisible(),true);
  const downloadPromise=page.waitForEvent('download');await page.locator('#exportConvs').click();const download=await downloadPromise;
  const backup=JSON.parse(fs.readFileSync(await download.path(),'utf8'));assert(backup.conversations.some(c=>c.id===quotaOwner));
  await page.evaluate(()=>{__requests[3].chunk({content:'后台没有丢失'});__requests[3].end()});await page.waitForFunction(()=>chats.size===0);
  assert.equal(await page.evaluate(id=>convs.find(c=>c.id===id).msgs.some(m=>m.text==='后台没有丢失'),quotaOwner),true);
  await page.evaluate(()=>{Storage.prototype.setItem=__setItem;for(const c of convs)saveConv(c)});assert.equal(await page.locator('#storageAlert').isVisible(),false);
  const saved=await page.evaluate(()=>JSON.parse(localStorage.getItem('jarvis.convs')));assert(saved.some(c=>c.id===quotaOwner));
  // Reconnect while a reply is streaming, then reused server item ids cannot overwrite the interrupted reply.
  await page.evaluate(()=>{S.mode='ptt'});await page.locator('#mic').click();await page.waitForFunction(()=>V.mic&&__sockets.length===1);
  const voiceOwner=await page.evaluate(()=>{__sockets[0].open();__sockets[0].event({type:'session.created',session:{instructions:''}});__sockets[0].event({type:'session.updated',session:{reasoning:false}});__sockets[0].event({type:'response.created',response:{id:'old-response'}});__sockets[0].event({type:'response.text.delta',item_id:'old-item',delta:'断线前的回复'});return cur.id});
  await page.locator('#vmMin').click();await page.locator('#newChat').click();
  await page.evaluate(()=>{__sockets[0].close(1006,'network');clearTimeout(V.retryTimer);connect(V.run);__sockets[1].open();__sockets[1].event({type:'session.updated',session:{reasoning:false}});__sockets[1].event({type:'response.text.delta',item_id:'old-item',delta:'新连接的回复'});__sockets[1].event({type:'response.done',response:{status:'completed',output:[{id:'old-item'}]}})});
  const voice=await page.evaluate(id=>convs.find(c=>c.id===id),voiceOwner);
  const old=voice.msgs.find(m=>m.text==='断线前的回复');assert.equal(old.streaming,false);assert.equal(old.interrupted,true);assert(voice.msgs.some(m=>m.text==='新连接的回复'&&!m.streaming));assert.equal(await page.evaluate(()=>cur.msgs.some(m=>m.via==='voice')),false);
  await page.evaluate(()=>voiceStop());
  // Module failure releases microphone tracks; retry works, and stopping the call releases the new stream too.
  await page.evaluate(async()=>{
   window.__tracks=[];const gum=navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);navigator.mediaDevices.getUserMedia=async(...args)=>{const stream=await gum(...args);__tracks.push(...stream.getTracks());return stream;};
   const probe=new AudioContext();const proto=Object.getPrototypeOf(probe.audioWorklet);window.__workletProto=proto;window.__addModule=proto.addModule;proto.addModule=async()=>{throw new Error('worklet failed')};await probe.close();
  });
  await page.locator('#mic').click();await page.waitForFunction(()=>V.micError&&__tracks.length>0);
  assert.equal(await page.evaluate(()=>V.mic),null);assert.equal(await page.evaluate(()=>__tracks.every(t=>t.readyState==='ended')),true);
  await page.evaluate(async()=>{__workletProto.addModule=__addModule;await openMic(V.run)});
  assert.equal(await page.evaluate(()=>!!V.mic&&__tracks.at(-1).readyState==='live'),true);
  await page.evaluate(()=>voiceStop());assert.equal(await page.evaluate(()=>__tracks.every(t=>t.readyState==='ended')),true);
  assert.deepEqual(errors,[]);
  console.log(JSON.stringify({pass:true,checks:['incomplete stream preserves partial text and reports interruption','incomplete tool calls never execute','network read failure finalizes original background message','valid terminal marker and split CRLF','quota preserves active history','downloadable conversation backup','storage recovery persists all conversations','reconnect finalizes original voice messages','reused item ids stay separate','microphone failure and retry release all tracks'],errors}));
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});
