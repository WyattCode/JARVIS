/* Shared install behavior for login and chat. No chat, credentials or API cache. */
(()=>{
'use strict';
const root=document.documentElement;
const display=matchMedia('(display-mode: standalone)');
let promptEvent=null,installed=false,installPending=false;
const isIOS=()=>/iPad|iPhone|iPod/.test(navigator.userAgent)||(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1);
const standalone=()=>installed||display.matches||navigator.standalone===true;
function sync(){root.classList.toggle('is-standalone',standalone());document.querySelectorAll('[data-install-app]').forEach(button=>{button.hidden=standalone();button.disabled=installPending;button.setAttribute('aria-busy',String(installPending))});}
function instructions(){
 let dialog=document.getElementById('pwaInstallHelp');
 if(!dialog){
  dialog=document.createElement('dialog');dialog.id='pwaInstallHelp';dialog.className='pwa-install-help';dialog.setAttribute('aria-labelledby','pwaInstallTitle');
  const title=document.createElement('h2');title.id='pwaInstallTitle';title.textContent='添加到主屏幕';
  const text=document.createElement('p');text.id='pwaInstallInstructions';
  const close=document.createElement('button');close.type='button';close.className='btn pwa-help-close';close.textContent='知道了';close.onclick=()=>dialog.close();
  dialog.append(title,text,close);document.body.append(dialog);
  dialog.addEventListener('click',e=>{if(e.target===dialog){const b=dialog.getBoundingClientRect();if(e.clientX<b.left||e.clientX>b.right||e.clientY<b.top||e.clientY>b.bottom)dialog.close();}});
  dialog.addEventListener('keydown',e=>{if(e.key==='Escape')e.stopPropagation();});
 }
 const chromeIOS=/CriOS/.test(navigator.userAgent);
 dialog.querySelector('p').textContent=isIOS()
  ? (chromeIOS?'点击 Chrome 的分享按钮，选择“添加到主屏幕”。':'点击 Safari 的分享按钮，选择“添加到主屏幕”。')+' 如果出现“作为网页 App 打开”，请保持开启。添加后从桌面 Jarvis 图标进入。'
  : '打开浏览器菜单，选择“安装应用”或“添加到主屏幕”，确认安装 Jarvis。添加后从桌面图标进入。';
 if(!dialog.open)dialog.showModal();
}
async function install(){
 if(standalone()||installPending)return;
 const event=promptEvent;
 if(!event){instructions();return;}
 promptEvent=null;installPending=true;sync();
 try{await event.prompt();const choice=await event.userChoice;if(choice?.outcome==='accepted'){installed=true;sync();}}
 catch{instructions();}
 finally{installPending=false;sync();}
}
window.addEventListener('beforeinstallprompt',event=>{if(document.querySelector('[data-install-app]'))event.preventDefault();promptEvent=event;sync();});
window.addEventListener('appinstalled',()=>{installed=true;promptEvent=null;sync();});
display.addEventListener('change',sync);
function init(){document.querySelectorAll('[data-install-app]').forEach(button=>button.addEventListener('click',install));sync();}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init,{once:true});else init();
function register(){if(location.protocol==='https:'&&'serviceWorker' in navigator)navigator.serviceWorker.register('/service-worker.js',{scope:'/',updateViaCache:'none'}).catch(()=>{});}
if(document.readyState==='complete')register();else window.addEventListener('load',register,{once:true});
})();
