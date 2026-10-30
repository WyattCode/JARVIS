// Browser regression checks. Run with Playwright installed (PLAYWRIGHT_MODULE may name an existing installation).
const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs=require('fs'),path=require('path'),assert=require('assert');
(async()=>{
 const browser=await chromium.launch({headless:true,args:['--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream']});
 try {
 const context=await browser.newContext({permissions:['microphone'],locale:'zh-CN',reducedMotion:'reduce'});
 const page=await context.newPage();const errors=[];let httpChats=0;
 page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/*',async route=>{
  const u=new URL(route.request().url());
  const reply=data=>route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(data)});
  if(u.pathname==='/voice')return route.fulfill({status:200,contentType:'text/html',body:fs.readFileSync(process.env.VOICE_HTML||path.join(__dirname,'../src/voice/voice.html'),'utf8')});
  if(u.pathname==='/v1/models')return reply({data:[{id:'chat',name:'Chat',kind:'chat'},{id:'speech',name:'Speech',kind:'speech',voices:['Mae','Nora'],default_voice:'Mae',default_for:['text_to_speech']}]});
  if(u.pathname==='/v1/tools')return reply({data:[{id:'chat',state:'ready',keep_loaded:true},{id:'speech',state:'ready',keep_loaded:true}],mem_available_bytes:24000000000});
  if(u.pathname==='/v1/skills/model-manager')return reply({enabled:false,text:''});
  if(u.pathname==='/v1/chat/completions'){httpChats++;return route.abort();}
  return reply({});
 });
 await page.addInitScript(()=>{
  window.__sockets=[];window.__sent=[];
  class Socket {
   static CONNECTING=0;static OPEN=1;static CLOSING=2;static CLOSED=3;
   constructor(){this.readyState=0;window.__sockets.push(this);}
   open(){this.readyState=1;this.onopen?.({});}
   send(s){const e=JSON.parse(s);if(e.type==='session.update')this.settings=e.session;window.__sent.push(e);if(e.type==='input_audio_buffer.clear')this.event({type:'input_audio_buffer.cleared'});}
   close(code=1000,reason=''){this.readyState=3;this.onclose?.({code,reason});}
   event(e){if(e.type==='session.updated'){const s=[...__sent].reverse().find(x=>x.type==='session.update')?.session||{};e.session={speech_model:this.settings?.speech_model??s.speech_model,voice:this.settings?.voice??s.voice,...e.session}}this.onmessage?.({data:JSON.stringify(e)});}
  }
  window.WebSocket=Socket;
 });
 await page.goto('http://127.0.0.1:8190/voice');await page.waitForFunction(()=>window.jarvis?.ready);
 await page.evaluate(()=>{S.mode='ptt';S.think=false;});await page.locator('#mic').click();
 await page.waitForFunction(()=>__sockets.length===1&&V.mic);
 await page.evaluate(()=>window.jarvis.say('首条消息必须保留'));
 assert.equal(await page.locator('#text').inputValue(),'首条消息必须保留');assert.equal(httpChats,0);
 await page.evaluate(()=>{__sockets[0].open();__sockets[0].event({type:'session.created',session:{instructions:'原始语音指令'}})});
 await page.waitForFunction(()=>__sent.some(x=>x.type==='session.update'));
 assert.equal(await page.evaluate(()=>voiceReady()),false);
 await page.evaluate(()=>{for(let i=0;i<100;i++)sendPcm(new Int16Array(960));});
 assert.equal(await page.evaluate(()=>V.pendingPcm.length),50);
 await page.evaluate(()=>__sockets[0].event({type:'session.updated',session:{reasoning:false}}));
 assert.equal(await page.evaluate(()=>voiceReady()),true);
 assert.equal(await page.evaluate(()=>V.pendingPcm.length),0);
 await page.evaluate(()=>{tools.data.find(m=>m.id==='speech').state='loading'});
 assert.equal(await page.evaluate(()=>voiceReady()),false);
 assert.equal(await page.evaluate(()=>voiceState()),'warming');
 await page.evaluate(()=>{tools.data.find(m=>m.id==='speech').state='ready';renderControls()});
 await page.locator('#vmMin').click();
 await page.locator('#send').click();
 assert.equal(await page.evaluate(()=>__sent.filter(x=>x.type==='response.create').length),1);assert.equal(httpChats,0);
 // Holding an audio reply must never activate push-to-talk recording.
 const collision=await page.evaluate(()=>{
  V.thinking=false;V.resp=null;V.bufferedItem='audio';V.pttHeld=false;const before=__sent.length;
  micChunk(new Int16Array(960));return{state:voiceState(),sent:__sent.length-before};
 });
 assert.equal(collision.state,'ptt');assert.equal(collision.sent,0);
 await page.evaluate(()=>{V.bufferedItem=null});
 await page.locator('#gear').click();await page.locator('#thinkSw').check();await page.locator('#drawerClose').click();
 assert.equal(await page.evaluate(()=>__sent.filter(x=>x.type==='session.update').at(-1).session.reasoning),true);
 assert.equal(await page.evaluate(()=>voiceReady()),false);
 await page.evaluate(()=>__sockets[0].event({type:'session.updated',session:{reasoning:true}}));
 assert.equal(await page.evaluate(()=>voiceReady()),true);
 await page.evaluate(()=>{S.instructions='新的指令';sessionUpdate();S.instructions='';sessionUpdate();});
 assert.equal(await page.evaluate(()=>__sent.filter(x=>x.type==='session.update').at(-1).session.instructions), await page.evaluate(()=>languageInstructions('原始语音指令')));
 assert(await page.evaluate(()=>languageInstructions('自定义指令').includes(LANGUAGE_POLICY)));
 assert.equal(await page.evaluate(()=>languageInstructions(languageInstructions('x'))), await page.evaluate(()=>languageInstructions('x')));
 await page.evaluate(()=>{__sockets[0].event({type:'session.updated',session:{reasoning:true}});__sockets[0].event({type:'session.updated',session:{reasoning:true}})});
 await page.locator('#mic').click();
 // Paused browser output keeps received PCM, and a user gesture resumes it.
 await page.evaluate(async()=>{
  await V.ctx.suspend();
  const pcm=new Int16Array(2400).fill(2000);play('resume-test',toB64(new Uint8Array(pcm.buffer)));
  V.speechDone.add('resume-test');V.replyDone.add('resume-test');
 });
 assert.equal(await page.evaluate(()=>voiceState()),'audioBlocked');
 assert.equal(await page.evaluate(()=>V.started.has('resume-test')),false);
 await page.locator('#orb').click();
 await page.waitForFunction(()=>V.ctx.state==='running'&&V.started.has('resume-test'));
 // No settings or PCM cross a reconnect before that socket's acknowledgement.
 await page.evaluate(()=>{__sockets[0].close(1006,'network');clearTimeout(V.retryTimer);connect(V.run);__sockets[1].open();});
 assert.equal(await page.evaluate(()=>voiceReady()),false);
 await page.evaluate(()=>__sockets[1].event({type:'session.updated',session:{reasoning:true}}));
 assert.equal(await page.evaluate(()=>voiceReady()),true);
 await page.evaluate(()=>{
  const m=botMsg('failed-audio');m.text='保留文字';
  handle({type:'error',error:{code:'speech_failed',message:'the speech model wrote no audio'}});
 });
 await page.waitForFunction(()=>document.querySelector('#log').textContent.includes('语音生成失败'));
 assert.equal(await page.evaluate(()=>voiceState()),'speechError');
 assert((await page.locator('#vmHint').innerText()).includes('语音引擎没有返回有效音频'));
 // Interrupt audio before scheduling; neither buffered nor late PCM may play.
 const interrupted=await page.evaluate(()=>{
  silence();V.speechError='';V.resp='buffered-response';
  const pcm=new Int16Array(2400).fill(2000),audio=toB64(new Uint8Array(pcm.buffer));
  play('buffered-cancel',audio);const before=V.held.length;
  bargeIn(true);V.speechDone.add('buffered-cancel');startOrWait('buffered-cancel');play('buffered-cancel',audio);
  return {before,held:V.held.length,cut:V.cut.has('buffered-cancel'),started:V.started.has('buffered-cancel')};
 });
 assert.deepEqual(interrupted,{before:1,held:0,cut:true,started:false});
 // A cancel before the first PCM must reject even a late, newly seen item id.
 const earlyCancel=await page.evaluate(()=>{
  silence();handle({type:'response.created',response:{id:'cancel-before-pcm'}});
  handle({type:'response.text.delta',response_id:'cancel-before-pcm',item_id:'unheard-text',delta:'未听到的正文'});bargeIn(true);
  const audio=toB64(new Uint8Array(new Int16Array(7200).fill(2000).buffer));
  handle({type:'response.audio.delta',response_id:'cancel-before-pcm',item_id:'late-first-item',delta:audio});
  return {queued:V.live.length+V.held.length,started:V.started.has('late-first-item'),unheard:__sent.find(x=>x.type==='conversation.item.truncate'&&x.item_id==='unheard-text')?.audio_end_ms};
 });
 assert.deepEqual(earlyCancel,{queued:0,started:false,unheard:0});
 assert.equal(await page.evaluate(()=>{const m=botMsg('historical-without-response');m.text='历史正文';bargeIn(false);return !!m.interrupted;}),false);
 // A late completion from the old response must not clear the new one.
 const staleDone=await page.evaluate(()=>{
  handle({type:'response.created',response:{id:'new-response'}});V.thinking=true;
  handle({type:'response.done',response:{id:'cancel-before-pcm',status:'cancelled',output:[]}});
  return {response:V.resp,thinking:V.thinking};
 });
 assert.deepEqual(staleDone,{response:'new-response',thinking:true});
 // An active reply preserves the next typed message, including before response.created.
 for(const active of ['thinking','response']) {
  const result=await page.evaluate(active=>{
   __sent.length=0;V.thinking=active==='thinking';V.resp=active==='response'?'active':null;
   $('text').value='下一条保留';sendText();
   return {input:$('text').value,creates:__sent.filter(x=>x.type==='response.create').length};
  },active);
  assert.deepEqual(result,{input:'下一条保留',creates:0});
 }
 await page.evaluate(()=>{V.thinking=false;V.resp=null;sendText()});
 assert.equal(await page.evaluate(()=>__sent.filter(x=>x.type==='response.create').length),1);
 assert.equal(await page.locator('#text').inputValue(),'');
 // Re-pressing cancels the old release timer; only the final release commits.
 await page.evaluate(()=>{V.thinking=false;V.resp=null;__sent.length=0;pttDown();V.holdStart=performance.now()-500;pttUp();});
 await page.waitForTimeout(80);await page.evaluate(()=>pttDown());await page.waitForTimeout(180);
 assert.equal(await page.evaluate(()=>V.pttHeld),true);
 assert.equal(await page.evaluate(()=>__sent.filter(x=>x.type==='input_audio_buffer.commit').length),0);
 await page.evaluate(()=>{V.holdStart=performance.now()-500;pttUp()});await page.waitForTimeout(260);
 assert.equal(await page.evaluate(()=>__sent.filter(x=>x.type==='input_audio_buffer.commit').length),1);
 // Text completion and a long wait cannot release an incomplete speech reply.
 await page.evaluate(()=>{silence();V.resp=null;V.thinking=false;V.awaitingTranscript=null;V.transcriptionError='';play('complete-reply',toB64(new Uint8Array(new Int16Array(7200).fill(2000).buffer)));textDone('complete-reply',500);renderVoice();});
 await page.waitForTimeout(900);
 assert.equal(await page.evaluate(()=>V.started.has('complete-reply')),false);
 assert.equal(await page.evaluate(()=>voiceState()),'thinking');
 assert.match(await page.locator('#vmState').textContent(),/准备语音/);
 await page.evaluate(()=>{play('complete-reply',toB64(new Uint8Array(new Int16Array(4800).fill(2000).buffer)));handle({type:'localrouter.response.speech_done',item_id:'complete-reply'});});
 assert.equal(await page.evaluate(()=>V.started.has('complete-reply')),false);
 await page.evaluate(()=>handle({type:'response.done',response:{id:'complete-reply-response',status:'completed',output:[{id:'complete-reply'}]}}));
 assert.equal(await page.evaluate(()=>V.started.has('complete-reply')),true);
 assert.equal(await page.evaluate(()=>V.live.filter(p=>p.item==='complete-reply').length),1);
 // Backend completion must not accept a second typed turn while its audio is playing.
 const blockedTyped=await page.evaluate(()=>{__sent.length=0;$('text').value='等待播完再发';onInput();sendText();return{input:$('text').value,creates:__sent.filter(x=>x.type==='response.create').length}});
 assert.deepEqual(blockedTyped,{input:'等待播完再发',creates:0});assert.equal(await page.locator('#send').isDisabled(),true);
 await page.waitForFunction(()=>V.live.length===0);assert.equal(await page.locator('#send').isEnabled(),true);
 await page.evaluate(()=>{$('text').value='';onInput();});
 // Short replies obey the same completion rule, without a second timeout policy.
 await page.evaluate(()=>{silence();play('short-complete',toB64(new Uint8Array(new Int16Array(960).fill(2000).buffer)));});
 await page.waitForTimeout(800);assert.equal(await page.evaluate(()=>V.started.has('short-complete')),false);
 await page.evaluate(()=>{handle({type:'localrouter.response.speech_done',item_id:'short-complete'});handle({type:'response.done',response:{id:'short-complete-response',status:'completed',output:[{id:'short-complete'}]}});});
 assert.equal(await page.evaluate(()=>V.started.has('short-complete')),true);
 // Cancelling a reply before the last sentence is ready must discard its audio.
 await page.evaluate(()=>{silence();V.resp='cancel-wait';play('cancel-wait-item',toB64(new Uint8Array(new Int16Array(2400).fill(2000).buffer)));bargeIn(true);handle({type:'localrouter.response.speech_done',response_id:'cancel-wait',item_id:'cancel-wait-item'});});
 assert.equal(await page.evaluate(()=>V.held.length+V.live.length),0);
 // A failed reply without a completion marker must not leave unplayable PCM waiting forever.
 await page.evaluate(()=>{V.resp='failed-wait';play('failed-item',toB64(new Uint8Array(new Int16Array(2400).fill(2000).buffer)));handle({type:'response.done',response:{id:'failed-wait',status:'failed',output:[{id:'failed-item'}]}});});
 assert.equal(await page.evaluate(()=>V.held.some(p=>p.item==='failed-item')),false);
 // A completed TTS stream must still be withheld when final response status is not successful.
 for(const status of ['failed','cancelled','incomplete']){
  const rejected=await page.evaluate(status=>{silence();const item='reject-'+status;V.resp='response-'+item;play(item,toB64(new Uint8Array(new Int16Array(2400).fill(2000).buffer)));handle({type:'localrouter.response.speech_done',response_id:V.resp,item_id:item});const premature=V.started.has(item);handle({type:'response.done',response:{id:V.resp,status,output:[{id:item}]}});return{premature,held:V.held.some(p=>p.item===item),started:V.started.has(item)};},status);
  assert.deepEqual(rejected,{premature:false,held:false,started:false});
 }
 // Adaptive playback starts a fast reply before completion, and a later failure stops its queued sources.
 await page.evaluate(()=>{silence();handle({type:'response.created',response:{id:'adaptive-response'}});handle({type:'response.text.delta',response_id:'adaptive-response',item_id:'adaptive-item',delta:'我们正在检查连续播放。'.repeat(8)});play('adaptive-item',toB64(new Uint8Array(new Int16Array(2400).fill(2000).buffer)));handle({type:'localrouter.response.text_done',item_id:'adaptive-item',chars:300});});
 await page.waitForTimeout(1300);
 await page.evaluate(()=>play('adaptive-item',toB64(new Uint8Array(new Int16Array(55200).fill(2000).buffer))));
 assert.equal(await page.evaluate(()=>V.started.has('adaptive-item')&&!V.speechDone.has('adaptive-item')),true);
 await page.evaluate(()=>handle({type:'response.done',response:{id:'adaptive-response',status:'failed',output:[]}}));
 assert.deepEqual(await page.evaluate(()=>({live:V.live.filter(p=>p.item==='adaptive-item').length,held:V.held.filter(p=>p.item==='adaptive-item').length,cut:V.cut.has('adaptive-item')})),{live:0,held:0,cut:true});
 // A fast first clause can speak while the model is still writing; cancellation stops it.
 await page.evaluate(()=>{silence();V.lastRate=0;handle({type:'response.created',response:{id:'early-clause-response'}});handle({type:'response.text.delta',response_id:'early-clause-response',item_id:'early-clause',delta:'这是尚未写完的首句。'});play('early-clause',toB64(new Uint8Array(new Int16Array(2400).fill(2000).buffer)));});
 await page.waitForTimeout(270);
 await page.evaluate(()=>play('early-clause',toB64(new Uint8Array(new Int16Array(9600).fill(2000).buffer))));
 assert.equal(await page.evaluate(()=>V.started.has('early-clause')&&!V.textDone.has('early-clause')),true);
 await page.evaluate(()=>bargeIn(true));
 assert.equal(await page.evaluate(()=>V.live.length+V.held.length),0);
 // Error responses can omit output even after audio deltas arrived.
 const emptyFailure=await page.evaluate(()=>{silence();handle({type:'response.created',response:{id:'no-output-response'}});handle({type:'response.audio.delta',response_id:'no-output-response',item_id:'no-output-audio',delta:toB64(new Uint8Array(new Int16Array(2400).fill(2000).buffer))});handle({type:'localrouter.response.speech_done',response_id:'no-output-response',item_id:'no-output-audio'});handle({type:'response.done',response:{id:'no-output-response',status:'failed',output:[]}});return{held:V.held.some(p=>p.item==='no-output-audio'),cut:V.cut.has('no-output-audio'),started:V.started.has('no-output-audio')};});
 assert.deepEqual(emptyFailure,{held:false,cut:true,started:false});
 // Delayed timing belongs to its response, never the most recent assistant message.
 const timingMatch=await page.evaluate(()=>{const old=botMsg('latency-old','latency-old-response'),latest=botMsg('latency-latest','latency-latest-response');old.text='较早回复';latest.text='较新回复';old.lat.firstAudio=latest.lat.firstAudio=100;lastLat.voice={firstAudio:100,stages:'latest stages',responseId:'latency-latest-response'};handle({type:'localrouter.response.timing',response_id:'latency-old-response',from:'speech_stopped',ms:{stt_start:0,stt_end:10,chat_start:10,first_token:20,tts_start:20,tts_first_pcm:30}});return{old:old.lat?.server?.response_id,latest:latest.lat?.server?.response_id,latestStages:lastLat.voice.stages};});
 assert.deepEqual(timingMatch,{old:'latency-old-response',latest:undefined,latestStages:'latest stages'});
 // Space works without button focus, repeats do not start a second turn, and release commits once.
 await page.evaluate(()=>{silence();V.thinking=false;V.resp=null;__sent.length=0;document.activeElement.blur();});
 await page.keyboard.down('Space');assert.equal(await page.evaluate(()=>V.pttHeld),true);
 const clears=await page.evaluate(()=>__sent.filter(x=>x.type==='input_audio_buffer.clear').length);
 await page.keyboard.down('Space');assert.equal(await page.evaluate(()=>__sent.filter(x=>x.type==='input_audio_buffer.clear').length),clears);
 await page.evaluate(()=>{V.holdStart=performance.now()-500});await page.keyboard.up('Space');await page.waitForTimeout(260);
 assert.equal(await page.evaluate(()=>__sent.filter(x=>x.type==='input_audio_buffer.commit').length),1);
 // A normal space in the composer remains text, with no microphone recording.
 await page.evaluate(()=>{V.thinking=false;V.resp=null;__sent.length=0;});await page.evaluate(()=>showVoice(false));await page.locator('#text').fill('hello');
 await page.locator('#text').press('End');await page.keyboard.press('Space');assert.equal(await page.locator('#text').inputValue(),'hello ');
 assert.equal(await page.evaluate(()=>V.pttHeld),false);assert.equal(await page.evaluate(()=>__sent.length),0);
 // Keyboard and pointer can overlap: releasing one must not end the other hold.
 await page.evaluate(()=>{document.activeElement.blur();});await page.keyboard.down('Space');
 await page.evaluate(()=>holdPtt('pointer'));await page.keyboard.up('Space');assert.equal(await page.evaluate(()=>V.pttHeld),true);
 await page.evaluate(()=>{V.holdStart=performance.now()-500;releasePtt('pointer')});await page.waitForTimeout(260);
 // Losing focus ends the hold, even if the key-up is never delivered.
 await page.evaluate(()=>{V.thinking=false;V.resp=null;__sent.length=0;});await page.keyboard.down('Space');
 await page.evaluate(()=>{V.holdStart=performance.now()-500;window.dispatchEvent(new Event('blur'))});
 assert.equal(await page.evaluate(()=>V.pttHeld),false);await page.keyboard.up('Space');await page.waitForTimeout(260);
 assert.equal(await page.evaluate(()=>__sent.filter(x=>x.type==='input_audio_buffer.commit').length),1);
 // The global shortcut must not steal native Space activation from other controls.
 await page.evaluate(()=>{V.thinking=false;V.resp=null;__sent.length=0;showVoice(true)});await page.locator('.seg [data-mode="vad"]').focus();await page.keyboard.down('Space');assert.equal(await page.evaluate(()=>V.pttHeld),false);await page.keyboard.up('Space');assert.equal(await page.evaluate(()=>S.mode),'vad');await page.evaluate(()=>__sockets.at(-1).event({type:'session.updated',session:{reasoning:S.think}}));
 await page.evaluate(()=>{document.querySelector('.seg [data-mode="ptt"]').click();__sockets.at(-1).event({type:'session.updated',session:{reasoning:S.think}})});
 await page.locator('#vmMin').focus();await page.keyboard.press('Space');assert.equal(await page.evaluate(()=>V.open),false);assert.equal(await page.evaluate(()=>V.pttHeld),false);
 await page.evaluate(()=>showVoice(true));await page.locator('#talk').focus();await page.keyboard.down('Space');assert.equal(await page.evaluate(()=>V.pttHeld),true);await page.evaluate(()=>V.holdStart=performance.now()-100);await page.keyboard.up('Space');await page.waitForTimeout(260);
 // Changing input mode also invalidates a pending PTT commit.
 await page.evaluate(()=>{V.thinking=false;V.resp=null;__sent.length=0;pttDown();V.holdStart=performance.now()-500;pttUp();document.querySelector('.seg [data-mode="vad"]').click();});
 await page.waitForTimeout(260);
 assert.equal(await page.evaluate(()=>__sent.filter(x=>x.type==='input_audio_buffer.commit').length),0);
 assert.equal(await page.evaluate(()=>V.tailUntil),0);
 // A click on the selected input mode must not clear an ongoing spoken turn.
 await page.evaluate(()=>{V.userSpeaking=true;__sent.length=0;document.querySelector('.seg [data-mode="vad"]').click()});
 assert.equal(await page.evaluate(()=>__sent.filter(e=>e.type==='input_audio_buffer.clear').length),0,'reselecting the current mode must preserve recording');
 await page.evaluate(()=>{V.gate={held:[new Int16Array([99])],loud:2,openUntil:999999};document.querySelector('.seg [data-mode="ptt"]').click()});
 assert.equal(await page.evaluate(()=>V.gate.held.length),0);assert.equal(await page.evaluate(()=>V.gate.loud),0);
 assert.equal(await page.evaluate(()=>V.userSpeaking),false,'mode switch must clear the old speaking state');
 const beforeLate=await page.evaluate(()=>cur.msgs.length);
 await page.evaluate(()=>{handle({type:'input_audio_buffer.speech_started',item_id:'old-vad-turn'});handle({type:'input_audio_buffer.speech_stopped',item_id:'old-vad-turn'})});
 assert.equal(await page.evaluate(()=>V.userSpeaking),false);assert.equal(await page.evaluate(()=>cur.msgs.length),beforeLate,'late VAD events must not create a PTT user turn');
 // Recognition language and vocabulary must reach the active session and persist independently of the chat model.
 await page.evaluate(()=>openDrawer());
 await page.locator('#recognitionLanguage').selectOption('zh');
 await page.locator('#transcriptionPrompt').fill('贾维斯，DGX Spark，TensorFold');
 await page.locator('#transcriptionPrompt').blur();
 let recognition=await page.evaluate(()=>__sent.filter(x=>x.type==='session.update').at(-1).session.input_audio_transcription);
 assert.deepEqual(recognition,{language:'zh',prompt:'贾维斯，DGX Spark，TensorFold'});
 assert.equal(await page.evaluate(()=>JSON.parse(localStorage.getItem('jarvis.settings')).recognitionLanguage),'zh');
 await page.locator('#recognitionLanguage').selectOption('');
 await page.locator('#transcriptionPrompt').fill('');await page.locator('#transcriptionPrompt').blur();
 recognition=await page.evaluate(()=>__sent.filter(x=>x.type==='session.update').at(-1).session.input_audio_transcription);
 assert.deepEqual(recognition,{language:'',prompt:''});
 // Changing voice interrupts old queued audio, pins the engine, and requires an exact acknowledgement.
 await page.evaluate(()=>{V.resp='old-voice-response';V.thinking=true;});
 await page.locator('#voices .vrow[data-voice="Nora"]').click();
 const pinned=await page.evaluate(()=>__sent.filter(x=>x.type==='session.update').at(-1).session);
 assert.equal(pinned.speech_model,'speech');assert.equal(pinned.voice,'Nora');
 assert.equal(await page.evaluate(()=>V.cancelledResponses.has('old-voice-response')),true);
 assert.equal(await page.evaluate(()=>S.speechModel),'speech');
 await page.evaluate(()=>{V.pendingUpdates=1;__sockets.at(-1).event({type:'session.updated',session:{reasoning:S.think,speech_model:'speech',voice:'Mae'}})});
 assert.equal(await page.evaluate(()=>V.sessionReady),false);
 await page.evaluate(()=>{sessionUpdate();__sockets.at(-1).event({type:'session.updated',session:{reasoning:S.think,speech_model:'speech',voice:'Nora'}})});
 assert.equal(await page.evaluate(()=>V.sessionReady),true);
 await page.locator('#drawerClose').click();
 await page.locator('#vmEnd').focus();await page.keyboard.press('Space');assert.equal(await page.evaluate(()=>V.ws),null);assert.equal(await page.evaluate(()=>V.pttHeld),false);
 assert.deepEqual(errors,[]);await page.evaluate(()=>voiceStop());
 console.log(JSON.stringify({pass:true,checks:['no text-only fallback during connect','preserve first input','bounded early PCM','cold models readiness','session acknowledgement','PTT/playback separation','reasoning switch reaches session','recognition language and vocabulary reach session','recognition settings persist and reset to automatic','audio resume','reconnect acknowledgement','visible speech errors','buffered and late audio cancellation','preserve text during active reply','rapid PTT re-press','mode change cancels PTT tail','selected mode preserves ongoing recording','mode change resets speaking state and held microphone chunks','late VAD events cannot create PTT turns','slow speech waits for completion','fast speech starts with safe reserve','first clause plays before text completion','early playback cancellation stops audio','failure stops streaming playback','text done and timeout cannot release partial speech','single coalesced audio source','preparation status visible','short reply uses same completion rule','waiting reply cancellation discards PCM','failed reply discards incomplete PCM','final successful response required','empty terminal output still cleans streamed audio','failed/cancelled/incomplete terminal states cannot play','typed turn preserved during playback','send control re-enables when playback ends','global space hold and release','key repeat is idempotent','typing spaces preserved','Space activates other controls without recording','Space on the talk button still records','Space activates end-call without recording','overlapping pointer and keyboard holds','blur releases recording','cancel before first PCM rejects late audio','stale done preserves new response','delayed timing stays with its own response'],httpChats,errors}));
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});
