// Every browser request is intercepted: no production endpoints or model execution.
const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true});const results=[];
 const html=fs.readFileSync(path.join(__dirname,'../src/voice/voice.html'),'utf8');
 const reply=text=>'data: '+JSON.stringify({choices:[{delta:{content:text},finish_reason:'stop'}]})+'\n\ndata: [DONE]\n\n';
 async function setup(custom=()=>false){
  const page=await browser.newPage({serviceWorkers:'block'}),errors=[],requests=[],dialogs=[];
  page.on('pageerror',e=>errors.push(e.message));page.on('dialog',async d=>{dialogs.push(d.message());await d.accept('native-key')});
  await page.addInitScript(()=>{window.sockets=[];class Socket{static OPEN=1;static CONNECTING=0;constructor(){this.readyState=0;this.sent=[];sockets.push(this)}send(x){const e=JSON.parse(x);this.sent.push(e);if(e.type==='input_audio_buffer.clear')this.event({type:'input_audio_buffer.cleared'})}close(code=1000,reason=''){this.readyState=3;this.onclose?.({code,reason})}open(){this.readyState=1;this.onopen?.({})}event(x){this.onmessage?.({data:JSON.stringify(x)})}}window.WebSocket=Socket;});
  await page.route('**/*',async r=>{const p=new URL(r.request().url()).pathname;requests.push({path:p,method:r.request().method()});const json=(v,status=200)=>r.fulfill({json:v,status});if(await custom(r,p,json))return;
   if(p==='/voice')return r.fulfill({contentType:'text/html',body:html});
   if(p==='/login')return r.fulfill({contentType:'text/html',body:'<title>login</title>登录'});
   if(p==='/v1/models')return json({data:[{id:'chat',kind:'chat',jarvis:{image_input:true,pdf_text:true}},{id:'speech',kind:'speech',voices:['Ezra'],default_voice:'Ezra'},{id:'asr',kind:'transcription'},{id:'video',kind:'video',limits:{max_seconds:15}},{id:'image',kind:'image'}]});
   if(p==='/v1/tools')return json({data:['chat','speech','asr','video','image'].map(id=>({id,kind:id==='asr'?'transcription':id,state:'ready'}))});
   if(p==='/v1/media/share')return json({url:'https://jarvis.test/media/signed-test'});
   if(p==='/v1/chat/completions')return r.fulfill({contentType:'text/event-stream',body:reply('附件中的预算是三万元。')});
   if(p==='/v1/jarvis/extract-pdf')return json({text:'PDF预算是五万元。'});
   return json({enabled:false});
  });
  await page.goto('http://jarvis.test/voice');await page.waitForFunction(()=>jarvis.ready);
  return{page,requests,dialogs,errors,async finish(name){assert.deepEqual(errors,[],name);results.push(name);await page.close()}};
 }
 async function voice(page){await page.evaluate(()=>{V.conv=cur;V.ctx={state:'running',currentTime:0,close:()=>Promise.resolve(),resume:()=>Promise.resolve()};V.mic={getAudioTracks:()=>[{readyState:'live',muted:false}],getTracks:()=>[]};S.speechModel='speech';S.tools=false;connect(V.run);const s=sockets.at(-1);s.open();s.event({type:'session.updated',session:s.sent.find(e=>e.type==='session.update').session})});}
 async function attach(page,text='项目预算为三万元。'){await page.evaluate(async text=>{await queueAttachments([new File([text],'budget.txt',{type:'text/plain'})]);$('text').value='读一下这个附件';sendText()},text);}
 try{
  // A refresh leaves server jobs active even though the in-memory task map is empty.
  let submissions=0;
  const media=await setup(async(r,p,json)=>{
   if(p==='/v1/videos'&&r.request().method()==='POST'){await json({id:'video_'+(++submissions),status:'in_progress',progress:10});return true;}
   if(p.startsWith('/v1/videos/')){await json({id:p.split('/').pop(),status:'in_progress',progress:10});return true;}
  });
  await media.page.evaluate(async()=>{addMsg({role:'user',text:'制作视频'});const call={id:'original',type:'function',function:{name:'generate_video',arguments:'{"prompt":"boat","seconds":15}'}};addMsg({role:'assistant',text:'开始制作。',calls:[call],via:'text'});await runTool(call,new AbortController().signal,cur)});
  await media.page.waitForFunction(()=>cur.msgs.some(m=>m.jobId==='video_1'));
  await media.page.reload();await media.page.waitForFunction(()=>jarvis.ready);await media.page.evaluate(()=>watchJobs());
  await media.page.getByRole('button',{name:'重新生成',exact:true}).click();
  const guarded=await media.page.evaluate(()=>{const owner=cur;deleteConv(owner);return{same:cur===owner,exists:convs.includes(owner),jobs:owner.msgs.filter(m=>m.jobId).map(m=>m.jobId),tasks:mediaTasks.size}});
  assert.deepEqual(guarded,{same:true,exists:true,jobs:['video_1'],tasks:0});assert.equal(submissions,1);
  for(const status of ['queued','in_progress','unknown']){
   const state=await media.page.evaluate(status=>{const m=cur.msgs.find(m=>m.jobId);m.result=JSON.stringify({status});m.unknown=status==='unknown';m.error=status==='unknown'?'待确认':'';const before=cur.msgs.length;regenerate();deleteConv(cur);return{before,after:cur.msgs.length,exists:convs.includes(cur)}},status);assert.equal(state.before,state.after);assert(state.exists);
  }
  const terminal=await media.page.evaluate(()=>{const owner=cur;const m=cur.msgs.find(m=>m.jobId);m.unknown=false;m.error='failed';m.result='{"status":"failed"}';deleteConv(owner);return convs.includes(owner)});assert.equal(terminal,false);
  await media.finish('persisted queued/in_progress/unknown tasks block regenerate and delete; terminal tasks release guard');

  const seed=await setup();
  const statuses=await seed.page.evaluate(()=>{for(const status of ['queued','in_progress','unknown','failed','cancelled'])addMsg({role:'tool',kind:'video',args:{prompt:'boat'},jobId:'job_'+status,result:JSON.stringify({status}),unknown:status==='unknown',error:['unknown','failed','cancelled'].includes(status)?'状态说明':''});V.conv=cur;connect(V.run);const s=sockets.at(-1);s.open();return s.sent.filter(e=>e.item?.type==='function_call_output').map(e=>JSON.parse(e.item.output))});
  assert.deepEqual(statuses.map(x=>x.status),['queued','in_progress','unknown','failed','cancelled']);for(const v of statuses)assert.equal(v.job_id,'job_'+v.status);assert(!statuses[2].error);assert(statuses[2].message);
  await seed.finish('realtime seed preserves all task states and IDs');

  let held;
  const race=await setup(async(r,p)=>{if(p==='/v1/jobs/video_race'){held=r;return true}});
  await race.page.evaluate(()=>{window.m=addMsg({role:'tool',kind:'video',via:'voice',jobId:'video_race',text:'making a video: boat',at:0,seenAt:0});V.byCall.set('race',m);window.poll=watchJobs()});
  while(!held)await new Promise(r=>setTimeout(r,5));
  await race.page.evaluate(()=>handle({type:'localrouter.job.done',call_id:'race',job_id:'video_race',status:'completed',urls:['/v1/files/video_race/video.mp4'],kind:'video'}));
  await race.page.waitForFunction(()=>m.media?.[0]?.url.startsWith('https:'));
  await held.fulfill({json:{id:'video_race',status:'in_progress',progress:50}});await race.page.evaluate(()=>poll);
  assert.equal(await race.page.evaluate(()=>JSON.parse(m.result).status),'completed');assert.equal(await race.page.evaluate(()=>JSON.parse(store.get('convs').find(c=>c.id===cur.id).msgs.find(x=>x.id===m.id).result).status),'completed');
  const alone=await race.page.evaluate(()=>{handle({type:'localrouter.job.done',call_id:'alone',job_id:'alone_job',status:'completed',urls:['/v1/files/alone_job/image.png'],kind:'image'});const m=V.byCall.get('alone');return{job:m.jobId,kind:m.kind,via:m.via,media:m.media.length}});assert.deepEqual(alone,{job:'alone_job',kind:'image',via:'voice',media:1});
  for(const urls of [[],[null],[{}],[''],['  '],['javascript:alert(1)']]) {
   const invalid=await race.page.evaluate(urls=>{handle({type:'localrouter.job.done',call_id:'bad_'+JSON.stringify(urls),job_id:'bad_job_'+JSON.stringify(urls),status:'completed',urls,kind:'video'});const m=V.byCall.get('bad_'+JSON.stringify(urls));return{status:mediaTaskState(m),result:JSON.parse(m.result).status,id:!!m.jobId,media:!!m.media?.length}},urls);
   assert.deepEqual(invalid,{status:'unknown',result:'unknown',id:true,media:false});
  }
  await race.page.evaluate(()=>handle({type:'localrouter.job.done',call_id:'alone',job_id:'alone_job',status:'completed',urls:[],kind:'image'}));assert.equal(await race.page.evaluate(()=>mediaTaskState(V.byCall.get('alone'))),'completed');
  await race.finish('late poll cannot regress completed state; standalone done event retains association');

  let oldPoll;const replaced=await setup(async(r,p,json)=>{if(p==='/v1/jobs/old_job'){oldPoll=r;return true}if(p==='/v1/videos'&&r.request().method()==='POST'){await json({id:'new_job',status:'in_progress'});return true}});
  await replaced.page.evaluate(()=>{window.m=addMsg({role:'tool',kind:'video',via:'voice',jobId:'old_job',args:{prompt:'boat'},text:'making a video: boat',at:0});V.byCall.set('old_call',m);window.poll=watchJobs()});while(!oldPoll)await new Promise(r=>setTimeout(r,5));
  await replaced.page.evaluate(async()=>{jobFinished(m,'failed',[],'upstream failure','video');await retryTool(m)});await replaced.page.waitForFunction(()=>m.jobId==='new_job');
  await oldPoll.fulfill({json:{id:'old_job',status:'in_progress'}});await replaced.page.evaluate(()=>poll);
  await replaced.page.evaluate(()=>handle({type:'localrouter.job.done',call_id:'old_call',job_id:'old_job',status:'failed',error:'late failure',kind:'video'}));
  assert.deepEqual(await replaced.page.evaluate(()=>({id:m.jobId,status:JSON.parse(m.result).status,unknown:!!m.unknown})),{id:'new_job',status:'in_progress',unknown:false});
  await replaced.finish('old poll and voice completion cannot mutate a retried task');

  let analysis;const attachment=await setup(async(r,p)=>{if(p==='/v1/chat/completions'){analysis=r;return true}});await voice(attachment.page);
  await attachment.page.evaluate(()=>{V.resp='old_response';V.thinking=true;V.live=[{src:{stop(){throw Error('old playback stopped')},onended:null}}]});
  await attach(attachment.page,'项目预算为三万元。'+ '资料'.repeat(6000));while(!analysis)await new Promise(r=>setTimeout(r,5));
  const during=await attachment.page.evaluate(()=>{const s=sockets.at(-1),before=s.sent.length;S.mode='vad';micChunk(new Int16Array(960));S.mode='ptt';pttDown();$('text').value='后续问题保留';sendText();return{busy:attachmentVoiceBusy(),held:V.pttHeld,draft:$('text').value,appends:s.sent.slice(before).filter(x=>x.type==='input_audio_buffer.append').length,live:V.live.length}});
  assert.deepEqual(during,{busy:true,held:false,draft:'后续问题保留',appends:0,live:1});
  await analysis.fulfill({contentType:'text/event-stream',body:reply('附件中的预算是三万元。'+ '分析'.repeat(6000))});await attachment.page.waitForFunction(()=>!chats.size);
  assert.equal(await attachment.page.evaluate(()=>attachmentVoiceBusy()),true);assert.equal(await attachment.page.evaluate(()=>sockets.at(-1).sent.filter(x=>x.item?.type==='message').length),0);
  await attachment.page.evaluate(()=>handle({type:'response.done',response:{id:'old_response',status:'completed',output:[]}}));
  const synced=await attachment.page.evaluate(()=>({busy:attachmentVoiceBusy(),items:sockets.at(-1).sent.filter(x=>x.item?.type==='message').map(x=>x.item),live:V.live.length}));
  assert.equal(synced.busy,false);assert.equal(synced.live,1);assert.equal(synced.items.length,2);assert(synced.items[0].content[0].text.includes('三万元'));for(const m of synced.items)assert(m.content[0].text.length<=6000);
  await attachment.page.evaluate(()=>{flushAttachmentVoiceContext();flushAttachmentVoiceContext()});assert.equal(await attachment.page.evaluate(()=>sockets.at(-1).sent.filter(x=>x.item?.type==='message').length),2);
  await attachment.page.evaluate(()=>{V.live=[];connect(V.run);const s=sockets.at(-1);s.open();s.event({type:'session.updated',session:s.sent.find(e=>e.type==='session.update').session})});
  assert.equal(await attachment.page.evaluate(()=>sockets.at(-1).sent.filter(x=>x.item?.type==='message').length),2);assert.equal(await attachment.page.evaluate(()=>attachmentVoiceBusy()),false);
  await attachment.finish('attachment sync waits for safe boundary, gates VAD/PTT/text, preserves playback, bounds content and deduplicates reconnect');

  let cancelReply;const cancelledTurn=await setup(async(r,p)=>{if(p==='/v1/chat/completions'){cancelReply=r;return true}});await voice(cancelledTurn.page);
  await cancelledTurn.page.evaluate(()=>{V.resp='cancel_response';V.thinking=true});await attach(cancelledTurn.page);while(!cancelReply)await new Promise(r=>setTimeout(r,5));
  await cancelledTurn.page.evaluate(()=>bargeIn(true));await cancelReply.fulfill({contentType:'text/event-stream',body:reply('预算三万元。')});await cancelledTurn.page.waitForFunction(()=>!chats.size);
  assert.equal(await cancelledTurn.page.evaluate(()=>attachmentVoiceBusy()),true);assert.equal(await cancelledTurn.page.evaluate(()=>sockets.at(-1).sent.filter(x=>x.item?.type==='message').length),0);
  await cancelledTurn.page.evaluate(()=>handle({type:'response.done',response:{id:'cancel_response',status:'cancelled',output:[]}}));assert.equal(await cancelledTurn.page.evaluate(()=>attachmentVoiceBusy()),false);assert.equal(await cancelledTurn.page.evaluate(()=>sockets.at(-1).sent.filter(x=>x.item?.type==='message').length),2);
  await cancelledTurn.finish('cancelled voice turn waits for server terminal acknowledgement before context injection');

  let reconnectReply;const reconnecting=await setup(async(r,p)=>{if(p==='/v1/chat/completions'){reconnectReply=r;return true}});await voice(reconnecting.page);await attach(reconnecting.page);while(!reconnectReply)await new Promise(r=>setTimeout(r,5));
  await reconnecting.page.evaluate(()=>{const old=sockets.at(-1);old.close(1006,'network');clearTimeout(V.retryTimer);connect(V.run);const next=sockets.at(-1);next.open();next.event({type:'session.updated',session:next.sent.find(x=>x.type==='session.update').session})});
  assert.equal(await reconnecting.page.evaluate(()=>sockets.at(-1).sent.filter(x=>x.item?.type==='message').length),0);
  await reconnectReply.fulfill({contentType:'text/event-stream',body:reply('预算三万元。')});await reconnecting.page.waitForFunction(()=>!chats.size&&!attachmentVoiceBusy());
  assert.deepEqual(await reconnecting.page.evaluate(()=>sockets.map(s=>s.sent.filter(x=>x.item?.type==='message').length)),[0,2]);await reconnecting.finish('HTTP attachment finishing across reconnect targets only the current socket once');

  const image=await setup();await voice(image.page);
  await image.page.evaluate(async()=>{const id='image_test';await putAttachment(id,{blob:new Blob(['mock image'],{type:'image/jpeg'})});cur.pendingAttachments=[{id,name:'photo.jpg',kind:'image',size:10}];$('text').value='分析这张图片';sendText()});await image.page.waitForFunction(()=>!chats.size);
  const imageContext=await image.page.evaluate(()=>sockets.at(-1).sent.filter(x=>x.item?.type==='message'));
  assert.equal(imageContext.length,2);assert(JSON.stringify(imageContext).includes('语音端未直接读取图像'));assert(!JSON.stringify(imageContext).includes('data:image'));assert(!JSON.stringify(imageContext).includes('image_url'));
  await image.finish('image context shares only bounded textual analysis, never image binary');

  for(const outcome of ['failed','empty','cancelled']){
   let waiting;const test=await setup(async(r,p)=>{if(p==='/v1/chat/completions'){waiting=r;return true}});await voice(test.page);await attach(test.page);while(!waiting)await new Promise(r=>setTimeout(r,5));
   if(outcome==='cancelled')await test.page.evaluate(()=>currentChat().ctl.abort());
   else await waiting.fulfill(outcome==='failed'?{status:500,json:{error:{message:'analysis failed'}}}:{contentType:'text/event-stream',body:reply('')});
   await test.page.waitForFunction(()=>!chats.size);const out=await test.page.evaluate(()=>({busy:attachmentVoiceBusy(),messages:sockets.at(-1).sent.filter(x=>x.item?.type==='message').length,state:cur.msgs.find(m=>m.attachments)?.voiceContextState}));assert.equal(out.busy,false);assert.equal(out.messages,0);assert.notEqual(out.state,'completed');await test.finish('attachment '+outcome+' releases gate without injecting a successful result');
  }

  let delayed;const switching=await setup(async(r,p)=>{if(p==='/v1/chat/completions'){delayed=r;return true}});await voice(switching.page);await attach(switching.page);while(!delayed)await new Promise(r=>setTimeout(r,5));
  const owner=await switching.page.evaluate(()=>{const id=cur.id;voiceStop();openConv(newConv().id);return id});await voice(switching.page);await delayed.fulfill({contentType:'text/event-stream',body:reply('预算三万元。')});await switching.page.waitForFunction(()=>!chats.size);
  assert.equal(await switching.page.evaluate(()=>sockets.at(-1).sent.filter(x=>x.item?.type==='message').length),0);
  await switching.page.evaluate(id=>{voiceStop();openConv(id)},owner);await voice(switching.page);assert.equal(await switching.page.evaluate(()=>sockets.at(-1).sent.filter(x=>x.item?.type==='message').length),2);
  await switching.finish('stopped or switched calls receive no stale injection; returning call seeds one copy');

  let deny=true;const auth=await setup(async(r,p,json)=>{if(p==='/needs-login'||deny&&p==='/v1/chat/completions'){await json({error:'login_required'},401);return true}});
  await attach(auth.page);await auth.page.waitForFunction(()=>publicLoginRequired&&!chats.size);
  const restored=await auth.page.evaluate(async()=>{await Promise.all([api('/needs-login'),api('/needs-login'),api('/needs-login')]);$('text').value+=' 新增草稿';onInput();await queueAttachments([new File(['%PDF-mock'],'audit.pdf',{type:'application/pdf'})]);return{draft:$('text').value,files:cur.pendingAttachments.map(x=>({name:x.name,needsExtraction:!!x.needsExtraction})),users:cur.msgs.filter(m=>m.role==='user').length,key:S.key,notice:$('toastText').textContent,label:$('toastUndo').textContent}});
  assert.equal(restored.draft,'读一下这个附件 新增草稿');assert.deepEqual(restored.files,[{name:'budget.txt',needsExtraction:false},{name:'audit.pdf',needsExtraction:true}]);assert.equal(restored.users,0);assert.equal(restored.label,'重新登录');assert.equal(auth.dialogs.length,0);assert(!restored.key);
  const before=auth.requests.length;await auth.page.evaluate(async()=>{await pollTools();await watchJobs();await checkPage();sendText()});assert.equal(auth.requests.length,before);
  await auth.page.getByRole('button',{name:'重新登录',exact:true}).click();await auth.page.waitForURL('**/login');deny=false;await auth.page.goto('http://jarvis.test/voice');await auth.page.waitForFunction(()=>jarvis.ready);
  assert.equal(await auth.page.evaluate(()=>$('text').value),'读一下这个附件 新增草稿');assert.equal(await auth.page.evaluate(()=>cur.pendingAttachments.length),2);
  await auth.page.evaluate(()=>sendText());await auth.page.waitForFunction(()=>!chats.size&&cur.msgs.some(m=>m.role==='assistant'&&m.text));assert(auth.requests.some(x=>x.path==='/v1/jarvis/extract-pdf'));
  await auth.finish('public expiry deduplicates login notice, pauses polling, restores drafts/files and resumes PDF extraction after login');

  let lateAuth;const switchedAuth=await setup(async(r,p)=>{if(p==='/v1/chat/completions'){lateAuth=r;return true}});await attach(switchedAuth.page);while(!lateAuth)await new Promise(r=>setTimeout(r,5));
  const original=await switchedAuth.page.evaluate(()=>{const id=cur.id;openConv(newConv().id);$('text').value='另一个会话的草稿';onInput();return id});
  await lateAuth.fulfill({status:401,json:{error:'login_required'}});await switchedAuth.page.waitForFunction(()=>publicLoginRequired&&!chats.size);
  assert.deepEqual(await switchedAuth.page.evaluate(id=>({current:$('text').value,previous:convs.find(c=>c.id===id).draft,files:convs.find(c=>c.id===id).pendingAttachments.length}),original),{current:'另一个会话的草稿',previous:'读一下这个附件',files:1});await switchedAuth.finish('late login rejection restores the originating conversation without overwriting another draft');

  const pageAuth=await setup();await pageAuth.page.evaluate(()=>{window.fetch=async()=>{const response=new Response('<title>登录</title>',{status:200});Object.defineProperty(response,'url',{value:location.origin+'/login'});return response}});
  await pageAuth.page.evaluate(()=>checkPage());assert.equal(await pageAuth.page.evaluate(()=>publicLoginRequired),true);assert.equal(await pageAuth.page.evaluate(()=>pageNotified),null);assert.equal(pageAuth.dialogs.length,0);await pageAuth.finish('page-version check recognizes login redirect without a false update notification');

  const native=await setup(async(r,p,json)=>{if(p==='/key-required'){await json({error:{message:'missing API key'}},r.request().headers().authorization==='Bearer native-key'?200:401);return true}});assert.equal(await native.page.evaluate(async()=> (await api('/key-required')).status),200);assert.equal(native.dialogs.length,1);assert(native.dialogs[0].includes('API 密钥'));await native.finish('native API key authentication keeps existing prompt and retry');
  console.log(JSON.stringify({passed:true,checks:results.length,tests:results,sandbox_only:true},null,2));
 }finally{await browser.close()}
})().catch(e=>{console.error(e.stack);process.exitCode=1});
