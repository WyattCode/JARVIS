const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const {execFileSync} = require('child_process');
const path = require('path'), assert = require('assert');
const root = path.resolve(__dirname, '..');
const html = execFileSync('python3', ['-c', "import sys;sys.path.insert(0,'deploy/jarvis');from public_access import PublicAccess;from pathlib import Path;page=PublicAccess.__new__(PublicAccess);page.static_dir=Path('src/voice');print(page.page())"], {cwd:root, encoding:'utf8'});
(async () => {
  const browser = await chromium.launch({headless:true}), checks = [], errors = [];
  try {
    for (const [width,height] of [[360,510],[416,510],[466,578],[390,844],[1280,800]]) {
      const page = await browser.newPage({viewport:{width,height}});
      page.on('pageerror', e => errors.push(e.message));
      await page.route('**/*', route => {
        const name = new URL(route.request().url()).pathname;
        if (name === '/login') return route.fulfill({contentType:'text/html', body:html});
        const names = {'/auth-assets/pwa.css':'auth/pwa.css','/auth-assets/pwa.js':'auth/pwa.js','/auth-assets/theme.css':'auth/theme.css','/auth-assets/theme.js':'auth/theme.js','/auth-assets/login.css':'auth/login.css','/auth-assets/login.js':'auth/login.js','/auth-assets/jarvis-core.webp':'auth/jarvis-core.webp','/favicon.svg':'icon.svg'};
        if (!names[name]) return route.abort();
        return route.fulfill({path:path.join(root,'src/voice',names[name])});
      });
      await page.goto('https://jarvis.test/login');
      await page.locator('.entity').evaluate(img => img.decode());
      const geometry = await page.evaluate(() => ({width:innerWidth,fullWidth:document.documentElement.scrollWidth,height:innerHeight,fullHeight:document.documentElement.scrollHeight}));
      assert.equal(geometry.width, geometry.fullWidth); assert.equal(geometry.height, geometry.fullHeight);
      const submit = await page.locator('button[type=submit]').boundingBox();
      assert(submit.height >= 44 && submit.y + submit.height <= height);
      await page.locator('#password').fill('example-only');
      await page.locator('#showPassword').click();
      assert.equal(await page.locator('#password').getAttribute('type'), 'text');
      assert(await page.locator('.eye-closed').isVisible()); assert(!await page.locator('.eye-open').isVisible());
      await page.locator('#showPassword').click();
      assert.equal(await page.locator('#password').getAttribute('type'), 'password');
      assert.equal(await page.locator('#password').inputValue(), 'example-only');
      await page.emulateMedia({reducedMotion:'reduce'});
      assert.equal(await page.locator('.entity').evaluate(e => getComputedStyle(e).animationName), 'none');
      checks.push(`${width}x${height}: complete form, real icon, password toggle, reduced motion`);
      await page.close();
    }
    assert.deepEqual(errors, []); console.log(JSON.stringify({pass:true,checks,errors},null,2));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode=1; });
