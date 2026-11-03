#!/usr/bin/env python3
"""Optional personal-access gate for the separate public Jarvis TLS listener.

No model credentials are used here. Sessions stay in memory, and the existing
LAN listener remains unchanged unless --auth-file is explicitly configured.
"""
import argparse
import asyncio
from collections import OrderedDict
import hashlib
import hmac
from http.cookies import SimpleCookie, CookieError
import html
import json
import os
from pathlib import Path
import secrets
import time
import urllib.parse

COOKIE = '__Host-jarvis_session'
# Server sessions do not expire by time. Clients may cap cookie retention.
COOKIE_MAX_AGE = 10 * 365 * 86400


class PublicAccess:
    def __init__(self, filename, hostname, clock=time.time, static_dir=None):
        path = Path(filename)
        if path.stat().st_mode & 0o077:
            raise ValueError('public auth file must have mode 600')
        self.static_dir = Path(static_dir) if static_dir else Path(__file__).resolve().parents[2] / 'src/voice'
        self.cfg = json.loads(path.read_text())
        self.iterations = int(self.cfg['iterations'])
        if self.iterations < 200000:
            raise ValueError('password derivation is too weak')
        self.salt = bytes.fromhex(self.cfg['salt'])
        self.digest = bytes.fromhex(self.cfg['password_hash'])
        # Legacy primary account stays valid; additional users carry independent salts.
        self.users = {self.cfg['username']: self.cfg}
        for user in self.cfg.get('users', []):
            if user['username'] in self.users or not 1 <= len(user['username']) <= 64:
                raise ValueError('duplicate or invalid account')
            if int(user['iterations']) < 200000 or len(bytes.fromhex(user['salt'])) < 16 or len(bytes.fromhex(user['password_hash'])) != 32:
                raise ValueError('invalid account derivation')
            self.users[user['username']] = user
        self.session_users = {}
        self.hostname = hostname.lower()
        self.clock = clock
        self.sessions = OrderedDict()
        self.attempts = OrderedDict()
        self.hash_slots = asyncio.Semaphore(2)

    async def reply(self, writer, status, body=b'', content_type='text/html; charset=utf-8', extra=()):
        if isinstance(body, str):
            body = body.encode()
        reason = {200:'OK',303:'See Other',400:'Bad Request',401:'Unauthorized',403:'Forbidden',405:'Method Not Allowed',413:'Content Too Large',429:'Too Many Requests'}.get(status,'Error')
        headers = [f'HTTP/1.1 {status} {reason}', f'Content-Type: {content_type}', f'Content-Length: {len(body)}',
                   'Cache-Control: no-store', 'Connection: close', 'X-Content-Type-Options: nosniff',
                   'Referrer-Policy: same-origin', "Content-Security-Policy: default-src 'none'; style-src 'self'; script-src 'self'; img-src 'self' data:; manifest-src 'self'; worker-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
                   'Permissions-Policy: camera=(), microphone=(self)']
        headers += [f'{k}: {v}' for k,v in extra]
        writer.write(('\r\n'.join(headers)+'\r\n\r\n').encode()+body)
        await writer.drain()

    def page(self, error='', account=False):
        if account:
            title, description = '已与你连接', '你的个人空间已就绪。'
            form = '<a class="secondary" href="/voice">返回贾维斯</a><form method="post" action="/logout"><button class="primary" type="submit">退出登录</button></form>'
        else:
            title, description = '欢迎回来', '登录，继续与你的贾维斯对话。'
            form = '''<form class="login-form" id="loginForm" method="post" action="/login">
<label class="field" for="username">账户<span class="input-wrap"><svg class="input-icon" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="8" r="3.5"/><path d="M5 20v-2a7 7 0 0 1 14 0v2"/></svg><input id="username" name="username" autocomplete="username" autocapitalize="none" spellcheck="false" maxlength="64" placeholder="输入你的账户" required></span></label>
<label class="field" for="password">密码<span class="input-wrap"><svg class="input-icon" viewBox="0 0 24 24" aria-hidden="true"><rect x="5" y="10" width="14" height="11" rx="3"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/></svg><input id="password" type="password" name="password" autocomplete="current-password" maxlength="256" placeholder="输入你的密码" required><button class="eye" id="showPassword" type="button" aria-label="显示密码" aria-pressed="false"><svg class="eye-open" viewBox="0 0 24 24" aria-hidden="true"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/></svg><svg class="eye-closed" viewBox="0 0 24 24" aria-hidden="true" hidden><path d="m3 3 18 18M10.5 5.1A12 12 0 0 1 22 12a18 18 0 0 1-3 3.8M6.2 6.2A19 19 0 0 0 2 12s3.5 7 10 7a12 12 0 0 0 5.8-1.8"/></svg></button></span></label>
<button class="primary" type="submit">登录</button></form><p class="form-note">你的专属连接，由此开启</p>'''
        template = (self.static_dir / 'auth/login.html').read_text()
        values = {'TITLE': title, 'DESCRIPTION': description, 'ERROR_HIDDEN': '' if error else 'hidden', 'ERROR': html.escape(error), 'FORM': form}
        for key, value in values.items():
            template = template.replace('{{' + key + '}}', value)
        return template

    def session(self, headers):
        raw = headers.get(b'cookie', [])
        if len(raw) != 1:
            return None
        try:
            cookie = SimpleCookie(); cookie.load(raw[0])
            token = cookie.get(COOKIE)
            if token is None or len(token.value) > 128:
                return None
            key = hashlib.sha256(token.value.encode()).hexdigest()
            expiry = self.sessions.get(key, 0)
            if expiry <= self.clock():
                self.sessions.pop(key, None)
                self.session_users.pop(key, None)
                return None
            return key
        except (ValueError, TypeError, CookieError):
            return None

    def browser_identity(self, headers):
        user = self.session_users.get(self.session(headers))
        if not user:
            return None
        # Keep the primary account's existing browser data and model key intact.
        prefix = 'jarvis.' if user == self.cfg['username'] else 'jarvis.user.' + hashlib.sha256(user.encode()).hexdigest()[:24] + '.'
        return {'username': user, 'storagePrefix': prefix}

    async def handle(self, reader, writer, method, target, headers, peer):
        """Return True to forward the already authenticated request, False if handled."""
        hosts = headers.get(b'host', [])
        try:
            parsed = urllib.parse.urlsplit('https://' + hosts[0]) if len(hosts) == 1 else None
            valid_host = (parsed is not None and parsed.hostname == self.hostname and
                          parsed.username is None and parsed.password is None and parsed.path in ('','/') and
                          not parsed.query and not parsed.fragment and parsed.port in (None,443,18447))
        except ValueError:
            valid_host = False
        if not valid_host or not target.startswith('/') or target.startswith('//'):
            await self.reply(writer,403,'访问地址不匹配'); return False
        lengths = headers.get(b'content-length', [])
        transfers = headers.get(b'transfer-encoding', [])
        if len(lengths)>1 or len(transfers)>1 or (lengths and transfers) or (transfers and transfers[0].lower()!='chunked'):
            await self.reply(writer,400,'请求格式无效'); return False
        try:
            size = int(lengths[0]) if lengths else 0
        except ValueError:
            size = -1
        if not 0 <= size <= 32*1024*1024:
            await self.reply(writer,413,'请求大小无效'); return False
        path = target.split('?',1)[0]
        origins = headers.get(b'origin', [])
        origin = urllib.parse.urlsplit(origins[0]) if len(origins)==1 else None
        try:
            origin_ok = bool(origin and origin.scheme=='https' and origin.hostname==self.hostname and
                             origin.username is None and origin.password is None and origin.path in ('','/') and
                             not origin.query and not origin.fragment and (origin.port or 443)==(parsed.port or 443))
        except ValueError:
            origin_ok = False
        if origins and not origin_ok:
            await self.reply(writer,403,'来源不匹配'); return False
        if path in ('/login','/logout') and method=='POST' and not origin_ok:
            await self.reply(writer,403,'请从登录页面提交'); return False
        if 'websocket' in ','.join(headers.get(b'upgrade', [])).lower() and not origin_ok:
            await self.reply(writer,403,'语音连接来源不匹配'); return False
        # Only presentation assets are public; model, voice and media routes stay gated.
        if method in ('GET', 'HEAD') and path in ('/favicon.svg', '/favicon.ico', '/apple-touch-icon.png', '/auth-assets/theme.css', '/auth-assets/theme.js', '/auth-assets/login.css', '/auth-assets/login.js', '/auth-assets/jarvis-core.webp', '/manifest.webmanifest', '/service-worker.js', '/auth-assets/pwa.js', '/auth-assets/pwa.css', '/pwa/icon-192.png', '/pwa/icon-512.png', '/pwa/icon-maskable-512.png'):
            return True
        session = self.session(headers)
        if path=='/login':
            if method=='GET':
                await self.reply(writer,303,extra=[('Location','/voice')]) if session else await self.reply(writer,200,self.page())
                return False
            if method!='POST':
                await self.reply(writer,405); return False
            if transfers or size>4096 or headers.get(b'content-type', [''])[0].split(';',1)[0]!='application/x-www-form-urlencoded':
                await self.reply(writer,400,'登录请求无效'); return False
            now=self.clock(); key=str(peer[0]); count,until=self.attempts.get(key,(0,now+300))
            if until<=now: count,until=0,now+300
            if count>=8:
                await self.reply(writer,429,self.page('尝试次数较多，请稍后再试。'),extra=[('Retry-After',str(max(1,int(until-now))))]);return False
            # Charge the attempt before awaiting body/hash, so concurrent attempts cannot bypass the bound.
            self.attempts[key]=(count+1,until);self.attempts.move_to_end(key)
            while len(self.attempts)>256:self.attempts.popitem(last=False)
            body=await asyncio.wait_for(reader.readexactly(size),10)
            try:
                fields=urllib.parse.parse_qs(body.decode('utf-8'),strict_parsing=True,max_num_fields=4)
                username=fields.get('username',[]); password=fields.get('password',[])
                valid_fields=(len(username)==1 and len(password)==1 and len(username[0])<=64 and len(password[0])<=256)
            except (ValueError,UnicodeError):valid_fields=False
            secret=password[0] if valid_fields else ''
            user=self.users.get(username[0], self.cfg) if valid_fields else self.cfg
            async with self.hash_slots:
                digest=await asyncio.to_thread(hashlib.pbkdf2_hmac,'sha256',secret.encode(),bytes.fromhex(user['salt']),int(user['iterations']))
            valid=bool(valid_fields and hmac.compare_digest(username[0].encode(),user['username'].encode()) and hmac.compare_digest(digest,bytes.fromhex(user['password_hash'])))
            if not valid:
                await self.reply(writer,401,self.page('账户或密码不正确。'));return False
            self.attempts.pop(key,None)
            token=secrets.token_urlsafe(32);session_key=hashlib.sha256(token.encode()).hexdigest();self.sessions[session_key]=float('inf');self.session_users[session_key]=user['username']
            while len(self.sessions)>20:
                expired,_=self.sessions.popitem(last=False);self.session_users.pop(expired,None)
            await self.reply(writer,303,extra=[('Location','/voice'),('Set-Cookie',f'{COOKIE}={token}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age={COOKIE_MAX_AGE}')]);return False
        if not session:
            if method=='GET' and path in ('/','/voice','/voice/','/account'):
                await self.reply(writer,303,extra=[('Location','/login')])
            else:
                await self.reply(writer,401,json.dumps({'error':'login_required'}),'application/json')
            return False
        if path=='/logout':
            if method!='POST':
                await self.reply(writer,405);return False
            self.sessions.pop(session,None);self.session_users.pop(session,None)
            await self.reply(writer,303,extra=[('Location','/login'),('Set-Cookie',f'{COOKIE}=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0')]);return False
        if path=='/account' and method=='GET':
            await self.reply(writer,200,self.page(account=True));return False
        return True


def create(filename, username, credentials):
    path=Path(filename);path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    if path.exists() or Path(credentials).exists():raise ValueError('credential files already exist; refusing to overwrite')
    password=secrets.token_urlsafe(24);salt=secrets.token_bytes(16);iterations=600000
    cfg={'username':username,'salt':salt.hex(),'iterations':iterations,'password_hash':hashlib.pbkdf2_hmac('sha256',password.encode(),salt,iterations).hex()}
    with open(path,'x',opener=lambda p,f:os.open(p,f,0o600))as file:json.dump(cfg,file)
    with open(credentials,'x',opener=lambda p,f:os.open(p,f,0o600))as file:file.write(f'账户：{username}\n密码：{password}\n登录：https://jarvis.odn.cc/login\n账户与退出：https://jarvis.odn.cc/account\n')


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--create',required=True);parser.add_argument('--username',default='wyatt');parser.add_argument('--credentials',required=True)
    args=parser.parse_args();create(args.create,args.username,args.credentials)
