/* Network-only app navigation. Never cache private pages, API responses or audio. */
'use strict';
const entryPaths=new Set(['/','/voice','/voice/','/login','/account']);
const offline=`<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="theme-color" content="#09090b"><title>Jarvis · 等待网络</title><style>body{margin:0;min-height:100dvh;display:grid;place-items:center;box-sizing:border-box;padding:max(24px,env(safe-area-inset-top)) max(24px,env(safe-area-inset-right)) max(24px,env(safe-area-inset-bottom)) max(24px,env(safe-area-inset-left));background:#09090b;color:#ededf1;font:16px/1.7 system-ui}main{max-width:340px}h1{font-size:28px}p{color:#a1a1aa}a{display:inline-block;color:#09090b;background:#ededf1;padding:10px 20px;border-radius:14px;text-decoration:none;min-height:24px}</style><main><h1>Jarvis</h1><p>暂时无法连接网络。恢复网络后即可继续使用。</p><a href="/voice">重新连接</a></main></html>`;
self.addEventListener('install',event=>event.waitUntil(self.skipWaiting()));
self.addEventListener('fetch',event=>{
 const request=event.request,url=new URL(request.url);
 if(request.method!=='GET'||request.mode!=='navigate'||url.origin!==self.location.origin||!entryPaths.has(url.pathname))return;
 event.respondWith(fetch(request).catch(()=>new Response(offline,{status:503,headers:{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store','Content-Security-Policy':"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"}})));
});
