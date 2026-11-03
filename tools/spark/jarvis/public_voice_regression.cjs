#!/usr/bin/env node
// Public browser playback regression. Text-triggered voice turns; no microphone/ASR claim.
const fs = require('fs');
const path = require('path');
// Exact scheduled-source comparison distinguishes natural digital silence from lost output.
// This function also runs in the browser, using only its recording state.
function verifyRecordedSamples(keys) {
  if (!V.rec || V.rec.rate !== RATE) return null;
  const output = recordedOutput(), per = {};
  for (const key of keys) per[key] = {samples:0, unchecked:0, maxDiff:0, rate:RATE};
  for (const p of V.rec.pieces) {
    const result = per[p.key];
    if (!result) continue;
    const offset = Math.round((p.start - V.rec.t0) * RATE);
    result.samples += p.data.length;
    if (offset < 0 || offset + p.data.length > output.length) {result.unchecked += p.data.length;continue;}
    for (let i=0; i<p.data.length; i++) result.maxDiff = Math.max(result.maxDiff,Math.abs(output[offset+i]-p.data[i]));
  }
  return per;
}
function sourceVerified(r, turn) {
  const keys=turn?.recordingKeys;
  if (!keys?.length) return false;
  let ms=0;
  for(const key of keys) {
    const v=r.outputVerification?.[key];
    if (!v || !Number.isFinite(v.samples) || v.samples<=0 || v.unchecked!==0 ||
        !Number.isFinite(v.maxDiff) || v.maxDiff>1e-6 || v.rate!==24000) return false;
    ms += v.samples/v.rate*1000;
  }
  return Number.isFinite(turn.audioMs) && Math.abs(ms-turn.audioMs)<1;
}
function assess(r, maxStartMs = 3000) {
  const checks = [];
  const add = (name, ok) => checks.push({name, ok: !!ok});
  for (const name of ['long', 'recovery']) {
    const t = r.turns[name];
    add(`${name}: completed with audio`, t?.status === 'completed' && t.audioPackets > 0);
    add(`${name}: starts within ${maxStartMs}ms`, Number.isFinite(t?.playbackMs) && t.playbackMs <= maxStartMs);
  }
  const long = r.turns.long;
  add('long: at least 15s audio', long?.audioMs >= 15000);
  add('long: playback before text completion', Number.isFinite(long?.playbackMs) && Number.isFinite(long?.textDoneMs) && long.playbackMs < long.textDoneMs);
  add('long: no scheduling underrun', long?.gaps && Object.keys(long.gaps).length === 0);
  add('long: output recorder captured playback', r.output?.some(x => long?.recordingKeys?.includes(x.reply)));
  add('long: output covers the reply', r.output?.some(x => long?.recordingKeys?.includes(x.reply) && Number.isFinite(x.window_ms) && x.window_ms >= long.audioMs - 1000));
  add('long: no output render/delivery gaps', Array.isArray(r.output) && r.output.length > 0 && (r.output.filter(x => long?.recordingKeys?.includes(x.reply)).every(x => !x.gaps_over && !x.render_gaps) || sourceVerified(r,long)));
  add('interrupt: active response cancelled', r.turns.interrupt?.status === 'cancelled');
  add('interrupt: old audio removed', r.interruptedAudioCleared === true);
  add('browser: no page errors', Array.isArray(r.errors) && r.errors.length === 0);
  return checks;
}
module.exports = {assess, verifyRecordedSamples};
async function main() {
  const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
  const out = path.resolve(process.env.OUT || 'public-voice-regression.json');
  const url = process.env.JARVIS_URL || 'http://127.0.0.1:8190/voice';
  const report = {url, scope: 'Public Chrome, text-triggered real voice replies and programmatic interruption; excludes microphone, ASR and Bluetooth', turns:{}, errors:[]};
  const browser = await chromium.launch({headless:true,args:['--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream','--autoplay-policy=no-user-gesture-required']});
  let page;
  try {
    const ctx = await browser.newContext({serviceWorkers:'block',permissions:['microphone']});
    page = await ctx.newPage();
    page.on('pageerror', e => report.errors.push(e.message));
    await page.goto(url);
    if (new URL(page.url()).pathname === '/login') {
      // Credentials are only filled into the login page; never included in the report.
      const home = process.env.JARVIS_AUTH_DIR || path.join(require('os').homedir(), 'jarvis/public');
      const text = fs.readFileSync(path.join(home,'登录信息.txt'),'utf8');
      const password = text.match(/密码[：:]\s*(\S+)/u)?.[1];
      if (!password) throw Error('Login credentials unavailable');
      await page.locator('#username').fill(JSON.parse(fs.readFileSync(path.join(home,'auth.json'),'utf8')).username);
      await page.locator('#password').fill(password);
      await page.locator('button[type=submit]').click();
      await page.waitForURL('**/voice');
    }
    await page.waitForFunction(() => window.jarvis?.ready);
    await page.evaluate(() => {jarvis.recordOutput = true;});
    await page.locator('#mic').click();
    await page.waitForFunction(() => voiceReady() && V.mic && V.rec);
    await page.evaluate(() => {
      window.__vr = {turns:{}, current:null};
      V.ws.addEventListener('message', e => {
        const m = JSON.parse(e.data), t = __vr.turns[__vr.current];
        if (!t) return;
        const at = performance.now() - t.start;
        if (m.type === 'localrouter.response.timing') t.serverTiming = m;
        if ((m.type === 'response.audio_transcript.delta' || m.type === 'response.text.delta') && t.firstTextMs == null) t.firstTextMs = at;
        if (m.type === 'error') t.errors.push(m.error);
        if (m.type === 'response.audio_transcript.delta' || m.type === 'response.text.delta') t.text += m.delta || '';
        if (m.type === 'response.created') {t.id = m.response.id; return;}
        if (m.type === 'response.audio.delta') {
          t.audioPackets++;if (!t.items.includes(m.item_id)) {t.items.push(m.item_id);t.recordingKeys.push(`${V.conn}:${m.item_id}`);}
          t.audioMs += atob(m.delta).length / 2 / 24000 * 1000;
          if (t.firstAudioMs == null) t.firstAudioMs = at;
        }
        if (m.type === 'localrouter.response.text_done') t.textDoneMs = at;
        if (m.type === 'response.done' && m.response.id === t.id) {t.status = m.response.status;t.statusDetails=m.response.status_details;}
      });
      window.__vrTimer = setInterval(() => {
        const t = __vr.turns[__vr.current];
        if (t && t.playbackMs == null && V.live.some(p => t.items.includes(p.item))) t.playbackMs = performance.now()-t.start;
      }, 5);
    });
    async function start(name, prompt) {
      await page.waitForFunction(() => voiceReady() && !V.resp && !V.thinking && V.live.length === 0 && V.held.length === 0, null, {timeout:120000});
      await page.evaluate(({name,prompt}) => {
        __vr.current = name; __vr.turns[name] = {start:performance.now(),audioPackets:0,audioMs:0,text:'',errors:[],items:[],recordingKeys:[],status:null,playbackMs:null,textDoneMs:null};
        jarvis.say(prompt);
      }, {name,prompt});
      console.log(`Requested ${name}`);
    }
    async function finish(name) {
      await page.waitForFunction(name => __vr.turns[name]?.status != null, name, {timeout:180000});
      await page.waitForFunction(() => V.live.length === 0 && V.held.length === 0, null, {timeout:180000});
      await page.evaluate(name => {__vr.turns[name].gaps=Object.fromEntries(Object.entries(jarvis.voice.gaps).filter(([id])=>__vr.turns[name].items.includes(id)));},name);
      Object.assign(report,await page.evaluate(() => ({turns:__vr.turns,output:jarvis.output(600000,30),voiceModel:V.expectedEffortModel,voiceEffort:S.voiceReasoningEffort})));
    }
    await start('warmup','请只回答：语音测试开始。'); await finish('warmup');
    await start('long','请用中文写一篇约三百字的完整故事，讲述灯塔管理员在暴风雨中帮助船只安全返航。直接讲故事，不要标题、列表或解释。'); await finish('long');
    await start('interrupt','请只原样朗读以下内容，不要省略，不要添加说明：' + '今天我们先检查语音系统，再核对网络连接和模型状态。如果发现异常，就保留日志并恢复稳定版本。这样可以避免重复修改，也能保证每次测试都有清楚的结果。'.repeat(3));
    await page.waitForFunction(() => __vr.turns.interrupt.playbackMs != null && V.resp && V.live.length > 0, null, {timeout:60000});
    await page.evaluate(() => {bargeIn(true);});
    await page.waitForFunction(() => __vr.turns.interrupt.status != null, null, {timeout:15000});
    await page.waitForTimeout(200);
    report.interruptedAudioCleared = await page.evaluate(() => ![...V.live,...V.held].some(p => __vr.turns.interrupt.items.includes(p.item)));
    await start('recovery','请只回答：打断后恢复正常。'); await finish('recovery');
    report.outputVerification = await page.evaluate(verifyRecordedSamples,report.turns.long.recordingKeys);
    Object.assign(report,await page.evaluate(() => ({turns:__vr.turns,output:jarvis.output(600000,30),voiceModel:V.expectedEffortModel,voiceEffort:S.voiceReasoningEffort})));
  } catch(e) {
    report.failure = e.message;
    if (page) {
      try {Object.assign(report,await page.evaluate(() => ({turns:window.__vr?.turns || {},output:window.jarvis?.output(180000,30)})));} catch {}
    }
  } finally {
    if (page) {try {await page.evaluate(() => {clearInterval(window.__vrTimer);voiceStop();});} catch {}}
    await browser.close();
    report.checks = assess(report, Number(process.env.MAX_START_MS || 3000));
    report.passed = !report.failure && report.checks.every(c => c.ok);
    fs.mkdirSync(path.dirname(out),{recursive:true});
    fs.writeFileSync(out,JSON.stringify(report,null,2)+'\n');
    console.log(JSON.stringify({passed:report.passed,checks:report.checks,failure:report.failure,report:out},null,2));
    if (!report.passed) process.exitCode=1;
  }
}
if (require.main === module) main().catch(e => {console.error(e.message);process.exitCode=1;});
