const fs=require('fs'),vm=require('vm'),assert=require('assert/strict');
const html=fs.readFileSync(require('path').join(__dirname,'../src/voice/voice.html'),'utf8');
const start=html.indexOf('function applyServerVoiceDefaults()'),end=html.indexOf('// Discovery can be incomplete',start);assert.ok(start>0&&end>start);
const s={voices:{tts:'old'},voiceDefaultRevisions:{}},v={ws:null};let writes=0;
const sandbox={S:s,V:v,models:[],store:{set(){writes++}}};vm.createContext(sandbox);vm.runInContext(html.slice(start,end),sandbox);
function server(revision,def='a',voices=['a','b']){sandbox.models=[{id:'tts',kind:'speech',default_voice:def,voice_default_revision:revision,voices}];sandbox.applyServerVoiceDefaults()}
server(7);assert.equal(s.voices.tts,'a');assert.equal(s.voiceDefaultRevisions.tts,7);assert.equal(writes,1);
s.voices.tts='b';server(7);assert.equal(s.voices.tts,'b');assert.equal(writes,1);
v.ws={};server(8);assert.equal(s.voices.tts,'b');assert.equal(s.voiceDefaultRevisions.tts,7);v.ws=null;server(8);assert.equal(s.voices.tts,'a');assert.equal(s.voiceDefaultRevisions.tts,8);
s.voices.tts='b';server(7);assert.equal(s.voices.tts,'b');server(9,'missing');assert.equal(s.voices.tts,'b');assert.equal(s.voiceDefaultRevisions.tts,8);
s.voiceDefaultRevisions='bad';server(10);assert.equal(s.voiceDefaultRevisions.tts,10);assert.equal(s.voices.tts,'a');
s.voices.tts='b';server(undefined);assert.equal(s.voices.tts,'b');s.voices={};server(undefined);assert.equal(s.voices.tts,'a');
s.voices.tts='removed';server(10,'a',['a','b']);assert.equal(s.voices.tts,'a');
console.log(JSON.stringify({passed:true,checks:['server default on revision','same revision preserves manual choice','new revision applied once','rollback revision not replayed','active call deferred','unavailable default retained','invalid stored revision recovered','legacy server fills only empty choice']}));
