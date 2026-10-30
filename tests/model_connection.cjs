// Connection diagnostics must recover without becoming permanent conversation messages.
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('fs'),path=require('path'),assert=require('assert');
(async()=>{
 const browser=await chromium.launch({headless:true});
 try{
  const page=await browser.newPage();let fail=true;const errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(()=>{
   if(!localStorage.getItem('audit-seeded')){
    localStorage.setItem('audit-seeded','1');localStorage.setItem('jarvis.current',JSON.stringify('old'));
    localStorage.setItem('jarvis.convs',JSON.stringify([{id:'old',updated:1,msgs:[
     {id:'user',at:Date.now(),role:'user',text:'无法连接模型：这句话是我输入的'},
     {id:'old-error',at:Date.now(),role:'sys',error:true,text:'无法连接模型：无法连接服务器，请检查网络'},
     {id:'other-error',at:Date.now(),role:'sys',error:true,text:'另一个需要保留的错误'}]}]));
   }
  });
  await page.route('**/*',r=>{
   const p=new URL(r.request().url()).pathname,reply=d=>r.fulfill({contentType:'application/json',body:JSON.stringify(d)});
   if(p==='/voice')return r.fulfill({contentType:'text/html',body:fs.readFileSync(path.join(__dirname,'../src/voice/voice.html'),'utf8')});
   if(p==='/v1/models')return fail?r.abort('failed'):reply({data:[{id:'chat',kind:'chat'}]});
   if(p==='/v1/tools')return reply({data:[{id:'chat',kind:'chat',keep_loaded:true,state:'ready'}]});
   return reply({enabled:false,text:''});
  });
  await page.goto('http://127.0.0.1:8190/voice');
  await page.waitForFunction(()=>typeof modelLoadFailures!=='undefined'&&modelLoadFailures===1);
  assert.equal(await page.locator('#statusPill').getAttribute('data-s'),'loading');
  assert.equal(await page.evaluate(()=>cur.msgs.some(m=>m.id==='old-error')),false);
  assert.equal(await page.evaluate(()=>cur.msgs.some(m=>m.id==='user')),true);
  assert.equal(await page.evaluate(()=>cur.msgs.some(m=>m.id==='other-error')),true);
  await page.evaluate(()=>loadModels());
  assert.equal(await page.locator('#statusPill').getAttribute('data-s'),'offline');
  assert((await page.locator('#statusPop').textContent()).includes('自动重试'));
  assert.equal(await page.evaluate(()=>cur.msgs.length),2);
  fail=false;await page.evaluate(()=>pollTools());
  await page.waitForFunction(()=>jarvis.ready);
  assert.equal(await page.locator('#statusPill').getAttribute('data-s'),'ready');
  assert(!(await page.locator('#statusPop').textContent()).includes('自动重试'));
  assert.equal(await page.evaluate(()=>JSON.parse(localStorage.getItem('jarvis.convs'))[0].msgs.length),2);
  await page.reload();await page.waitForFunction(()=>jarvis.ready);
  assert.equal(await page.evaluate(()=>cur.msgs.length),2);
  assert.deepEqual(errors,[]);
  console.log(JSON.stringify({pass:true,checks:['first failure stays connecting','persistent failure is visible in status','automatic retry recovers','recovery clears diagnostics','legacy system notices removed','user text and unrelated errors preserved','connection errors never saved across refresh']}));
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
