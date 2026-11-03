const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true});const errors=[];let checks=0;
 try {
  const page=await browser.newPage();page.on('pageerror',e=>errors.push(e.message));
  await page.route('**/*',route=>{
   const p=new URL(route.request().url()).pathname;
   if(p==='/voice')return route.fulfill({contentType:'text/html',body:fs.readFileSync(path.join(__dirname,'../src/voice/voice.html'),'utf8')});
   const data=p==='/v1/models'?{data:[{id:'chat',kind:'chat',jarvis:{voice_effort_models:{none:'chat-none',low:'chat-low',medium:'chat-medium',high:'chat-high'}}},{id:'speech',kind:'speech',voices:['Ezra'],default_voice:'Ezra'},{id:'asr',kind:'transcription'}]}:p==='/v1/tools'?{data:[{id:'chat',kind:'chat',state:'ready'},{id:'speech',kind:'speech',state:'ready',keep_loaded:true},{id:'asr',kind:'transcription',state:'ready',keep_loaded:true}]}:{enabled:false};
   return route.fulfill({json:data});
  });
  await page.goto('http://jarvis.test/voice');await page.waitForFunction(()=>jarvis.ready);
  await page.evaluate(()=>{
   window.sentUpdates=[];
   window.resetUpdates=()=>{V.ws={readyState:WebSocket.OPEN,send(x){sentUpdates.push(JSON.parse(x))}};V.sessionUpdates=[];V.expectedSession=null;V.pendingUpdates=0;V.sessionReady=false;V.configError='';V.pendingPcm=[];sentUpdates.length=0;S.speechModel='speech';S.voices.speech='Ezra';};
   window.ackUpdate=(request,changes={})=>handle({type:'session.updated',session:{...request.session,...changes}});
   window.latestUpdate=()=>sentUpdates.filter(x=>x.type==='session.update').at(-1);
  });
  for(const think of [false,true])for(const voiceEffort of ['none','low']){
   const r=await page.evaluate(({think,voiceEffort})=>{resetUpdates();S.think=think;S.voiceReasoningEffort=voiceEffort;sessionUpdate();const req=latestUpdate();ackUpdate(req);return{requested:req.session.reasoning,ready:V.sessionReady,error:V.configError,pending:V.pendingUpdates};},{think,voiceEffort});
   assert.deepEqual(r,{requested:voiceEffort!=='none',ready:true,error:'',pending:0});checks++;
  }
  for(const think of [false,true]){
   const r=await page.evaluate(think=>{resetUpdates();S.think=think;S.reasoningEffort='high';S.voiceReasoningEffort='follow';sessionUpdate();const req=latestUpdate();ackUpdate(req);return{reasoning:req.session.reasoning,model:req.session.model,ready:V.sessionReady};},think);
   assert.deepEqual(r,{reasoning:think,model:think?'chat-high':'chat-none',ready:true});checks++;
  }
  const queued=await page.evaluate(()=>{resetUpdates();S.think=true;S.voiceReasoningEffort='none';sessionUpdate();const first=latestUpdate();S.think=false;S.voiceReasoningEffort='low';sessionUpdate();const second=latestUpdate();ackUpdate(first);const intermediate={ready:V.sessionReady,pending:V.pendingUpdates,error:V.configError};ackUpdate(second);ackUpdate(first);return{intermediate,ready:V.sessionReady,pending:V.pendingUpdates,error:V.configError,unique:first.event_id!==second.event_id};});
  assert.deepEqual(queued,{intermediate:{ready:false,pending:1,error:''},ready:true,pending:0,error:'',unique:true});checks++;
  const rejectedOld=await page.evaluate(()=>{resetUpdates();S.voiceReasoningEffort='none';sessionUpdate();const first=latestUpdate();S.voiceReasoningEffort='low';sessionUpdate();const second=latestUpdate();handle({type:'error',error:{code:'invalid_session',message:'old invalid',event_id:first.event_id}});const before={pending:V.pendingUpdates,error:V.configError,ready:V.sessionReady};ackUpdate(second);handle({type:'error',error:{code:'invalid_session',message:'stale rejection',event_id:first.event_id}});return{before,ready:V.sessionReady,error:V.configError};});
  assert.deepEqual(rejectedOld,{before:{pending:1,error:'',ready:false},ready:true,error:''});checks++;
  const rejectedLatest=await page.evaluate(()=>{resetUpdates();S.voiceReasoningEffort='none';sessionUpdate();const first=latestUpdate();S.voiceReasoningEffort='low';sessionUpdate();const second=latestUpdate();V.pendingPcm=[new Int16Array(2)];handle({type:'error',error:{code:'invalid_session',message:'bad config',event_id:second.event_id}});ackUpdate(first);const rejected={ready:V.sessionReady,error:V.configError,pcm:V.pendingPcm.length,pending:V.pendingUpdates};sessionUpdate();ackUpdate(latestUpdate());return{rejected,ready:V.sessionReady,error:V.configError};});
  assert.deepEqual(rejectedLatest,{rejected:{ready:false,error:'bad config',pcm:0,pending:0},ready:true,error:''});checks++;
  for(const changes of [{reasoning:false},{voice:'Other'},{model:'wrong'}]){
   const r=await page.evaluate(changes=>{resetUpdates();S.voiceReasoningEffort='low';sessionUpdate();ackUpdate(latestUpdate(),changes);return{ready:V.sessionReady,error:!!V.configError};},changes);
   assert.deepEqual(r,{ready:false,error:true});checks++;
  }
  for(const state of ['unknown','unavailable'])for(const kind of ['chat','speech','transcription']){
   const r=await page.evaluate(({state,kind})=>{online=true;tools={data:models.map(m=>({id:m.id,kind:m.kind,state:m.kind===kind?state:'ready'}))};renderStatus();return{overall:overall(),text:document.getElementById('statusPop').textContent};},{state,kind});
   assert.deepEqual(r.overall,['unknown','模型状态未知']);assert(!r.text.includes('unavailable'));assert(r.text.includes(state==='unavailable'?'暂不可查询':'状态未知'));checks++;
  }
  const ready=await page.evaluate(()=>{tools={data:models.map(m=>({id:m.id,kind:m.kind,state:'ready'}))};return overall()});assert.deepEqual(ready,['ready','已就绪']);checks++;
  await page.evaluate(()=>{V.ws=null;});assert.deepEqual(errors,[]);
  console.log(JSON.stringify({passed:true,checks,sandbox_only:true}));
 } finally {await browser.close();}
})().catch(e=>{console.error(e.stack);process.exitCode=1});
