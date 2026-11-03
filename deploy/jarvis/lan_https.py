#!/usr/bin/env python3
"""TLS relay to Jarvis loopback, including streaming and WebSockets.

LAN behavior is unchanged by default. A separate public listener can require
personal login with --auth-file and --public-host.

No external dependencies. Requires server.crt/server.key in --cert-dir.
"""
import argparse
import asyncio
import copy
import ipaddress
import json
import urllib.request
import urllib.parse
import ssl
import signal
import sys
from pathlib import Path

sys.path.append(str(Path(__file__).resolve().parent))
from bounded_http import request_json, read_json_response


async def relay(reader, writer):
    while data := await reader.read(65536):
        writer.write(data)
        await writer.drain()


def same_https_origin(origin, host):
    try:
        source = urllib.parse.urlsplit(origin)
        target = urllib.parse.urlsplit('https://' + host)
        return (source.scheme == 'https' and source.path in ('', '/') and
                not source.query and not source.fragment and
                source.username is None and source.password is None and
                target.username is None and target.password is None and
                source.hostname == target.hostname and
                (source.port or 443) == (target.port or 443))
    except ValueError:
        return False


def role_ready(state, kind):
    return any(tool.get('kind') == kind and tool.get('state') in ('ready', 'busy')
               for tool in state.get('data', []))


class StatusQueries:
    """Share only in-flight reads; every later poll still obtains fresh status."""
    def __init__(self, fetch):
        self.fetch = fetch
        self.pending = {}

    async def get(self, port, path):
        key = (port, path)
        task = self.pending.get(key)
        if task is None or task.done():
            task = asyncio.create_task(self.fetch(port, path))
            self.pending[key] = task

            def finished(done):
                if self.pending.get(key) is done:
                    self.pending.pop(key, None)
                # A disconnected requester must not leave an unobserved failure.
                if not done.cancelled():
                    done.exception()
            task.add_done_callback(finished)
        # One disconnected browser must not cancel another browser's status read.
        # Callers merge role metadata, so give each caller its own mutable result.
        return copy.deepcopy(await asyncio.shield(task))


