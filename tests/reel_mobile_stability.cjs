const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright'),fs=require('fs'),assert=require('assert');
(async()=>{const b=await chromium.launch();try{const results=[];for(const size of [{width:425,height:623},{width:400,height:900},{width:890,height:502},{width:678,height:466}]){
 const p=await b.newPage({reducedMotion:'reduce',viewport:size,hasTouch:true,isMobile:true,userAgent:'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 Chrome/144 Mobile Safari/537.36'});
 await p.route('**/*',r=>{const n=new URL(r.request().url()).pathname;if(n==='/audit-wide.svg'||n==='/audit-tall.svg')return r.fulfill({contentType:'image/svg+xml',body:`<svg xmlns="http://www.w3.org/2000/svg" width="${n.includes('wide')?1600:900}" height="${n.includes('wide')?900:1600}"><rect width="100%" height="100%" fill="#356078"/></svg>`});return n==='/voice'?r.fulfill({contentType:'text/html',body:fs.readFileSync('src/voice/voice.html','utf8')}):r.fulfill({json:n==='/v1/models'?{data:[{id:'chat',kind:'chat'}]}:n==='/v1/tools'?{data:[{id:'chat',state:'ready'}]}:{enabled:false}})});
 await p.goto('https://jarvis.test/voice');await p.waitForFunction(()=>jarvis.ready);await p.evaluate(()=>showVoice(true));
 const positions=()=>p.evaluate(()=>['#orb','#vm .controls','#vm .stage'].map(s=>{const r=document.querySelector(s).getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}}));
 const before=await positions();await p.evaluate(()=>{reelLive=true;cur.msgs.push({id:'reel-test',role:'tool',kind:'image',name:'generate_image',text:'测试作品'});renderReel()});
 assert(await p.locator('#vm .rc').isVisible());assert.equal(await p.locator('#mobileTabs').count(),0);
 const state=await p.locator('.rc').evaluate(e=>{const s=getComputedStyle(e),a=getComputedStyle(e,'::after'),r=e.getBoundingClientRect(),list=e.parentElement.getBoundingClientRect();return{transform:s.transform,top:r.top,listTop:list.top,outline:{top:a.top,right:a.right,bottom:a.bottom,left:a.left,width:a.borderTopWidth,events:a.pointerEvents}}});
 assert.equal(state.transform,'none');assert(state.top>=state.listTop);for(const side of ['top','right','bottom','left'])assert.equal(state.outline[side],'0px');assert.equal(state.outline.width,'2px');assert.equal(state.outline.events,'none');
 await p.locator('#reelToggle').click();assert(await p.locator('#reelList').isHidden());await p.locator('#reelToggle').click();assert(await p.locator('#reelList').isVisible());assert(await p.evaluate(()=>V.open));
 assert(await p.evaluate(()=>{const c=document.querySelector('#vm .controls').getBoundingClientRect(),r=document.querySelector('#reel').getBoundingClientRect();return c.bottom<=r.top+1 && r.bottom<=innerHeight+1}));
 await p.evaluate(()=>{for(let i=0;i<8;i++)cur.msgs.push({id:'many-'+i,role:'tool',kind:'image',name:'generate_image',text:'作品 '+i});renderReel()});
 await p.waitForTimeout(40);
 assert(await p.locator('#reelList').evaluate(e=>{const r=e.getBoundingClientRect();return [...e.children].every(c=>{const a=c.getBoundingClientRect();return a.top>=r.top&&a.bottom<=r.bottom})}),'whole card must fit scrollport');
 await p.locator('#reelList').evaluate(e=>e.scrollLeft=e.scrollWidth);assert(await p.locator('#reelList').evaluate(e=>e.scrollLeft>0));
 await p.evaluate(()=>{cur.msgs.push({id:'newest',role:'tool',kind:'video',name:'generate_video',text:'最新作品'});renderReel()});await p.waitForTimeout(40);
 assert.equal(await p.locator('#reelList').evaluate(e=>e.scrollLeft),0);
 assert.equal(await p.locator('#reelList .rc').first().getAttribute('data-key'),'newest:p');
 // New works received while collapsed must be revealed when reopening.
 await p.locator('#reelList').evaluate(e=>e.scrollLeft=e.scrollWidth);
 await p.locator('#reelToggle').click();await p.evaluate(()=>{cur.msgs.push({id:'collapsed-new',role:'tool',kind:'image',name:'generate_image',text:'收起时生成'});renderReel()});await p.waitForTimeout(40);
 await p.locator('#reelToggle').click();await p.waitForTimeout(40);assert.equal(await p.locator('#reelList').evaluate(e=>e.scrollLeft),0);
 // Ordinary rerenders preserve manual browsing.
 await p.locator('#reelList').evaluate(e=>e.scrollLeft=e.scrollWidth);const manual=await p.locator('#reelList').evaluate(e=>e.scrollLeft);
 await p.evaluate(()=>renderReel());await p.waitForTimeout(40);assert.equal(await p.locator('#reelList').evaluate(e=>e.scrollLeft),manual);
 // Works arriving while the voice view is hidden also reveal on return.
 await p.evaluate(()=>{showVoice(false);cur.msgs.push({id:'hidden-new',role:'tool',kind:'image',name:'generate_image',text:'聊天期间生成'});renderReel()});await p.waitForTimeout(40);await p.evaluate(()=>showVoice(true));await p.waitForTimeout(40);assert.equal(await p.locator('#reelList').evaluate(e=>e.scrollLeft),0);
 await p.evaluate(()=>{cur.msgs.push({id:'ratios',role:'tool',kind:'image',name:'generate_image',text:'画幅测试',media:[{kind:'image',url:'/audit-wide.svg'},{kind:'image',url:'/audit-tall.svg'}]});renderReel()});
 await p.waitForFunction(()=>[...document.querySelectorAll('.rc img')].length===2&&[...document.querySelectorAll('.rc img')].every(e=>e.complete&&e.naturalWidth));
 assert(await p.locator('.rc img').evaluateAll(imgs=>imgs.every(img=>{const card=img.closest('.rc'),thumb=img.parentElement,r=card.getBoundingClientRect(),list=card.parentElement.getBoundingClientRect();return Math.abs(parseFloat(card.style.getPropertyValue('--media-ratio'))-img.naturalWidth/img.naturalHeight)<.001&&getComputedStyle(img).objectFit==='contain'&&Math.abs(thumb.clientHeight-img.clientHeight)<=1&&r.bottom<=list.bottom&&card.querySelector('figcaption').getBoundingClientRect().bottom<=r.bottom})));
 results.push({size,inlineWorks:true,collapseWorks:true,controlsUncovered:true});await p.close();
 }console.log(JSON.stringify({pass:true,results}));}finally{await b.close()}})().catch(e=>{console.error(e);process.exitCode=1});
