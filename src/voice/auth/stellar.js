/* Procedural living core. No network, model requests or external animation dependencies. */
(()=>{
'use strict';
if(window.JarvisStellar)return;
const entries=new Map(),reduced=matchMedia('(prefers-reduced-motion: reduce)');
let frame=0,last=0,clock=0,previous=0;
function release(host,e){e.watch.disconnect();intersection.unobserve(host);resize.unobserve(host);entries.delete(host)}
const TAU=Math.PI*2;
const random=()=>{try{const v=new Uint32Array(1);crypto.getRandomValues(v);return v[0]/4294967296}catch{return Math.random()}};
function wake(){if(!frame&&!document.hidden&&!reduced.matches&&[...entries.values()].some(e=>e.visible&&e.host.dataset.resting!=='true'))frame=requestAnimationFrame(tick)}
const intersection=new IntersectionObserver(records=>{for(const record of records){const e=entries.get(record.target);if(e){e.visible=record.isIntersecting; if(e.visible)paint(e,clock)}}wake()});
const resize=new ResizeObserver(records=>{for(const record of records){const e=entries.get(record.target);if(!e)continue;if(!record.target.isConnected){release(record.target,e);continue}const width=record.contentRect.width;if(!width)continue;const size=Math.max(32,Math.min(600,Math.ceil(width*1.34*Math.min(devicePixelRatio||1,1.5))));if(e.canvas.width!==size){e.canvas.width=e.canvas.height=size;e.small=width<65}paint(e,clock)}wake()});
function attach(host){
 if(!host||entries.has(host))return;
 const canvas=document.createElement('canvas');canvas.className='stellar-canvas';canvas.setAttribute('aria-hidden','true');
 const ctx=canvas.getContext('2d',{alpha:true});if(!ctx)return;
 // Prepare the final-sized first frame before replacing the fallback image.
 const width=host.getBoundingClientRect().width;
 const size=Math.max(32,Math.min(600,Math.ceil((width||128)*1.34*Math.min(devicePixelRatio||1,1.5))));
 canvas.width=canvas.height=size;
 const e={host,canvas,ctx,visible:false,small:width<65,offset:random()*1200,tempo:.88+random()*.24};paint(e,clock);
 entries.set(host,e);host.append(canvas);host.dataset.stellar='live';intersection.observe(host);resize.observe(host);
 const watch=new MutationObserver(()=>{if(host.dataset.resting!=='true')wake()});watch.observe(host,{attributes:true,attributeFilter:['data-resting','data-mood']});e.watch=watch;
}
// Same B1 paired-winding construction and radii as Android ReactorPainter.
function paint(e,time){
 const {ctx:c,canvas,host}=e,size=canvas.width;if(!size)return;
 const t=reduced.matches?0:(e.offset+time*e.tempo)*Math.PI/13;
 const mood=host.dataset.mood||'idle',level=Math.max(0,Math.min(1,parseFloat(host.style.getPropertyValue('--lvl'))||0));
 const energy=mood==='speaking'?.65+level*.35:['thinking','responding'].includes(mood)?.72:['hearing','talking'].includes(mood)?.48:.18;
 const pulse=.5+.5*Math.sin(t*12+e.offset),dark=document.documentElement.dataset.theme==='dark';
 const white=dark?'#e6f8ff':'#326579',cyan=dark?'#8fdceb':'#147f9f',faint=dark?'#39778e':'#6a9dab';
 c.setTransform(size/256,0,0,size/256,0,0);c.clearRect(0,0,256,256);c.translate(128,128);c.scale(1.1,1.1);c.lineCap='round';
 const circle=(r,color,alpha,width)=>{c.globalAlpha=alpha;c.strokeStyle=color;c.lineWidth=width;c.beginPath();c.arc(0,0,r,0,TAU);c.stroke()};
 const line=(a,r1,r2,color,alpha,width,offset=0)=>{const x=-Math.sin(a)*offset,y=Math.cos(a)*offset;c.globalAlpha=alpha;c.strokeStyle=color;c.lineWidth=width;c.beginPath();c.moveTo(Math.cos(a)*r1+x,Math.sin(a)*r1+y);c.lineTo(Math.cos(a)*r2+x,Math.sin(a)*r2+y);c.stroke()};
 const arc=(r,a,sweep,color,alpha,width)=>{c.globalAlpha=alpha;c.strokeStyle=color;c.lineWidth=width;c.beginPath();c.arc(0,0,r,a,a+sweep);c.stroke()};
 const glow=(radius,stops)=>{c.globalAlpha=1;const g=c.createRadialGradient(0,0,0,0,0,radius);for(const [at,color]of stops)g.addColorStop(at,color);c.fillStyle=g;c.beginPath();c.arc(0,0,radius,0,TAU);c.fill()};
 glow(100,[[0,dark?'rgba(143,220,235,.17)':'rgba(20,127,159,.07)'],[1,'rgba(143,220,235,0)']]);
 glow(78,[[0,dark?'#181b1e':'#e9f8fc'],[.55,dark?'#0d0f11':'rgba(205,233,241,.5)'],[1,dark?'rgba(17,19,21,.4)':'rgba(234,247,250,0)']]);
 circle(92,faint,.17,.6);
 for(let i=0;i<60;i++)line(i*Math.PI/30-t*.5,i%5===0?86:89,91,faint,i%5===0?.55:.22,i%5===0?.9:.5);
 arc(96,t,.65,cyan,.55,.8);arc(96,t+Math.PI,.4,cyan,.3,.8);
 circle(78,white,.8,1.4);circle(75,faint,.4,.55);
 for(let i=0;i<10;i++)for(const offset of [-2,2]){const a=-Math.PI/2+i*Math.PI/5+t*.1;line(a,61,72,cyan,.1,6,offset);line(a,61,72,white,.76,1.7,offset)}
 circle(55,white,.75,1.5);circle(52,faint,.36,.6);
 arc(58,-t*2,1.35,cyan,.14,5);arc(58,-t*2,1.05,cyan,.85,1.3);arc(49,t*3+Math.PI,.9,cyan,.6,.8);
 for(let i=0;i<3;i++){const a=-Math.PI/2+i*TAU/3;line(a,32,47,white,.65,2.2);c.globalAlpha=1;c.fillStyle=cyan;c.beginPath();c.arc(Math.cos(a)*48,Math.sin(a)*48,1.5,0,TAU);c.fill()}
 glow(32+energy*pulse*2,[[0,'rgba(143,220,235,.28)'],[1,'rgba(143,220,235,0)']]);
 circle(27,cyan,.14+energy*.08,6);circle(27,cyan,1,2.8);circle(22,faint,.35,.6);
 glow(20,[[0,dark?`rgba(230,248,255,${.45+energy*pulse*.25})`:'rgba(50,101,121,.4)'],[.5,'rgba(143,220,235,.12)'],[1,'rgba(143,220,235,.015)']]);
 for(let i=0;i<24;i++){const wave=.5+.5*Math.sin(t*12+i*.7+e.offset);line(i*Math.PI/12,34,35.4+energy*(2+wave*5),cyan,.22+energy*.35,1)}
 for(let i=0;i<4;i++){const a=t*(i%2===0?1:-1)+i*Math.PI/2,r=i%2===0?82:44;c.globalAlpha=.75;c.fillStyle=cyan;c.beginPath();c.arc(Math.cos(a)*r,Math.sin(a)*r,i%2===0?1.3:.9,0,TAU);c.fill()}
 c.globalAlpha=1;
}
function tick(now){frame=0;if(document.hidden||reduced.matches){previous=0;return}if(previous)clock+=Math.min(now-previous,80)/1000;previous=now;
 if(now-last>=1000/30){last=now-(now-last)%(1000/30);for(const [host,e]of entries){if(!host.isConnected){release(host,e);continue}if(e.visible&&host.dataset.resting!=='true')paint(e,clock)}}wake();
}
function pause(){cancelAnimationFrame(frame);frame=0;previous=0;if(reduced.matches)for(const e of entries.values())paint(e,0);wake()}
document.addEventListener('visibilitychange',pause);reduced.addEventListener('change',pause);
new MutationObserver(()=>{for(const e of entries.values())paint(e,clock)}).observe(document.documentElement,{attributes:true,attributeFilter:['data-theme']});
window.JarvisStellar={attach};
function login(){attach(document.getElementById('constellation'))}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',login,{once:true});else login();
})();
