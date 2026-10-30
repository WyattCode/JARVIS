const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');const fs=require('fs'),assert=require('assert');
(async()=>{const b=await chromium.launch({headless:true});try{const p=await b.newPage({viewport:{width:1440,height:900}}),errors=[];p.on('pageerror',e=>errors.push(e.message));
 await p.route('**/*',r=>{const path=new URL(r.request().url()).pathname;if(path==='/voice')return r.fulfill({contentType:'text/html',body:fs.readFileSync(__dirname+'/../src/voice/voice.html','utf8')});return r.fulfill({json:path==='/v1/models'?{data:[{id:'chat',kind:'chat'}]}:path==='/v1/tools'?{data:[{id:'chat',kind:'chat',state:'ready'}]}:{enabled:false}})});
 await p.goto('https://jarvis.test/voice');await p.waitForFunction(()=>jarvis.ready);assert.equal(await p.title(),'Jarvis · 人工智能助手');
 await p.locator('#text').fill('保留输入草稿');
 for(const width of [1024,1440,1920]){
  await p.setViewportSize({width,height:900});await p.locator('#sideGrip').click();await p.waitForTimeout(300);
  assert.equal(await p.locator('#menu').getAttribute('aria-expanded'),'false');assert(await p.locator('#side').evaluate(e=>e.inert));
  assert.equal((await p.locator('#app > main').boundingBox()).x,0);
  const grip=await p.locator('#sideGrip').boundingBox();assert(grip.x>=0&&grip.width>0);
  await p.locator('#sideGrip').click();await p.waitForTimeout(300);assert.equal(await p.locator('#menu').getAttribute('aria-expanded'),'true');
  assert.equal(await p.locator('#text').inputValue(),'保留输入草稿');
 }
 // Start dragging while the previous collapse is still in flight: no snap to 0/full width.
 await p.locator('#menu').click();await p.waitForTimeout(60);
 let mid=await p.locator('#sideGrip').boundingBox();await p.mouse.move(mid.x+12,mid.y+32);await p.mouse.down();
 const beforeDrag=await p.locator('#app > main').boundingBox();await p.mouse.move(mid.x+17,mid.y+32);
 const afterDrag=await p.locator('#app > main').boundingBox();assert(Math.abs(afterDrag.x-beforeDrag.x)<60,'drag continues from the visible column');
 await p.locator('#sideGrip').dispatchEvent('pointercancel',{pointerId:1});await p.mouse.up();await p.waitForTimeout(300);
 assert.equal(await p.locator('#menu').getAttribute('aria-expanded'),'false');
 await p.locator('#menu').click();await p.waitForTimeout(300);
 await p.locator('#menu').click();await p.waitForTimeout(280);await p.reload();await p.waitForFunction(()=>jarvis.ready);
 assert.equal(await p.locator('#menu').getAttribute('aria-expanded'),'false');assert.equal((await p.locator('#app > main').boundingBox()).x,0);
 const grip=await p.locator('#sideGrip').boundingBox();await p.mouse.move(grip.x+12,grip.y+32);await p.mouse.down();await p.mouse.move(230,grip.y+32,{steps:12});await p.mouse.up();await p.waitForTimeout(300);
 assert.equal(await p.locator('#menu').getAttribute('aria-expanded'),'true');
 let edge=await p.locator('#sideGrip').boundingBox();await p.mouse.move(edge.x+12,edge.y+32);await p.mouse.down();await p.mouse.move(30,edge.y+32,{steps:8});await p.locator('#sideGrip').dispatchEvent('pointercancel',{pointerId:1});await p.mouse.up();await p.waitForTimeout(300);assert.equal(await p.locator('#sideGrip').getAttribute('aria-expanded'),'true');
 edge=await p.locator('#sideGrip').boundingBox();await p.mouse.move(edge.x+12,edge.y+32);await p.mouse.down();await p.mouse.move(140,edge.y+32,{steps:8});await p.locator('#sideGrip').evaluate(e=>e.releasePointerCapture(1));await p.mouse.move(700,edge.y+32);await p.mouse.up();await p.waitForTimeout(300);assert.equal(await p.evaluate(()=>$('app').classList.contains('desktop-side-drag')),false);assert.equal(await p.locator('#sideGrip').getAttribute('aria-expanded'),'true');
 await p.locator('#sideGrip').focus();await p.keyboard.press('ArrowLeft');await p.waitForTimeout(280);assert.equal(await p.locator('#menu').getAttribute('aria-expanded'),'false');
 await p.keyboard.press('ArrowRight');await p.waitForTimeout(280);assert.equal(await p.locator('#menu').getAttribute('aria-expanded'),'true');
 await p.setViewportSize({width:416,height:760});assert(await p.locator('#sideGrip').isHidden());await p.locator('#menu').click();assert.equal(await p.locator('#side').evaluate(e=>e.inert),false);
 await p.setViewportSize({width:1440,height:900});await p.waitForTimeout(300);assert.equal(await p.locator('#menu').getAttribute('aria-expanded'),'true');
 await p.emulateMedia({reducedMotion:'reduce'});await p.locator('#menu').click();assert.equal((await p.locator('#app > main').boundingBox()).x,0);
 assert.deepEqual(errors,[]);console.log(JSON.stringify({pass:true,checks:['three PC widths fully collapse and reopen','draft preserved','state survives reload','grip drags open from fully collapsed','keyboard arrows','mobile drawer unchanged','reduced motion','updated title'],errors},null,2));
}finally{await b.close()}})().catch(e=>{console.error(e);process.exitCode=1});
