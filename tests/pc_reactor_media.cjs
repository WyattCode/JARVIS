const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('fs'),path=require('path'),assert=require('assert');
(async()=>{const browser=await chromium.launch({headless:true});try{
 const p=await browser.newPage({viewport:{width:1440,height:1000},permissions:['clipboard-read','clipboard-write']});const errors=[],calls=[];
 p.on('pageerror',e=>errors.push(e.message));const file='/media/'+('f'.repeat(64))+'/img_0123456789abcdef/image-0.png';
 await p.route('**/*',r=>{const u=new URL(r.request().url());calls.push(u.pathname);
  if(u.pathname==='/voice')return r.fulfill({contentType:'text/html',body:fs.readFileSync(path.join(__dirname,'../src/voice/voice.html'),'utf8')});
  if(u.pathname==='/v1/media/share'){assert.deepEqual(r.request().postDataJSON(),{url:'/v1/files/img_0123456789abcdef/image-0.png'});return r.fulfill({json:{url:'https://jarvis.test'+file}})}
  if(u.pathname===file)return r.fulfill({contentType:'image/png',body:Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jh18AAAAASUVORK5CYII=','base64')});
  return r.fulfill({json:u.pathname==='/v1/models'?{data:[{id:'chat',kind:'chat'}]}:u.pathname==='/v1/tools'?{data:[{id:'chat',state:'ready'}]}:{enabled:false}})
 });
 await p.goto('https://jarvis.test/voice');await p.waitForFunction(()=>jarvis.ready);
 assert.equal(await p.evaluate(()=>document.documentElement.dataset.theme),'dark');
 assert.equal(await p.evaluate(()=>getComputedStyle(document.documentElement).getPropertyValue('--bg').trim()),'#09090b');
 for(const size of [{width:1024,height:768},{width:1440,height:900},{width:1920,height:1080}]){
  await p.setViewportSize(size);assert(await p.locator('#empty .stellar-canvas').isVisible());assert.equal(await p.locator('#empty .sun-face').evaluate(e=>getComputedStyle(e).opacity),'0');
  const overflow=await p.evaluate(()=>document.documentElement.scrollWidth>innerWidth);assert(!overflow);
 }
 await p.evaluate(()=>{S.key='test-api-key';window.__blobCalls=0;URL.createObjectURL=()=>{__blobCalls++;return 'blob:bad'};$('log').append(card({kind:'image',url:'/v1/files/img_0123456789abcdef/image-0.png',prompt:'test artwork'}))});
 await p.waitForFunction(()=>document.querySelector('.card img')?.src.includes('/media/'));
 assert.equal(await p.evaluate(()=>__blobCalls),0);
 const share=p.getByRole('button',{name:'复制作品链接',exact:true});await share.click();await p.waitForFunction(()=>!document.querySelector('.card button[aria-label="复制作品链接"]').disabled);
 assert.equal(await p.evaluate(()=>navigator.clipboard.readText()),'https://jarvis.test'+file);
 assert.equal(calls.filter(x=>x==='/v1/media/share').length,1);
 await p.emulateMedia({reducedMotion:'reduce'});await p.waitForTimeout(80);
 const still=await p.locator('#empty canvas').evaluate(c=>c.toDataURL());await p.waitForTimeout(100);assert.equal(await p.locator('#empty canvas').evaluate(c=>c.toDataURL()),still);
 assert.deepEqual(errors,[]);console.log(JSON.stringify({pass:true,checks:['neutral dark default','B1 reactor at three desktop widths','legacy face hidden','share HTTPS link without blob or Bearer','cached media capability','reduced motion stable'],errors},null,2));
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1});