async def main(args):
    network = ipaddress.ip_network(args.subnet)
    access = None
    if bool(args.auth_file) != bool(args.public_host):
        raise ValueError('--auth-file and --public-host must be configured together')
    if args.auth_file:
        if not args.static_dir:
            raise ValueError('--static-dir is required for the public access gate')
        if not args.public_host:
            raise ValueError('--public-host is required with --auth-file')
        from public_access import PublicAccess
        access = PublicAccess(args.auth_file, args.public_host, static_dir=args.static_dir)

    share = None
    if args.media_share_config:
        if not access:
            raise ValueError("public media sharing requires the public login gate")
        from media_share import MediaShare
        share = MediaShare(args.media_share_config, args.public_host, recovery_port=args.backend)

    async def fetch_status(port, path):
        return await request_json(f'http://127.0.0.1:{port}{path}', timeout=3, max_bytes=4*1024*1024)

    upstream_json = StatusQueries(fetch_status).get

    async def json_reply(writer, value, status=200):
        body = json.dumps(value).encode()
        writer.write(f'HTTP/1.1 {status} { {200:"OK",403:"Forbidden",503:"Service Unavailable"}.get(status,"Error")}\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n'.encode()+body)
        await writer.drain()

    async def client(reader, writer):
        upstream = None
        tasks = []
        try:
            peer = writer.get_extra_info('peername')
            if not peer or ipaddress.ip_address(peer[0]) not in network:
                return
            head = b''
            backend = args.backend
            fallback = False
            if args.static_dir:
                head = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 10)
                line = head.split(b'\r\n', 1)[0].decode('ascii')
                method, target, _ = line.split(' ', 2)
                path = target.split('?', 1)[0]
                request_headers = {}
                for field in head.split(b'\r\n')[1:]:
                    if not field:
                        continue
                    key, separator, value = field.partition(b':')
                    if not separator:
                        raise ValueError('malformed HTTP header')
                    request_headers.setdefault(key.lower(), []).append(value.decode('latin-1').strip())
                # Capabilities bypass personal login only for this exact, signed GET/HEAD route.
                if share and path.startswith('/media/'):
                    if request_headers.get(b'host') != [args.public_host] or method not in ('GET', 'HEAD'):
                        await json_reply(writer, {'error':'media route refused'},403)
                        return
                    await share.serve(writer, method, target, request_headers)
                    return
                if access:
                    if not await access.handle(reader, writer, method, target, request_headers, peer):
                        return
                    # Personal login cookies are never forwarded into model/voice backends.
                    parts = head.split(b'\r\n')
                    head = b'\r\n'.join([parts[0]] + [p for p in parts[1:] if not p.lower().startswith(b'cookie:')])
                if share and path == '/v1/media/share' and method == 'POST':
                    lengths = request_headers.get(b'content-length', [])
                    if len(lengths) != 1 or request_headers.get(b'transfer-encoding') or not lengths[0].isdigit() or not 0 < int(lengths[0]) <= 4096:
                        await json_reply(writer, {'error':'invalid share request'},400)
                        return
                    try:
                        value = json.loads(await asyncio.wait_for(reader.readexactly(int(lengths[0])),10))
                        if not isinstance(value, dict):
                            raise ValueError('expected object')
                        url = share.url(value.get('url'))
                    except (ValueError, TypeError):
                        await json_reply(writer, {'error':'only generated images or videos can be shared'},400)
                    except OSError:
                        await json_reply(writer, {'error':'media file is not ready'},404)
                    else:
                        await json_reply(writer, {'url':url})
                    return
                origins = request_headers.get(b'origin', [])
                hosts = request_headers.get(b'host', [])
                if origins and (len(origins) != 1 or len(hosts) != 1 or not (
                        same_https_origin(origins[0], hosts[0]) or origins[0] in args.allow_origin)):
                    await json_reply(writer, {'error':'cross-origin request refused'},403)
                    return
                # Opt-in public voice experiment; read on every request for immediate withdrawal.
                voice_test = {}
                if access and args.voice_test_config:
                    try:
                        voice_test = json.loads(Path(args.voice_test_config).read_text())
                        if not isinstance(voice_test, dict):
                            voice_test = {}
                        port = voice_test.get('backend_port')
                        if type(port) is not int or not 1 <= port <= 65535:
                            voice_test = {}
                    except (OSError, ValueError, TypeError):
                        voice_test = {}
                test_enabled = voice_test.get('enabled') is True
                if method == 'GET' and path == '/v1/voice-test':
                    ready = False
                    if test_enabled:
                        try:
                            state = await upstream_json(voice_test['backend_port'], '/v1/tools')
                            ready = role_ready(state, 'speech') and role_ready(state, 'transcription')
                        except Exception:
                            pass
                    await json_reply(writer, {'enabled':test_enabled, 'ready':ready})
                    return
                test_requested = path == '/v1/realtime' and urllib.parse.parse_qs(
                    urllib.parse.urlsplit(target).query).get('voice_variant') == ['new']
                if test_requested and not test_enabled:
                    await json_reply(writer, {'error':'voice test disabled'},503)
                    return
                if args.voice_backend and method == 'GET' and path in ('/v1/tools', '/health'):
                    try:
                        main_state, voice_state, worker_state = await asyncio.gather(
                            upstream_json(args.backend, '/v1/tools'),
                            upstream_json(args.voice_backend, '/v1/tools'),
                            upstream_json(args.speech_backend, '/v1/tools'))
                        if path == '/health':
                            ready = (role_ready(worker_state, 'speech') and
                                     role_ready(main_state, 'chat') and
                                     role_ready(main_state, 'transcription') and
                                     role_ready(voice_state, 'speech') and
                                     role_ready(voice_state, 'transcription'))
                            await json_reply(writer, {'ok':ready,'voice_split':not args.local_speech}, 200 if ready else 503)
                        else:
                            for tool in main_state['data']:
                                if tool['kind']=='speech':
                                    actual=next((x for x in worker_state['data'] if x['id']==tool['id']),None)
                                    if actual:tool.update(actual)
                            main_state['voice_sessions']=voice_state.get('voice_sessions',0)
                            await json_reply(writer,main_state)
                    except Exception:
                        await json_reply(writer, {'ok':False,'error':'voice dependency unavailable'},503)
                    return
                if args.voice_backend and path=='/v1/realtime':backend=args.voice_backend
                if test_requested:
                    backend=voice_test['backend_port']
                    query = urllib.parse.parse_qsl(urllib.parse.urlsplit(target).query, keep_blank_values=True)
                    target = path + (('?' + urllib.parse.urlencode([(k,v) for k,v in query if k != 'voice_variant'])) if any(k != 'voice_variant' for k,v in query) else '')
                    replacement = f'{method} {target} HTTP/1.1'
                    head = replacement.encode() + head[len(line):]
                    line = replacement
                if args.speech_backend and path=='/v1/audio/speech':backend=args.speech_backend
                fallback=bool(args.voice_backend and method=='GET' and path.startswith(('/v1/files/','/v1/jobs/','/v1/videos/')))
                if path!='/v1/realtime':
                    fields=head.split(b'\r\n')
                    fields=[field for field in fields[1:] if field and not field.lower().startswith(b'connection:')]
                    head=line.encode()+b'\r\n'+b'\r\n'.join(fields)+b'\r\nConnection: close\r\n\r\n'
                name = {'/': ('voice.html', 'text/html; charset=utf-8'),
                        '/voice': ('voice.html', 'text/html; charset=utf-8'),
                        '/voice/': ('voice.html', 'text/html; charset=utf-8'),
                        '/favicon.svg': ('icon.svg', 'image/svg+xml'),
                        '/favicon.ico': ('favicon.ico', 'image/x-icon'),
                        '/auth-assets/theme.css': ('auth/theme.css', 'text/css; charset=utf-8'),
                        '/auth-assets/theme.js': ('auth/theme.js', 'application/javascript; charset=utf-8'),
                        '/auth-assets/login.css': ('auth/login.css', 'text/css; charset=utf-8'),
                        '/auth-assets/login.js': ('auth/login.js', 'application/javascript; charset=utf-8'),
                        '/auth-assets/jarvis-core.webp': ('auth/jarvis-core.webp', 'image/webp'),
                        '/apple-touch-icon.png': ('apple-touch-icon.png', 'image/png'),
                        '/manifest.webmanifest': ('manifest.webmanifest', 'application/manifest+json'),
                        '/service-worker.js': ('service-worker.js', 'application/javascript; charset=utf-8'),
                        '/auth-assets/pwa.js': ('auth/pwa.js', 'application/javascript; charset=utf-8'),
                        '/auth-assets/pwa.css': ('auth/pwa.css', 'text/css; charset=utf-8'),
                        '/pwa/icon-192.png': ('pwa/icon-192.png', 'image/png'),
                        '/pwa/icon-512.png': ('pwa/icon-512.png', 'image/png'),
                        '/pwa/icon-maskable-512.png': ('pwa/icon-maskable-512.png', 'image/png')}.get(target.split('?', 1)[0])
                if method in ('GET', 'HEAD') and name:
                    body = (Path(args.static_dir) / name[0]).read_bytes()
                    if access and name[0] == 'voice.html':
                        identity = json.dumps(access.browser_identity(request_headers), ensure_ascii=True).replace('<', '\\u003c')
                        body = body.replace(b'<!--PUBLIC_IDENTITY-->', ('<script>window.jarvisAccount=' + identity + ';</script>').encode(), 1)
                        account = '<section class="sect public-account" aria-label="个人访问"><a class="btn" href="/account">账户</a><form method="post" action="/logout"><button class="btn" type="submit"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 4H4v16h5m6-13 5 5-5 5M8 12h12"/></svg>退出登录</button></form></section>'
                        body = body.replace(b'<!--PUBLIC_ACCOUNT-->', account.encode(), 1)
                        if test_enabled:
                            from public_voice_test import inject
                            body = inject(body)

                    headers = ('HTTP/1.1 200 OK\r\nContent-Type: ' + name[1] +
                               '\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff' +
                               ('\r\nX-Frame-Options: DENY' if access else '') +
                               ("\r\nContent-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline' blob:; style-src 'self' 'unsafe-inline'; worker-src 'self' blob:; manifest-src 'self'; img-src 'self' blob: data:; media-src 'self' blob:; connect-src 'self' ws: wss:" + ("; frame-ancestors 'none'" if access else '') if name[0]=='voice.html' else '') +
                               '\r\nContent-Length: ' + str(len(body)) + '\r\nConnection: close\r\n\r\n')
                    writer.write(headers.encode() + (body if method == 'GET' else b''))
                    await writer.drain()
                    return
            back, upstream = await asyncio.wait_for(
                asyncio.open_connection('127.0.0.1', backend), 10)
            if head:
                upstream.write(head)
                await upstream.drain()
            inspect_mcp = bool(share and path == '/mcp' and method == 'POST')
            inspect_media = bool(share and (inspect_mcp or path == "/v1/images/generations" or (method == "GET" and path.startswith(("/v1/jobs/", "/v1/videos/")) and not path.endswith("/content"))))
            if inspect_media and method == 'POST':
                tasks.append(asyncio.create_task(relay(reader, upstream)))
            if fallback or inspect_media:
                reply_head = await asyncio.wait_for(back.readuntil(b'\r\n\r\n'),900 if inspect_media and method == 'POST' else 30)
                if fallback and reply_head.split(b' ',2)[1]==b'404':
                    upstream.close()
                    await upstream.wait_closed()
                    back,upstream=await asyncio.wait_for(asyncio.open_connection('127.0.0.1',args.voice_backend),10)
                    upstream.write(head);await upstream.drain()
                    reply_head=await asyncio.wait_for(back.readuntil(b'\r\n\r\n'),30)
                if inspect_mcp and b'content-type: application/json' in reply_head.lower() and reply_head.split(b' ',2)[1].startswith(b'2'):
                    try:
                        value = await read_json_response(back,reply_head,timeout=30,max_bytes=96*1024*1024)
                        def encoded_result():
                            return json.dumps(share.rewrite_mcp(value),ensure_ascii=False).encode()
                        body = await asyncio.to_thread(encoded_result)
                    except (OSError, ValueError):
                        await json_reply(writer,{'error':{'message':'任务服务响应不完整或超过限制，请稍后重试'}},503)
                        return
                    lines = reply_head.split(b'\r\n')
                    kept = [v for v in lines[1:] if v and not v.lower().startswith((b'content-length:',b'connection:',b'transfer-encoding:',b'trailer:'))]
                    writer.write(lines[0]+b'\r\n'+b'\r\n'.join(kept)+f'\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n'.encode()+body)
                    await writer.drain()
                    return
                if inspect_media and not inspect_mcp and b'content-type: application/json' in reply_head.lower():
                    fields = {}
                    for field in reply_head.split(b'\r\n')[1:]:
                        key, sep, value = field.partition(b':')
                        if sep:
                            fields[key.lower()] = value.strip()
                    length = fields.get(b'content-length', b'')
                    if length.isdigit() and int(length) <= 2*1024*1024 and b'transfer-encoding' not in fields:
                        body = await asyncio.wait_for(back.readexactly(int(length)),30)
                        try:
                            body = json.dumps(await asyncio.to_thread(share.rewrite,json.loads(body)),ensure_ascii=False).encode()
                        except (ValueError, TypeError):
                            pass
                        lines = reply_head.split(b'\r\n')
                        kept = [v for v in lines[1:] if v and not v.lower().startswith((b'content-length:',b'connection:'))]
                        writer.write(lines[0]+b'\r\n'+b'\r\n'.join(kept)+f'\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n'.encode()+body)
                        await writer.drain()
                        return
                writer.write(reply_head);await writer.drain()
            if not tasks:
                tasks.append(asyncio.create_task(relay(reader, upstream)))
            tasks.append(asyncio.create_task(relay(back, writer)))
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
        except (OSError, asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError, ValueError):
            pass
        finally:
            for task in tasks:
                task.cancel()
            if tasks:
                await asyncio.gather(*tasks, return_exceptions=True)
            for stream in (upstream, writer):
                if stream:
                    stream.close()
                    try:
                        await stream.wait_closed()
                    except OSError:
                        pass

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(Path(args.cert_dir) / 'server.crt',
                            Path(args.cert_dir) / 'server.key')
    if access:
        def reload_certificate():
            try:
                candidate = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                candidate.load_cert_chain(Path(args.cert_dir) / 'server.crt', Path(args.cert_dir) / 'server.key')
                context.load_cert_chain(Path(args.cert_dir) / 'server.crt', Path(args.cert_dir) / 'server.key')
                print('public TLS certificate reloaded', file=sys.stderr, flush=True)
            except (OSError, ssl.SSLError):
                print('public TLS reload failed; retaining previous certificate context', file=sys.stderr, flush=True)
        asyncio.get_running_loop().add_signal_handler(signal.SIGHUP, reload_certificate)
    server = await asyncio.start_server(client, args.host, args.port, ssl=context,
                                        ssl_handshake_timeout=10 if access else 60)

    async with server:
        await server.serve_forever()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--media-share-config', help='Private generated-media roots and persistent signing key configuration')
    parser.add_argument('--auth-file', help='Optional separate public listener: personal login configuration')
    parser.add_argument('--public-host', help='Exact public hostname required by the personal login gate')
    parser.add_argument('--voice-test-config', help='Optional public-only, dynamically removable voice experiment configuration')
    parser.add_argument('--static-dir', help='Serve UI assets without restarting the model daemon')
    parser.add_argument('--allow-origin', action='append', default=[], help='Explicit additional trusted browser origin; absent Origin remains valid for API clients')
    parser.add_argument('--host', required=True)
    parser.add_argument('--subnet', default='192.168.10.0/24')
    parser.add_argument('--port', type=int, default=8443)
    parser.add_argument('--backend', type=int, default=8190)
    parser.add_argument('--voice-backend', type=int)
    parser.add_argument('--speech-backend', type=int)
    parser.add_argument('--local-speech', action='store_true', help='Speech runs on this Spark; report single-Spark local services in health')
    parser.add_argument('--cert-dir', required=True)
    asyncio.run(main(parser.parse_args()))
