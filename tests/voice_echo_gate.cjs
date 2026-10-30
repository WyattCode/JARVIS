// Exercise the actual microphone gate with quiet speech and active reply playback.
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const html=fs.readFileSync(path.join(__dirname,'../src/voice/voice.html'),'utf8');
const source=html.slice(html.indexOf('function micChunk(pcm) {'),html.indexOf('function coreVoiceModelsReady()'));
function capture({aec,gate=true,mode='vad',amplitude=600}){
 const sent=[],context={Int16Array,performance:{now:()=>1000},cur:'current',previewAudio:null,
 S:{mode,gate},V:{conv:'current',browserEchoCancelled:aec,live:[{}],playRms:.08,gate:{held:[],loud:0,openUntil:0},pttHeld:true,tailUntil:0},
 rms16:pcm=>Math.sqrt(pcm.reduce((s,x)=>s+x*x,0)/pcm.length)/32768,sendPcm:pcm=>sent.push([...pcm]),dbg:()=>{}};
 vm.createContext(context);vm.runInContext(source,context);
 for(let i=0;i<4;i++)context.micChunk(new Int16Array(960).fill(amplitude));
 return sent;
}
assert(capture({aec:true}).every(p=>p.every(x=>x===600)),'Native AEC must preserve quiet speech during reply playback');
assert(capture({aec:false}).every(p=>p.every(x=>x===0)),'Without native AEC, configured echo guard remains active');
assert(capture({aec:false,gate:false}).every(p=>p.every(x=>x===600)),'Disabling the guard preserves input');
assert(capture({aec:false,mode:'ptt'}).every(p=>p.every(x=>x===600)),'Held push-to-talk preserves quiet speech');
assert(capture({aec:false,amplitude:8000}).some(p=>p.some(x=>x===8000)),'Loud interruptions open the fallback gate');
console.log(JSON.stringify({pass:true,checks:5}));
