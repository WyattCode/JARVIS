const {test} = require('node:test');
const assert = require('node:assert/strict');
const {assess} = require('../tools/spark/jarvis/public_voice_regression.cjs');
function good() {return {turns:{long:{status:'completed',audioPackets:500,audioMs:20000,playbackMs:1000,textDoneMs:2000,items:['long1'],recordingKeys:['1:long1'],gaps:{}},interrupt:{status:'cancelled'},recovery:{status:'completed',audioPackets:30,playbackMs:900}},output:[{reply:'1:long1',window_ms:20000,gaps_over:0,render_gaps:0}],interruptedAudioCleared:true,errors:[]};}
const passed = r => assess(r).every(c=>c.ok);
test('complete streaming playback evidence passes',()=>assert.ok(passed(good())));
test('missing evidence fails closed',()=>assert.ok(!passed({turns:{},errors:[]})));
test('late playback fails latency check',()=>{const r=good();r.turns.long.playbackMs=3500;assert.ok(!passed(r));});
test('waiting for all text fails streaming check',()=>{const r=good();r.turns.long.playbackMs=2100;assert.ok(!passed(r));});
test('short reply cannot masquerade as long test',()=>{const r=good();r.turns.long.audioMs=14000;assert.ok(!passed(r));});
test('delivery and render gaps both fail',()=>{for(const key of ['gaps_over','render_gaps']){const r=good();r.output[0][key]=1;assert.ok(!passed(r));}});
test('underrun fails even if recorder misses it',()=>{const r=good();r.turns.long.gaps={long1:1};assert.ok(!passed(r));});
test('output from another turn cannot substitute for long playback',()=>{const r=good();r.output[0].reply='warmup';assert.ok(!passed(r));});
test('interruption must cancel and clear audio',()=>{for(const key of ['cancel','clear']){const r=good();if(key==='cancel')r.turns.interrupt.status='completed';else r.interruptedAudioCleared=false;assert.ok(!passed(r));}});
test('recovery must produce audio',()=>{const r=good();r.turns.recovery.audioPackets=0;assert.ok(!passed(r));});
test('same item from another connection is rejected',()=>{const r=good();r.output[0].reply='2:long1';assert.ok(!passed(r));});

test('partial output coverage fails',()=>{const r=good();r.output[0].window_ms=2000;assert.ok(!passed(r));});

const vm=require('node:vm');
const {verifyRecordedSamples}=require('../tools/spark/jarvis/public_voice_regression.cjs');
function verify(output,source) {
 return vm.runInNewContext('('+verifyRecordedSamples.toString()+')(["1:long1"])',{
  RATE:24000,recordedOutput:()=>Float32Array.from(output),
  V:{rec:{rate:24000,t0:0,pieces:[{key:'1:long1',start:0,data:Float32Array.from(source)}]}}
 });
}
test('natural digital silence is preserved, not a playback hole',()=>{
 const source=new Float32Array(480000).fill(.1);source.fill(0,10000,20000);const v=verify(source,source)['1:long1'];assert.equal(v.maxDiff,0);assert.equal(v.unchecked,0);
 const r=good();r.turns.long.audioMs=20000;r.output[0].render_gaps=1;r.outputVerification={'1:long1':v};assert.ok(passed(r));
});
test('inserted silence, missing samples, and foreign output cannot clear a gap',()=>{
 assert.ok(verify([.2,0,0],[.2,.3,0])['1:long1'].maxDiff>.1);
 assert.ok(verify([.2],[.2,.3,0])['1:long1'].unchecked>0);
 for(const proof of [{samples:480000,unchecked:0,maxDiff:.1,rate:24000},{samples:480000,unchecked:1,maxDiff:0,rate:24000},{samples:240000,unchecked:0,maxDiff:0,rate:24000}]){
  const r=good();r.output[0].gaps_over=1;r.outputVerification={'1:long1':proof};assert.ok(!passed(r));
 }
});
