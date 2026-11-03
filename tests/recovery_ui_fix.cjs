const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,args:['--autoplay-policy=no-user-gesture-required']});let checks=0;
 try{
  const page=await browser.newPage();const errors=[],calls=[];const jobs=new Map();let sequence=0,network=false,submissionMode='';
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('**/*',async r=>{
   const p=new URL(r.request().url()).pathname;calls.push([r.request().method(),p]);const json=(x,status=200)=>r.fulfill({status,json:x});
   if(p==='/voice')return r.fulfill({contentType:'text/html',body:fs.readFileSync(path.join(__dirname,'../src/voice/voice.html'),'utf8')});
   if(p==='/v1/models')return json({data:[{id:'chat',kind:'chat'},{id:'speech',kind:'speech',voices:['Ezra'],default_voice:'Ezra'},{id:'asr',kind:'transcription'},{id:'video',kind:'video',limits:{max_seconds:15}}]});
   if(p==='/v1/tools')return json({data:['chat','speech','asr','video'].map(id=>({id,kind:id==='asr'?'transcription':id,state:'ready'}))});
   if((p==='/v1/videos'||p==='/v1/images/generations')&&r.request().method()==='POST'&&submissionMode){
    const mode=submissionMode;submissionMode='';
    if(mode==='missing-id')return json({status:'in_progress'});
    if(mode==='image-null')return r.fulfill({contentType:'application/json',body:'null'});
    if(mode==='image-empty')return json({});
    if(mode==='image-no-results')return json({data:[]});
    if(mode==='drop')return r.abort('connectionreset');
    if(mode==='invalid-json')return r.fulfill({contentType:'application/json',body:'{"status":'});
    if(mode==='reject')return json({error:{message:'explicit refusal'}},400);
   }
   if(p==='/v1/videos'&&r.request().method()==='POST'){const id='video_'+String(++sequence).padStart(8,'0');jobs.set(id,{id,status:'in_progress',progress:10});await new Promise(ok=>setTimeout(ok,20));return json(jobs.get(id));}
   if(/^\/v1\/(videos|jobs)\//.test(p)&&!p.endsWith('/content')){if(network)return json({error:{message:'temporarily unavailable'}},503);const id=p.split('/').at(-1);return json(jobs.get(id)||{error:{message:'not found'}},jobs.has(id)?200:404);}
   if(p==='/v1/media/share')return json({url:'https://jarvis.test/media/signed-test'});
   return json({enabled:false});
  });
  await page.addInitScript(()=>{window.sockets=[];class Socket{static OPEN=1;static CONNECTING=0;constructor(){this.readyState=0;this.sent=[];sockets.push(this)}send(x){this.sent.push(JSON.parse(x))}close(code=1000,reason=''){this.readyState=3;this.onclose?.({code,reason})}open(){this.readyState=1;this.onopen?.({})}event(x){this.onmessage?.({data:JSON.stringify(x)})}}window.WebSocket=Socket;});
  await page.goto('http://jarvis.test/voice');await page.waitForFunction(()=>jarvis.ready);
  const ids=await page.evaluate(()=>{const owner=cur;const m=addMsg({role:'tool',kind:'video',args:{prompt:'original prompt',seconds:15},text:'making a video: original prompt',owner:PAGE_ID});startMediaTask(m,m.args,owner);openConv(newConv().id);return{owner:owner.id,card:m.id};});
  await page.waitForFunction(id=>!!convs.flatMap(c=>c.msgs).find(m=>m.id===id)?.jobId,ids.card);
  let snapshot=await page.evaluate(({owner,card})=>{const stored=store.get('convs').find(c=>c.id===owner).msgs.find(m=>m.id===card);return{jobId:stored.jobId,prompt:stored.args.prompt,current:cur.id,route:stored.jobRoute};},ids);
  assert.equal(snapshot.jobId,'video_00000001');assert.equal(snapshot.prompt,'original prompt');assert.notEqual(snapshot.current,ids.owner);assert.equal(snapshot.route,'videos');checks++;
  await page.reload();await page.waitForFunction(()=>jarvis.ready);await page.evaluate(id=>openConv(id),ids.owner);
  await page.evaluate(async()=>{await watchJobs()});
  snapshot=await page.evaluate(id=>{const m=cur.msgs.find(x=>x.id===id);return{jobId:m.jobId,error:m.error||'',status:JSON.parse(m.result).status};},ids.card);
  assert.deepEqual(snapshot,{jobId:'video_00000001',error:'',status:'in_progress'});assert.equal(sequence,1);assert(calls.some(([method,p])=>method==='GET'&&p==='/v1/videos/video_00000001'));checks++;
  await page.evaluate(async id=>{await retryTool(cur.msgs.find(m=>m.id===id))},ids.card);assert.equal(sequence,1);checks++;
  network=true;await page.evaluate(async id=>{const m=cur.msgs.find(m=>m.id===id);m.seenAt=0;m.at=0;await watchJobs()},ids.card);
  snapshot=await page.evaluate(id=>{const m=cur.msgs.find(m=>m.id===id);return{unknown:m.unknown,failed:m.failed,status:JSON.parse(m.result).status,prompt:m.args.prompt};},ids.card);
  assert.deepEqual(snapshot,{unknown:true,failed:null,status:'unknown',prompt:'original prompt'});checks++;
  network=false;jobs.set('video_00000001',{id:'video_00000001',status:'completed',progress:100});
  await page.evaluate(async id=>{const m=cur.msgs.find(m=>m.id===id);m.seenAt=0;await watchJobs()},ids.card);
  snapshot=await page.evaluate(id=>{const m=cur.msgs.find(m=>m.id===id);return{status:JSON.parse(m.result).status,media:m.media.length,error:m.error,unknown:m.unknown}},ids.card);
  assert.deepEqual(snapshot,{status:'completed',media:1,error:'',unknown:false});assert.equal(sequence,1);checks++;
  const image=await page.evaluate(async()=>{const m=addMsg({role:'tool',kind:'image',text:'making a picture: saved image prompt',owner:'old-page'});await watchJobs();return{unknown:m.unknown,failed:m.failed,prompt:m.args.prompt,status:JSON.parse(m.result).status,text:m.text}});
  assert.equal(image.unknown,true);assert.equal(image.failed,null);assert.equal(image.prompt,'saved image prompt');assert.equal(image.status,'unknown');assert(image.text.includes('状态待确认'));assert(!image.text.includes('已中断'));checks++;
  jobs.set('video_voice',{id:'video_voice',status:'completed',urls:['/v1/files/video_voice/video.mp4']});
  const voice=await page.evaluate(async()=>{const m=addMsg({role:'tool',kind:'video',via:'voice',text:'making a video: voice prompt',jobId:'video_voice',seenAt:0,at:0});await watchJobs();return{status:JSON.parse(m.result).status,media:m.media?.length,via:m.via}});
  assert.deepEqual(voice,{status:'completed',media:1,via:'voice'});assert(calls.some(([,p])=>p==='/v1/jobs/video_voice'));checks++;
  const cancelledId=await page.evaluate(()=>{const m=addMsg({role:'tool',kind:'video',args:{prompt:'cancelled wait'},text:'making a video: cancelled wait',owner:PAGE_ID});startMediaTask(m,m.args,cur);return m.id});
  await page.waitForFunction(id=>!!cur.msgs.find(m=>m.id===id)?.jobId,cancelledId);
  const cancelled=await page.evaluate(async id=>{const task=mediaTasks.get(id);task.ctl.abort();await task.promise;const m=cur.msgs.find(m=>m.id===id);return{unknown:m.unknown,status:JSON.parse(m.result).status,job:m.jobId}},cancelledId);
  assert.equal(cancelled.status,'unknown');assert.equal(cancelled.unknown,true);jobs.set(cancelled.job,{id:cancelled.job,status:'cancelled',error:{message:'cancelled by server'}});
  await page.evaluate(async id=>{const m=cur.msgs.find(m=>m.id===id);m.seenAt=0;m.at=0;await watchJobs()},cancelledId);
  assert.equal(await page.evaluate(id=>JSON.parse(cur.msgs.find(m=>m.id===id).result).status,cancelledId),'cancelled');checks++;
  for(const [kind,mode] of [['video','missing-id'],['video','drop'],['video','invalid-json'],['image','drop'],['image','invalid-json'],['image','image-null'],['image','image-empty'],['image','image-no-results']]){
   submissionMode=mode;const path=kind==='video'?'/v1/videos':'/v1/images/generations';const before=calls.filter(([method,p])=>method==='POST'&&p===path).length;
   const outcome=await page.evaluate(async kind=>{const m=addMsg({role:'tool',kind,args:{prompt:'ambiguous original'},text:`making ${kind==='video'?'a video':'a picture'}: ambiguous original`,owner:PAGE_ID});startMediaTask(m,m.args,cur);await mediaTasks.get(m.id).promise;const outcome={status:JSON.parse(m.result).status,unknown:m.unknown,failed:!!m.failed,prompt:m.args.prompt};await retryTool(m);return outcome},kind);
   assert.deepEqual(outcome,{status:'unknown',unknown:true,failed:false,prompt:'ambiguous original'});assert.equal(calls.filter(([method,p])=>method==='POST'&&p===path).length,before+1);checks++;
  }
  const abortedSubmission=await page.evaluate(async()=>{
   const original=window.fetch;let started=false;
   window.fetch=(url,opts)=>String(url)==='/v1/images/generations'?new Promise((resolve,reject)=>{started=true;opts.signal.addEventListener('abort',()=>reject(new DOMException('aborted','AbortError')),{once:true})}):original(url,opts);
   try{const m=addMsg({role:'tool',kind:'image',args:{prompt:'abort after submission'},owner:PAGE_ID});startMediaTask(m,m.args,cur);const task=mediaTasks.get(m.id);task.ctl.abort();await task.promise;return{started,status:JSON.parse(m.result).status,unknown:m.unknown,failed:!!m.failed}}finally{window.fetch=original}
  });
  assert.deepEqual(abortedSubmission,{started:true,status:'unknown',unknown:true,failed:false});checks++;
  submissionMode='reject';const rejected=await page.evaluate(async()=>{const m=addMsg({role:'tool',kind:'video',args:{prompt:'refused'},owner:PAGE_ID});startMediaTask(m,m.args,cur);await mediaTasks.get(m.id).promise;return{status:JSON.parse(m.result).status,unknown:m.unknown,failed:!!m.failed}});
  assert.deepEqual(rejected,{status:'failed',unknown:false,failed:true});checks++;
  const beforeInvalid=calls.filter(([method,p])=>method==='POST'&&p==='/v1/videos').length;
  const invalid=await page.evaluate(async()=>{const m=addMsg({role:'tool',kind:'video',args:{prompt:'invalid duration',seconds:999},owner:PAGE_ID});startMediaTask(m,m.args,cur);await mediaTasks.get(m.id)?.promise;return JSON.parse(m.result).status});
  assert.equal(invalid,'failed');assert.equal(calls.filter(([method,p])=>method==='POST'&&p==='/v1/videos').length,beforeInvalid);checks++;
  const delay=await page.evaluate(async()=>{const ctl=new AbortController(),signal=ctl.signal,live=new Set();const add=signal.addEventListener.bind(signal),remove=signal.removeEventListener.bind(signal);signal.addEventListener=(type,fn,...rest)=>{if(type==='abort')live.add(fn);return add(type,fn,...rest)};signal.removeEventListener=(type,fn,...rest)=>{if(type==='abort')live.delete(fn);return remove(type,fn,...rest)};for(let i=0;i<12;i++)await mediaPollDelay(0,signal);const afterNormal=live.size;const promise=mediaPollDelay(10000,signal).then(()=>'',e=>e.name);ctl.abort();const name=await promise;const afterAbort=live.size;const pre=await mediaPollDelay(0,signal).then(()=>'',e=>e.name);return{afterNormal,afterAbort,name,pre}});
  assert.deepEqual(delay,{afterNormal:0,afterAbort:0,name:'AbortError',pre:'AbortError'});checks++;
  const lifecycle=await page.evaluate(async()=>{V.conv=cur;V.ctx=new AudioContext();await V.ctx.resume();V.mic={getAudioTracks(){return[{readyState:'live',muted:false}]},getTracks(){return[]}};S.speechModel='speech';S.voices.speech='Ezra';V.paused=true;connect(V.run);const first=sockets.at(-1);first.open();first.event({type:'session.updated',session:first.sent.find(e=>e.type==='session.update').session});const healthy={paused:V.paused,state:voiceState()};first.event({type:'localrouter.voice.paused',model:'speech'});sessionUpdate();first.event({type:'session.updated',session:first.sent.filter(e=>e.type==='session.update').at(-1).session});const actualPause=V.paused;first.close(1006,'network');clearTimeout(V.retryTimer);const closed=V.paused;connect(V.run);const second=sockets.at(-1);second.open();first.event({type:'localrouter.voice.paused',model:'speech'});const stale=V.paused;second.event({type:'localrouter.voice.paused',model:'speech'});second.event({type:'session.updated',session:second.sent.find(e=>e.type==='session.update').session});const newPause=V.paused;voiceStop();return{healthy,actualPause,closed,stale,newPause,stopped:V.paused}});
  assert.equal(lifecycle.healthy.paused,false);assert.notEqual(lifecycle.healthy.state,'paused');assert.deepEqual({...lifecycle,healthy:undefined},{healthy:undefined,actualPause:true,closed:false,stale:false,newPause:true,stopped:false});checks++;
  assert.deepEqual(errors,[]);console.log(JSON.stringify({passed:true,checks,sandbox_only:true}));
 }finally{await browser.close()}
})().catch(e=>{console.error(e.stack);process.exitCode=1});
