/* Shared by login and voice.html (inlined there to support the existing LAN listener). */
(()=>{
'use strict';
const key='jarvis.appearance', root=document.documentElement, system=matchMedia('(prefers-color-scheme: dark)');
const valid=value=>['light','dark','system'].includes(value)?value:'dark';
let choice='dark';try{choice=valid(localStorage.getItem(key))}catch{}
const icons={light:'<circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5"/>',dark:'<path d="M20.7 13.1A9 9 0 0 1 10.9 3.3a9 9 0 1 0 9.8 9.8Z"/>',system:'<rect x="3" y="4" width="18" height="13" rx="2"/><path d="M8 21h8m-4-4v4"/>'};
const names={light:'白天',dark:'黑夜',system:'跟随系统'};
function apply(){
 const mode=choice==='system'?(system.matches?'dark':'light'):choice;
 root.dataset.theme=mode;root.dataset.themeChoice=choice;
 document.querySelectorAll('meta[name="theme-color"]').forEach(meta=>{meta.content=mode==='dark'?'#09090b':'#f5f5f6';meta.removeAttribute('media')});
 document.querySelectorAll('[data-theme-choice-button]').forEach(button=>{const on=button.dataset.themeChoiceButton===choice;button.setAttribute('aria-checked',String(on));button.tabIndex=on?0:-1});
}
function choose(value){choice=valid(value);try{localStorage.setItem(key,choice)}catch{}apply()}
const mounted=new WeakSet();
function mount(){document.querySelectorAll('[data-theme-control]').forEach(group=>{
 if(mounted.has(group))return;
 let buttons=[...group.querySelectorAll('[data-theme-choice-button]')];
 if(group.hasAttribute('data-theme-prerender')&&buttons.length!==3)return;
 group.classList.add('theme-switch');group.setAttribute('role','radiogroup');group.setAttribute('aria-label','外观');
 if(!buttons.length)for(const mode of ['light','dark','system']){const button=document.createElement('button');button.type='button';button.dataset.themeChoiceButton=mode;button.setAttribute('role','radio');button.setAttribute('aria-label',names[mode]);button.title=names[mode];button.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true">'+icons[mode]+'</svg>';group.append(button);buttons.push(button)}
 for(const button of buttons)button.addEventListener('click',()=>choose(button.dataset.themeChoiceButton));
 mounted.add(group);
 group.addEventListener('keydown',event=>{let index=buttons.indexOf(document.activeElement);if(index<0)return;if(['ArrowRight','ArrowDown'].includes(event.key))index=(index+1)%3;else if(['ArrowLeft','ArrowUp'].includes(event.key))index=(index+2)%3;else if(event.key==='Home')index=0;else if(event.key==='End')index=2;else return;event.preventDefault();choose(buttons[index].dataset.themeChoiceButton);buttons[index].focus()});
 });apply()}
apply();
if(document.readyState==='loading'){
 // Hydrate parsed controls before first paint, without waiting for unrelated deferred scripts.
 const parsing=new MutationObserver(mount);parsing.observe(root,{childList:true,subtree:true});
 document.addEventListener('DOMContentLoaded',()=>{parsing.disconnect();mount()},{once:true});
 mount();
}else mount();
system.addEventListener('change',()=>{if(choice==='system')apply()});
window.addEventListener('storage',event=>{if(event.key===key||event.key===null){choice=valid(event.newValue);apply()}});
})();
