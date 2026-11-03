const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,args:['--autoplay-policy=no-user-gesture-required']});
 const report={sandbox_only:true,errors:[]};
 try {
  const page=await browser.newPage();page.on('pageerror',e=>report.errors.push(e.message));
  await page.route('**/*',route=>{
   const pathname=new URL(route.request().url()).pathname;
   if(pathname==='/voice')return route.fulfill({contentType:'text/html',body:fs.readFileSync(path.join(__dirname,'../src/voice/voice.html'),'utf8')});
   return route.fulfill({json:pathname==='/v1/models'?{data:[{id:'chat',kind:'chat'},{id:'speech',kind:'speech',voices:['Mae'],default_voice:'Mae'}]}:pathname==='/v1/tools'?{data:[{id:'chat',state:'ready'},{id:'speech',state:'ready'}]}:{enabled:false}});
  });
  await page.goto('http://jarvis.test/voice');await page.waitForFunction(()=>jarvis.ready);
  await page.evaluate(async()=>{
   V.ctx=new AudioContext({sampleRate:24000});V.out=V.ctx.createGain();V.out.connect(V.ctx.destination);await V.ctx.resume();
   window.testTone=ms=>toB64(new Uint8Array(new Int16Array(24*ms).fill(2000).buffer));
   handle({type:'response.created',response:{id:'held-response'}});
   handle({type:'response.text.delta',response_id:'held-response',item_id:'held-item',delta:'测试中的完整文字仍然保留。'});
   play('held-item',testTone(100));play('held-item',testTone(400));
   window.beforeFailure={held:V.held.length,started:V.started.has('held-item')};
   handle({type:'error',error:{code:'speech_failed',message:'故障注入：后续音色偏离'}});
  });
  await page.waitForTimeout(310);
  report.held_failure=await page.evaluate(()=>({before:beforeFailure,started_after_error:V.started.has('held-item'),live_after_error:V.live.filter(x=>x.item==='held-item').length,cut_after_error:V.cut.has('held-item'),error_shown:!!V.speechError}));
  report.active_failure=await page.evaluate(()=>{
   silence();handle({type:'response.created',response:{id:'active-response'}});
   handle({type:'response.text.delta',response_id:'active-response',item_id:'active-item',delta:'测试中的完整文字仍然保留。'});
   play('active-item',testTone(100));V.firstAt.set('active-item',performance.now()-300);play('active-item',testTone(2000));
   const live_before_error=V.live.length;
   handle({type:'error',error:{code:'speech_failed',message:'故障注入：后续音色偏离'}});
   const live_after_error=V.live.length,cut_after_error=V.cut.has('active-item');
   handle({type:'response.text.delta',response_id:'active-response',item_id:'active-item',delta:'失败后的剩余文字。'});
   handle({type:'response.audio.delta',response_id:'active-response',item_id:'active-item',delta:testTone(300)});
   const late_pcm_live=V.live.length,text_preserved=V.byItem.get('active-item').text.endsWith('失败后的剩余文字。');
   handle({type:'response.done',response:{id:'active-response',status:'failed',output:[]}});
   return{live_before_error,live_after_error,cut_after_error,live_after_done:V.live.length,late_pcm_live,text_preserved};
  });
  report.stale_error=await page.evaluate(()=>{
   silence();handle({type:'response.created',response:{id:'new-response'}});
   handle({type:'response.text.delta',response_id:'new-response',item_id:'new-item',delta:'新回复正常。'});
   play('new-item',testTone(100));V.firstAt.set('new-item',performance.now()-300);play('new-item',testTone(2000));
   handle({type:'error',response_id:'old-response',error:{code:'speech_failed',message:'旧回复错误'}});
   return{live:V.live.length,cut:V.cut.has('new-item'),error:V.speechError};
  });
  report.failed_terminal=await page.evaluate(()=>{
   silence();handle({type:'response.created',response:{id:'terminal-response'}});
   handle({type:'response.text.delta',response_id:'terminal-response',item_id:'terminal-item',delta:'待播文字。'});
   play('terminal-item',testTone(100));
   handle({type:'error',error:{code:'speech_failed',message:'错误'}});
   handle({type:'localrouter.response.speech_done',response_id:'terminal-response',item_id:'terminal-item'});
   handle({type:'response.done',response:{id:'terminal-response',status:'completed',output:[]}});
   return{live:V.live.length,held:V.held.length,cut:V.cut.has('terminal-item')};
  });
  await page.evaluate(()=>{silence();V.ctx.close();});
 } finally {await browser.close();}
 assert.equal(report.held_failure.started_after_error,false);
 assert.equal(report.active_failure.live_after_error,0);
 assert.equal(report.active_failure.late_pcm_live,0);
 assert.equal(report.active_failure.text_preserved,true);
 assert.deepEqual(report.stale_error,{live:1,cut:false,error:''});
 assert.deepEqual(report.failed_terminal,{live:0,held:0,cut:true});
 assert.deepEqual(report.errors,[]);
 console.log(JSON.stringify({passed:true,checks:6,report},null,2));
})().catch(e=>{console.error(e.message);process.exitCode=1});
