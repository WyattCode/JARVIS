// Exercise the actual playback scheduler against delayed long-reply audio.
const vm=require('vm'),fs=require('fs'),path=require('path'),assert=require('assert');
const html=fs.readFileSync(process.env.VOICE_HTML||path.join(__dirname,'../src/voice/voice.html'),'utf8');
const code=html.slice(html.indexOf('const START_MS ='),html.indexOf('// For tests: the page\'s own output'));
let wall=1000,clock=0,timer=0;const timers=new Map(),starts=[];
const ctx={state:'running',sampleRate:24000,get currentTime(){return clock;},destination:{},createBuffer(c,n,r){const data=new Float32Array(n);return{duration:n/r,length:n,getChannelData(){return data;}}},createBufferSource(){return{connect(){},stop(){},start(at){starts.push({at,buffer:this.buffer,duration:this.buffer.duration});}}}};
const V={ctx,cut:new Set(),started:new Set(),held:[],firstAt:new Map(),got:new Map(),bufferTargets:new Map(),rebufferFrom:new Map(),speechDone:new Set(),replyDone:new Set(),textDone:new Set(),chars:new Map(),gaps:new Map(),doneMs:new Map(),byItem:new Map(),live:[],freeRate:new Map(),lastRate:0,nextTime:0,lead:.1};
const sandbox={V,S:{},cur:{msgs:[]},RATE:24000,LOUD:250/32768,performance:{now:()=>wall},fromB64:s=>new Uint8Array(Buffer.from(s,'base64')),dbg(){},renderVoice(){},renderStatus(){},draw(){},setTimeout(f){timers.set(++timer,f);return timer;},clearTimeout(id){timers.delete(id);}};
vm.createContext(sandbox);vm.runInContext(code,sandbox);
const pcm=(ms,value=2000)=>Buffer.from(new Int16Array(ms*24).fill(value).buffer).toString('base64');
sandbox.play('long',pcm(300,1000));assert.equal(starts.length,0,'must not speak the first sentence early');
sandbox.textDone('long',500);wall+=30000;clock+=30;sandbox.startOrWait('long');assert.equal(starts.length,0,'text completion and timeout must not release partial audio');
sandbox.play('long',pcm(1200,2000));wall+=30000;clock+=30;sandbox.startOrWait('long');assert.equal(starts.length,0,'even a large reserve must await speech completion');
V.speechDone.add('long');sandbox.startOrWait('long');assert.equal(starts.length,0,'speech completion must wait for final successful response');V.replyDone.add('long');sandbox.startOrWait('long');assert.equal(starts.length,1);assert.equal(starts[0].buffer.length,36000);assert.equal(starts[0].buffer.getChannelData(0)[0],1000/32768);assert.equal(starts[0].buffer.getChannelData(0)[7200],2000/32768);assert.equal(V.held.length,0);assert.equal(V.gaps.size,0);
ctx.state='interrupted';sandbox.play('blocked',pcm(40));V.speechDone.add('blocked');V.replyDone.add('blocked');sandbox.startOrWait('blocked');assert.equal(starts.length,1);ctx.state='running';sandbox.startOrWait('blocked');assert.equal(starts.length,2);
sandbox.play('cancelled',pcm(100));V.cut.add('cancelled');V.speechDone.add('cancelled');sandbox.startOrWait('cancelled');assert.equal(starts.length,2);
console.log(JSON.stringify({pass:true,checks:['no early first sentence','text completion is not speech completion','no timeout escape during slow generation','large buffer cannot release incomplete reply','one coalesced audio source','sample count and order preserved','no scheduling gaps','suspended context resumes completed audio','cancelled reply cannot play','speech completion alone cannot start a failed response']}));
// Fast ongoing synthesis may start with a measured reserve; no timeout alone can do this.
V.nextTime=clock;V.byItem.set('fast',{text:'我们正在测试连续播放。'.repeat(8)});
sandbox.play('fast',pcm(100));wall+=1300;clock+=1.3;
sandbox.play('fast',pcm(2200));assert.equal(V.started.has('fast'),true,'fast stream starts while text is growing');
sandbox.textDone('fast',300);assert.equal(V.started.has('fast'),true,'fast measured stream starts before completion');
assert.equal(V.speechDone.has('fast'),false);assert.equal(starts.at(-1).buffer.length,55200,'startup PCM coalesced without loss');
const scheduled=V.nextTime;sandbox.play('fast',pcm(100));assert.equal(starts.at(-1).at,scheduled,'later PCM scheduled contiguously');
// Once an unexpectedly stalled stream underruns, do not repeatedly restart short sentences.
clock=V.nextTime+1;wall+=5000;sandbox.play('fast',pcm(2000));assert.equal(V.started.has('fast'),false);
wall+=1400;sandbox.play('fast',pcm(4000));assert.equal(V.started.has('fast'),false,'underrun stays buffered despite large new burst');
V.speechDone.add('fast');V.replyDone.add('fast');sandbox.startOrWait('fast');assert.equal(V.started.has('fast'),true);
// A slow stream with known text is never released by a wall-clock timeout.
V.byItem.set('slow',{text:'慢速生成的长回复。'.repeat(20)});sandbox.play('slow',pcm(100));sandbox.textDone('slow',500);
wall+=3000;clock+=3;sandbox.play('slow',pcm(1600));assert.equal(V.started.has('slow'),false);
console.log(JSON.stringify({adaptivePass:true,checks:['fast measured stream starts before completion','fast stream starts before text completion','coalesced startup preserves PCM','later PCM has contiguous schedule','underrun cannot cause repeated sentence restarts','slow stream waits for completion']}));

// Upstream starts at 250ms of observation, without the old 1.2s / 1.8s gates.
V.nextTime=clock;sandbox.play('quick',pcm(100));wall+=250;clock+=.25;sandbox.play('quick',pcm(300));
assert.equal(V.started.has('quick'),true);assert.equal(V.textDone.has('quick'),false);
// An estimate may start an already-written reply promptly, but not override measured slow delivery.
V.lastRate=2;V.nextTime=clock;sandbox.play('prior',pcm(250));sandbox.textDone('prior',100);
assert.equal(V.started.has('prior'),true);
sandbox.play('stale-prior',pcm(40));wall+=1000;clock+=1;sandbox.play('stale-prior',pcm(100));sandbox.textDone('stale-prior',500);
assert.equal(V.started.has('stale-prior'),false,'stale prior cannot overrule slow current rate');
// Missing packets must not stop the 25ms reevaluation, and a stalled stream never escapes on a timeout.
wall+=20000;clock+=20;sandbox.startOrWait('stale-prior');assert.equal(V.started.has('stale-prior'),false);
assert.ok(timers.size>0);
console.log(JSON.stringify({upstreamPass:true,checks:['250ms observation permits first-clause playback','text completion not required for fast stream','server/prior throughput starts written reply promptly','slow current throughput overrides stale fast estimate','stalled stream has no forced timeout escape','25ms reevaluation active']}));
// A process-global server estimate can belong to a different voice or client.
V.lastRate=0;V.freeRate.set('new-voice',4);V.nextTime=clock;
sandbox.play('new-voice',pcm(250));sandbox.textDone('new-voice',1000);
assert.equal(V.started.has('new-voice'),false,'unscoped server estimate must not bypass first measurement after voice change');
wall+=250;clock+=.25;sandbox.play('new-voice',pcm(300));assert.equal(V.started.has('new-voice'),true,'new voice can start on its own measured throughput');
console.log(JSON.stringify({reviewPass:true,checks:['foreign server speed cannot bypass new voice measurement','new voice still starts after 250ms measured fast delivery']}));
