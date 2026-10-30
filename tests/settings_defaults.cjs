// The requested default must migrate existing browsers once, then respect the user's later opt-out.
const vm=require('vm'),fs=require('fs'),path=require('path'),assert=require('assert');
const html=fs.readFileSync(path.join(__dirname,'../src/voice/voice.html'),'utf8');
const start=html.indexOf('const S = Object.assign('),end=html.indexOf('if (S.voice &&',start),code=html.slice(start,end);
function load(saved){const writes=[];const c=vm.createContext({store:{get:()=>saved||{},set:(key,value)=>writes.push({key,value:{...value}})}});vm.runInContext(code,c);return{settings:vm.runInContext('S',c),writes};}
let a=load();assert.equal(a.settings.mode,'ptt');assert.equal(a.settings.voiceModeDefaultRevision,1);assert.equal(a.settings.think,true);assert.equal(a.settings.reasoningDefaultRevision,1);
let b=load({think:false});assert.equal(b.settings.think,true);assert.equal(b.writes.length,1);
let c=load({think:false,reasoningDefaultRevision:1,voiceModeDefaultRevision:1,atlasVoiceDefaultRevision:1,mode:'vad'});assert.equal(c.settings.think,false);assert.equal(c.writes.length,0);
let d=load({think:true,reasoningDefaultRevision:1,voiceModeDefaultRevision:1,atlasVoiceDefaultRevision:1,mode:'vad'});assert.equal(d.settings.think,true);assert.equal(d.writes.length,0);
assert.equal(a.settings.voices['fishaudio/drama-3'],'zh-xingheng');
const migratedVoice=load({voices:{'fishaudio/drama-3':'Mae',other:'custom'}});assert.equal(migratedVoice.settings.voices['fishaudio/drama-3'],'zh-xingheng');assert.equal(migratedVoice.settings.voices.other,'custom');
const retainedVoice=load({voices:{'fishaudio/drama-3':'Arlo'},reasoningDefaultRevision:1,voiceModeDefaultRevision:1,atlasVoiceDefaultRevision:1});assert.equal(retainedVoice.settings.voices['fishaudio/drama-3'],'Arlo');
let oldMode=load({mode:'vad',reasoningDefaultRevision:1});assert.equal(oldMode.settings.mode,'ptt');assert.equal(oldMode.writes.length,1);assert.equal(c.settings.mode,'vad');
const boot=html.slice(html.indexOf('const debug = [];'),html.indexOf("window.addEventListener('error'"));
const nodes=new Map();const cboot=vm.createContext({localStorage:{getItem(){return null;},setItem(){throw new Error('quota');}},performance:{now:()=>0},$:id=>{if(!nodes.has(id))nodes.set(id,{});return nodes.get(id);}});
vm.runInContext(boot,cboot);assert.equal(vm.runInContext('S.think',cboot),true);assert(vm.runInContext("storageFailures.has('settings')",cboot));assert.equal(vm.runInContext('debug.length',cboot),1);
console.log(JSON.stringify({pass:true,checks:['Atlas is the default voice','existing voice choices migrate to Atlas once','later manual voice selection persists','new profiles default to push-to-talk','old voice mode migrates once','later hands-free choice persists','new profiles enable reasoning','existing profiles migrate once','later explicit opt-out persists','enabled state persists','quota failure during first-load migration preserves boot']}));
