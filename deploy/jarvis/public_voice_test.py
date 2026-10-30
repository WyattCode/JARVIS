"""Public desktop opt-in voice comparison, injected without changing the stable UI file."""
UI = r'''
<style>
.public-voice-test { display:none; align-items:center; gap:8px; flex:none; }
@media (min-width:761px) and (hover:hover) and (pointer:fine) {
 .public-voice-test { display:inline-flex; }
}
.vm-top .public-voice-test { grid-column:1 / -1; grid-row:2; justify-self:center; justify-content:center; flex-wrap:wrap; margin-top:8px; max-width:100%; }
@media (max-width:1100px) { .top .public-voice-test small, .top [data-voice-test-export] { display:none; } }
.public-voice-test button { min-height:34px; padding:6px 12px; border:1px solid var(--border); border-radius:9px; background:var(--portal-surface); color:var(--text); font:600 12px system-ui; cursor:pointer; white-space:nowrap; }
.public-voice-test button[aria-pressed="true"] { background:#ffe5b3; color:#553300; border-color:#b98a34; }
.public-voice-test button:focus-visible { outline:2px solid #3998c8; outline-offset:2px; }
.public-voice-test small { font:12px system-ui; color:var(--muted); white-space:nowrap; }
.public-voice-test button:disabled { opacity:.5; cursor:wait; }
</style>
<script>
(()=>{
 let selected=false,busy=false,unavailable=false;
 const history=[]; const record=(type,data={})=>{history.push({ms:Math.round(performance.now()),variant:selected?'new':'stable',type,...data});if(history.length>2400)history.splice(0,400)};
 window.jarvisVoiceTestPath='/v1/realtime';
 window.jarvisVoiceTestObserve=sock=>{
   const variant=selected?'new':'stable';
   sock.addEventListener('open',()=>record('socket.open',{socketVariant:variant}));
   sock.addEventListener('close',e=>record('socket.close',{socketVariant:variant,code:e.code}));
   sock.addEventListener('message',e=>{try{const m=JSON.parse(e.data);if(m.type==='response.audio.delta')record('audio.arrival',{socketVariant:variant,bytes:Math.floor(m.delta.length*3/4)});else if(['response.created','response.done'].includes(m.type))record(m.type,{socketVariant:variant});}catch{}});
 };
 function render(){
   document.querySelectorAll('[data-voice-test-toggle]').forEach(b=>{b.textContent=selected?'切回稳定语音':'新版语音测试';b.setAttribute('aria-pressed',String(selected));b.disabled=busy||(!selected&&unavailable)});
   document.querySelectorAll('[data-voice-test-status]').forEach(s=>s.textContent=selected?'当前：新版测试':unavailable?'测试已关闭':'当前：稳定版');
 }
 function stable(message){
   voiceStop(); selected=false;window.jarvisVoiceTestPath='/v1/realtime';record('switch.stable');render();if(message)toast(message);
 }
 async function toggle(){
   if(busy)return;
   if(selected){stable('已切回稳定版，点击麦克风继续对话');return;}
   busy=true;render();
   try{
     const r=await fetch('/v1/voice-test',{cache:'no-store'});
     if(!r.ok)throw Error('测试服务不可用');
     const s=await r.json();if(!s.enabled||!s.ready)throw Error('新版语音暂未就绪，继续使用稳定版');
     if(V.conv&&V.conv!==cur)openConv(V.conv.id);
     voiceStop(); selected=true;window.jarvisVoiceTestPath='/v1/realtime?voice_variant=new';record('switch.new');render();
     voiceStart();showVoice(true);toast('已进入新版语音测试；可随时切回稳定版');
   }catch(e){toast(e.message,true);}finally{busy=false;render();}
 }
 function download(){
   const c=V.ctx;
   const report={at:new Date().toISOString(),entry:location.origin,variant:selected?'new':'stable',userAgent:navigator.userAgent,mode:S.mode,voices:S.voices,context:c?{rate:c.sampleRate,state:c.state,baseLatency:c.baseLatency,outputLatency:c.outputLatency}:null,gaps:window.jarvis?.voice.gaps,events:history.slice()};
   const u=URL.createObjectURL(new Blob([JSON.stringify(report,null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=u;a.download='jarvis-public-voice-test.json';a.click();setTimeout(()=>URL.revokeObjectURL(u),1000);
 }
 for(const parent of [document.querySelector('.top'),document.querySelector('.vm-top')]){
   if(!parent)continue;
   const wrap=document.createElement('div');wrap.className='public-voice-test';wrap.innerHTML='<small data-voice-test-status role="status"></small><button type="button" data-voice-test-toggle aria-pressed="false" title="切换会结束当前播报；刷新页面恢复稳定版">新版语音测试</button><button type="button" data-voice-test-export title="只导出时序和状态，不包含录音或对话正文">导出测试记录</button>';
   wrap.querySelector('[data-voice-test-toggle]').onclick=toggle;wrap.querySelector('[data-voice-test-export]').onclick=download;
   parent.insertBefore(wrap,parent.querySelector('#gear,#vmEnd'));
 }
 render();
 const poll=setInterval(async()=>{try{const r=await fetch('/v1/voice-test',{cache:'no-store'});if(!r.ok)return;const s=await r.json();unavailable=!s.enabled;if(selected&&!s.enabled)stable('新版测试已撤销，已恢复稳定版；点击麦克风继续');render();}catch{}},5000);
 window.addEventListener('pagehide',()=>clearInterval(poll),{once:true});
})();
</script>
'''

def inject(body):
    endpoint = b"const url = new URL('/v1/realtime', location.href);"
    socket = b"const sock = new WebSocket(url.href, ['realtime']);"
    if body.count(endpoint) != 1 or body.count(socket) != 1 or body.count(b'</body>') != 1:
        # An incompatible UI must remain stable rather than partially injected.
        return body
    return body.replace(endpoint, b"const url = new URL(window.jarvisVoiceTestPath || '/v1/realtime', location.href);", 1).replace(socket, socket + b'\n  window.jarvisVoiceTestObserve?.(sock);', 1).replace(b'</body>', UI.encode() + b'</body>', 1)
