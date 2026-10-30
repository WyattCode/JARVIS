#!/usr/bin/env python3
"""Loopback-only Jarvis chat bridge. Credentials stay on the server.

Chat goes to the configured LAN model; speech, media and other APIs stay local.
Existing model daemons are never started, stopped or reconfigured here.
"""
import argparse
import asyncio
import collections
import json
import mimetypes
import resource
import re
import ssl
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools/speech/drama3'))
from voice_catalog import describe_voices, preview_audio

EFFORTS = {'none', 'low', 'medium', 'high'}


def chat_body(body, config):
    if not isinstance(body, dict):
        raise ValueError('request must be a JSON object')
    out = dict(body)
    selected = out.get('model')
    aliases = {config['model'] + '--jarvis-' + e: e for e in EFFORTS}
    routed_effort = aliases.get(selected) if isinstance(selected, str) else None
    if routed_effort is not None:
        out['model'] = config['model']
    if out.get('model') not in (None, '', config['model'], config['name'], 'qwen3.8-27b'):
        raise ValueError('unknown chat model')
    out['model'] = config['model']
    kwargs = out.get('chat_template_kwargs') or {}
    if not isinstance(kwargs, dict):
        raise ValueError('chat_template_kwargs must be an object')
    kwargs = dict(kwargs)
    effort = routed_effort if routed_effort is not None else out.get('reasoning_effort')
    if effort is None:
        effort = config.get('reasoning_effort', 'high')
    if kwargs.get('enable_thinking') is False:
        effort = 'none'
    if not isinstance(effort, str) or effort not in EFFORTS:
        raise ValueError('reasoning_effort must be none, low, medium or high')
    out['reasoning_effort'] = effort
    kwargs['enable_thinking'] = effort != 'none'
    out['chat_template_kwargs'] = kwargs
    if 'max_tokens' not in out and 'max_completion_tokens' not in out:
        out['max_tokens'] = 8192
    return out


async def relay(reader, writer):
    while data := await reader.read(65536):
        writer.write(data)
        await writer.drain()


class Bridge:
    def __init__(self, config, backend=8190):
        self.config = config
        self.backend = backend
        self.base = urllib.parse.urlsplit(config['base_url'])
        if self.base.scheme not in ('http', 'https') or not self.base.hostname or self.base.username or self.base.password:
            raise ValueError('invalid upstream URL')
        self.recent = collections.deque(maxlen=20)
        self.history = json.loads(Path(config['job_history']).read_text()) if config.get('job_history') else {}
        self.artifact_root = Path(config['artifact_root']).resolve() if config.get('artifact_root') else None

    async def fetch_json(self, remote, path, port=None, timeout=8):
        def fetch():
            base = self.config['base_url'].rstrip('/') if remote else f'http://127.0.0.1:{port or self.backend}/v1'
            headers = {'Authorization': 'Bearer ' + self.config['api_key']} if remote else {}
            request = urllib.request.Request(base + path, headers=headers)
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(request, timeout=timeout) as response:
                return json.load(response)
        return await asyncio.to_thread(fetch)

    def video_ports(self, path, method):
        if path == '/v1/audio/speech' and self.config.get('speech_backend_port'):
            return [self.config['speech_backend_port']]
        if path == '/v1/audio/transcriptions' and self.config.get('transcription_backend_port'):
            return [self.config['transcription_backend_port']]
        if not self.config.get('video_worker_port'):
            return [self.backend]
        worker = self.config['video_worker_port']
        if path.startswith('/v1/tools/minimax-h3/'):
            return [worker]
        if path == '/v1/videos' or path.startswith(('/v1/videos/', '/v1/jobs/video_', '/v1/files/video_')):
            ports = [self.config['video_backend_port']]
            if method in ('GET', 'DELETE'):
                ports += [self.backend, worker]  # old head jobs and direct worker MCP jobs retain their IDs
            return list(dict.fromkeys(ports))
        return [self.backend]

    def mcp_ports(self, value):
        if not self.config.get('video_worker_port') or not isinstance(value, dict):
            return [self.backend]
        params = value.get('params') or {}
        if value.get('method') != 'tools/call' or not isinstance(params, dict):
            return [self.backend]
        name = params.get('name')
        args = params.get('arguments') or {}
        if not isinstance(args, dict):
            return [self.backend]
        video = args.get('model') in ('video', 'minimax-h3')
        if name == 'generate_video' or (video and name in ('reserve_for', 'load_model', 'unload_model')):
            return [self.config['video_worker_port']]
        if name == 'get_job' and str(args.get('id', args.get('job_id', ''))).startswith('video_'):
            return [self.config['video_worker_port']]
        return [self.backend]

    async def request_payload(self, reader, headers):
        limit = 32 * 1024 * 1024
        if b'transfer-encoding' not in headers:
            size = int(headers.get(b'content-length', b'0'))
            if not 0 <= size <= limit:
                raise ValueError('request is too large')
            return await asyncio.wait_for(reader.readexactly(size), 60)
        if headers[b'transfer-encoding'].lower() != b'chunked' or b'content-length' in headers:
            raise ValueError('invalid request framing')
        chunks, total = bytearray(), 0
        deadline = asyncio.get_running_loop().time() + 60
        async def read(awaitable):
            return await asyncio.wait_for(awaitable, max(0, deadline - asyncio.get_running_loop().time()))
        while True:
            line = await read(reader.readuntil(b'\r\n'))
            if len(line) > 8192:
                raise ValueError('chunk header is too large')
            size = int(line.split(b';', 1)[0].strip(), 16)
            if size < 0 or total + size > limit:
                raise ValueError('request is too large')
            if size == 0:
                trailers = 0
                while True:
                    line = await read(reader.readuntil(b'\r\n'))
                    trailers += len(line)
                    if trailers > 8192:
                        raise ValueError('trailers are too large')
                    if line == b'\r\n':
                        return bytes(chunks)
            data = await read(reader.readexactly(size + 2))
            if data[-2:] != b'\r\n':
                raise ValueError('invalid chunk')
            chunks.extend(data[:-2]); total += size

    async def local_rpc(self, port, value, timeout=15):
        def fetch():
            request = urllib.request.Request(f'http://127.0.0.1:{port}/mcp', data=json.dumps(value).encode(), headers={'Content-Type':'application/json'})
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(request, timeout=timeout) as response:
                return json.load(response)
        return await asyncio.to_thread(fetch)

    def unavailable_video(self, models):
        videos = [m for m in models if m.get('kind') == 'video']
        if not videos:
            videos = [{'id': 'minimax-h3', 'name': 'MiniMax H3', 'kind': 'video', 'keep_loaded': False}]
        return [dict(m, machine=self.config['video_worker_machine'], state='failed', running=False,
                     resident_bytes=0, working_bytes=0, last_error='视频备用机未连接') for m in videos]

    @staticmethod
    def worker_videos(models):
        if not isinstance(models, list) or any(not isinstance(m, dict) for m in models):
            raise ValueError('invalid worker model list')
        videos = [m for m in models if m.get('kind') == 'video']
        if not videos:
            raise ValueError('worker does not offer video')
        return videos

    async def model_list(self, value):
        result = await self.local_rpc(self.backend, value)
        text = result['result']['content'][0]
        state = json.loads(text['text'])
        try:
            remote = await self.local_rpc(self.config['video_worker_port'], value, timeout=1.5)
            worker = json.loads(remote['result']['content'][0]['text'])
            videos = [dict(t, machine=self.config['video_worker_machine']) for t in self.worker_videos(worker['models'])]
            state['video_worker_memory'] = worker.get('memory')
        except (OSError, ValueError, KeyError, TypeError, IndexError):
            videos = self.unavailable_video(state['models'])
        state['models'] = [t for t in state['models'] if t.get('kind') != 'video'] + videos
        text['text'] = json.dumps(state, ensure_ascii=False)
        return result

    async def metadata(self, path):
        local, remote = await asyncio.gather(self.fetch_json(False, path), self.fetch_json(True, '/models'))
        actual = next((m for m in remote.get('data', []) if m.get('id') == self.config['model']), None)
        if actual is None:
            raise ConnectionError('configured upstream model is unavailable')
        state = actual.get('status', {})
        state = state.get('value') if isinstance(state, dict) else state
        ready = state in (None, 'loaded', 'ready')
        context = actual.get('meta', {}).get('n_ctx')
        if path == '/models':
            brain = dict(actual, name=self.config['name'], kind='chat', machine=self.base.hostname,
                         running=ready, capabilities=['chat_completion'], default_for=['chat_completion'],
                         qualified=True)
            brain['jarvis'] = {'default_reasoning_effort': 'high', 'reasoning_efforts': sorted(EFFORTS),
                               'effective_context': context,
                               'voice_effort_models': {e: self.config['model'] + '--jarvis-' + e for e in EFFORTS},
                               'image_input': 'image' in actual.get('architecture', {}).get('input_modalities', []),
                               'pdf_text': Path('/usr/bin/pdftotext').exists()}
        else:
            brain = {'id': self.config['model'], 'name': self.config['name'], 'kind': 'chat',
                     'state': 'ready' if ready else 'loading', 'machine': self.base.hostname,
                     'keep_loaded': True, 'resident_bytes': 0, 'working_bytes': 0}
        others = [dict(m) for m in local.get('data', []) if m.get('kind') != 'chat']
        if self.config.get('speech_backend_port'):
            speech = await self.fetch_json(False, path, self.config['speech_backend_port'])
            speakers = [describe_voices(dict(m), self.config.get('voice_catalog'))
                        for m in speech.get('data', []) if m.get('kind') == 'speech']
            if not speakers:
                raise ConnectionError('configured speech service has no speech model')
            others = [m for m in others if m.get('kind') != 'speech'] + speakers
        if self.config.get('transcription_backend_port'):
            recognition = await self.fetch_json(False, path, self.config['transcription_backend_port'])
            recognizers = [dict(m, machine='head') for m in recognition.get('data', []) if m.get('kind') == 'transcription']
            if not recognizers:
                raise ConnectionError('configured transcription service has no transcription model')
            others = [m for m in others if m.get('kind') != 'transcription'] + recognizers
        if self.config.get('video_worker_port'):
            try:
                worker = await self.fetch_json(False, path, self.config['video_worker_port'], timeout=1.5)
                videos = [dict(m, machine=self.config['video_worker_machine']) for m in self.worker_videos(worker.get('data', []))]
            except (OSError, ValueError, TypeError, AttributeError):
                videos = self.unavailable_video(others)
            others = [m for m in others if m.get('kind') != 'video'] + videos
        if path == '/models':
            for model in others:
                if model.get('id') in self.config.get('video_limits', {}):
                    model['limits'] = self.config['video_limits'][model['id']]
        return dict(local, data=[brain] + others)

    async def pdf_text(self, payload):
        if not payload.startswith(b'%PDF-'):
            raise ValueError('文件不是有效的PDF')
        def limits():
            resource.setrlimit(resource.RLIMIT_AS, (128 * 1024 * 1024,) * 2)
            resource.setrlimit(resource.RLIMIT_CPU, (10, 10))
        process = await asyncio.create_subprocess_exec(
            '/usr/bin/pdftotext', '-layout', '-enc', 'UTF-8', '-', '-',
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL, preexec_fn=limits)
        async def feed():
            try:
                process.stdin.write(payload)
                await process.stdin.drain()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                process.stdin.close()
        async def read():
            chunks = []; size = 0
            while chunk := await process.stdout.read(65536):
                size += len(chunk)
                if size > 512 * 1024:
                    raise ValueError('PDF文字过多，请拆分文件后上传')
                chunks.append(chunk)
            return b''.join(chunks)
        tasks = [asyncio.create_task(feed()), asyncio.create_task(read()), asyncio.create_task(process.wait())]
        try:
            _, output, code = await asyncio.wait_for(asyncio.gather(*tasks), 15)
            if code:
                raise ValueError('PDF读取失败，请确认文件未加密且未损坏')
            text = output.decode('utf-8').strip()
            if not text:
                raise ValueError('PDF未提取到文字；扫描件请改传图片')
            return text
        except asyncio.TimeoutError:
            raise ValueError('处理PDF超时，请拆分后重试')
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            if process.returncode is None:
                process.kill()
            await process.wait()

    async def reply(self, writer, status, value):
        body = json.dumps(value, ensure_ascii=False).encode()
        reason = {200: 'OK', 400: 'Bad Request', 404: 'Not Found', 413: 'Payload Too Large', 503: 'Service Unavailable'}.get(status, 'Error')
        writer.write(f'HTTP/1.1 {status} {reason}\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n'.encode() + body)
        await writer.drain()

    async def client(self, reader, writer):
        upstream = None
        tasks = []
        response_started = False
        try:
            head = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 10)
            first, *fields = head[:-4].split(b'\r\n')
            method, target, _ = first.decode('ascii').split(' ', 2)
            path = urllib.parse.urlsplit(target).path
            headers = {}
            for field in fields:
                key, sep, value = field.partition(b':')
                if not sep:
                    raise ValueError('invalid header')
                key = key.lower()
                if key in headers and key in (b'content-length', b'transfer-encoding'):
                    raise ValueError('duplicate framing header')
                headers[key] = value.strip()
            if method == 'GET' and self.artifact_root:
                parts = path.split('/')
                if len(parts) == 4 and parts[1:3] in (['v1','jobs'], ['v1','videos']):
                    section = 'jobs' if parts[2] == 'jobs' else 'videos'
                    saved = self.history.get(section, {}).get(parts[3])
                    if saved:
                        await self.reply(writer, 200, saved)
                        return
                saved_file = None
                if len(parts) == 5 and parts[1:3] == ['v1','files']:
                    job = self.history.get('jobs', {}).get(parts[3], {})
                    archived = path in job.get('urls', []) and job.get('status') == 'completed'
                    generated = re.fullmatch(r'(?:image|video)_[0-9a-f]{16}', parts[3]) and re.fullmatch(r'(?:image-[0-9]+\.png|video\.mp4)', parts[4])
                    if archived or generated:
                        saved_file = self.artifact_root / parts[3] / parts[4]
                if len(parts) == 5 and parts[1:3] == ['v1','videos'] and parts[4] == 'content':
                    job = self.history.get('jobs', {}).get(parts[3], {})
                    if job.get('status') == 'completed' or re.fullmatch(r'video_[0-9a-f]{16}', parts[3]):
                        saved_file = self.artifact_root / parts[3] / 'video.mp4'
                allowed_root = self.artifact_root
                if saved_file and not saved_file.is_file() and parts[3].startswith('video_'):
                    for root in self.config.get('legacy_video_roots', []):
                        root = Path(root).resolve()
                        candidate = root / parts[3] / saved_file.name
                        if candidate.resolve().is_relative_to(root) and candidate.is_file():
                            saved_file, allowed_root = candidate, root
                            break
                if saved_file and saved_file.resolve().is_relative_to(allowed_root) and saved_file.is_file():
                    mime = mimetypes.guess_type(saved_file.name)[0] or 'application/octet-stream'
                    size = saved_file.stat().st_size
                    writer.write(f'HTTP/1.1 200 OK\r\nContent-Type: {mime}\r\nContent-Length: {size}\r\nCache-Control: private, no-store\r\nConnection: close\r\n\r\n'.encode())
                    response_started = True
                    with saved_file.open('rb') as file:
                        while chunk := file.read(65536):
                            writer.write(chunk)
                            await writer.drain()
                    return
            if method == 'GET' and path.startswith('/v1/voice-previews/'):
                match = re.fullmatch(r'/v1/voice-previews/([A-Za-z0-9][A-Za-z0-9._-]{0,63})\.wav', path)
                audio = preview_audio(self.config.get('voice_catalog'), match[1]) if match else None
                if audio is None:
                    await self.reply(writer, 404, {'error': {'message': 'voice preview not found'}})
                    return
                writer.write(f'HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: {len(audio)}\r\nCache-Control: private, max-age=3600\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n'.encode() + audio)
                response_started = True
                await writer.drain()
                return
            if method == 'GET' and path in ('/v1/models', '/v1/tools'):
                await self.reply(writer, 200, await self.metadata(path[3:]))
                return
            if method == 'GET' and path == '/__jarvis_brain/status':
                await self.reply(writer, 200, {'model': self.config['model'], 'default_effort': 'high', 'recent': list(self.recent)})
                return
            if method == 'POST' and path == '/v1/jarvis/extract-pdf':
                if b'transfer-encoding' in headers:
                    raise ValueError('PDF requests require Content-Length')
                size = int(headers.get(b'content-length', b'0'))
                if not 0 < size <= 10 * 1024 * 1024:
                    await self.reply(writer, 413, {'error': {'message': 'PDF最大10MB'}})
                    return
                payload = await asyncio.wait_for(reader.readexactly(size), 30)
                text = await self.pdf_text(payload)
                await self.reply(writer, 200, {'text': text})
                return
            payload = None
            ports = self.video_ports(path, method)
            if self.config.get('video_worker_port') and method == 'GET' and path == '/v1/skills/model-manager':
                value = await self.fetch_json(False, '/skills/model-manager')
                value['text'] = 'Video runs on a separate Spark. Never unload head speech/image models to make room for video. Video reserve/load/unload calls are routed to that worker.\n\n' + value.get('text', '')
                await self.reply(writer, 200, value)
                return
            if self.config.get('video_worker_port') and method == 'POST' and path == '/mcp':
                payload = await self.request_payload(reader, headers)
                value = json.loads(payload)
                params = value.get('params') if isinstance(value, dict) else None
                if isinstance(params, dict) and value.get('method') == 'tools/call' and params.get('name') == 'list_models':
                    await self.reply(writer, 200, await self.model_list(value))
                    return
                ports = self.mcp_ports(value)
                args = (params.get('arguments') or {}) if isinstance(params, dict) else {}
                job_id = str(args.get('id', '')) if isinstance(args, dict) else ''
                if isinstance(params, dict) and params.get('name') == 'get_job' and job_id.startswith('video_'):
                    saved = self.history.get('jobs', {}).get(job_id)
                    if saved:
                        await self.reply(writer, 200, {'jsonrpc':'2.0','id':value.get('id'),'result':{'content':[{'type':'text','text':json.dumps(saved)}],'isError':saved.get('status')=='failed'}})
                        return
                    probe = dict(value, params=dict(params, arguments=dict(args, wait_s=0)))
                    for port in dict.fromkeys([self.config['video_backend_port'], self.config['video_worker_port'], self.backend]):
                        try:
                            found = await self.local_rpc(port, probe, timeout=1.5)
                        except (OSError, ValueError):
                            continue
                        if not found.get('error') and not found.get('result', {}).get('isError', True):
                            ports = [port]
                            if not args.get('wait_s'):
                                await self.reply(writer, 200, found)
                                return
                            break
            if payload is None and ports != [self.backend] and method in ('POST', 'PUT', 'PATCH'):
                payload = await self.request_payload(reader, headers)
            if payload is not None:
                clean = [f for f in fields if f.split(b':', 1)[0].lower() not in (b'content-length', b'transfer-encoding')]
                head = first + b'\r\n' + b'\r\n'.join(clean) + f'\r\nContent-Length: {len(payload)}\r\n\r\n'.encode()
            if method == 'POST' and path == '/v1/chat/completions':
                if b'transfer-encoding' in headers:
                    raise ValueError('chat requests require Content-Length')
                size = int(headers.get(b'content-length', b'0'))
                if size < 0 or size > 32 * 1024 * 1024:
                    await self.reply(writer, 413, {'error': {'message': '请求附件累计过大，请减少附件或新建会话'}})
                    return
                body = await asyncio.wait_for(reader.readexactly(size), 60)
                value = chat_body(json.loads(body), self.config)
                encoded = json.dumps(value, ensure_ascii=False).encode()
                remote_port = self.base.port or (443 if self.base.scheme == 'https' else 80)
                tls = ssl.create_default_context() if self.base.scheme == 'https' else None
                back, upstream = await asyncio.wait_for(asyncio.open_connection(self.base.hostname, remote_port, ssl=tls), 10)
                route = self.base.path.rstrip('/') + '/chat/completions'
                auth = self.config['api_key']
                remote_headers = (f'POST {route} HTTP/1.1\r\nHost: {self.base.netloc}\r\nAuthorization: Bearer {auth}\r\nContent-Type: application/json\r\nContent-Length: {len(encoded)}\r\nConnection: close\r\n\r\n').encode()
                upstream.write(remote_headers + encoded)
                await upstream.drain()
                entry = {'time': round(time.time()), 'effort': value['reasoning_effort'],
                         'stream': bool(value.get('stream')), 'max_tokens': value.get('max_tokens'), 'status': 'active'}
                self.recent.append(entry)
                async def downstream():
                    nonlocal response_started
                    response = await asyncio.wait_for(back.readuntil(b'\r\n\r\n'), 3600)
                    entry['http_status'] = int(response.split(b' ', 2)[1])
                    if entry['http_status'] in (401, 403):
                        await self.reply(writer, 503, {'error': {'message': '远端大模型鉴权失败，请检查服务端接入配置'}})
                        response_started = True
                        entry['status'] = 'upstream_auth_failed'
                        return
                    writer.write(response)
                    response_started = True
                    await writer.drain()
                    await relay(back, writer)
                    entry['status'] = 'upstream_closed'
                async def disconnected():
                    await reader.read(1)
                    entry['status'] = 'client_disconnected'
                tasks = [asyncio.create_task(downstream()), asyncio.create_task(disconnected())]
            elif ports != [self.backend] or payload is not None:
                async def routed():
                    nonlocal upstream, response_started
                    for index, port in enumerate(ports):
                        back, upstream = await asyncio.wait_for(asyncio.open_connection('127.0.0.1', port), 10)
                        upstream.write(head + (payload or b'')); await upstream.drain()
                        response = await asyncio.wait_for(back.readuntil(b'\r\n\r\n'), 3600)
                        code = int(response.split(b' ', 2)[1])
                        if code == 404 and index + 1 < len(ports):
                            upstream.close(); await upstream.wait_closed(); upstream = None
                            continue
                        writer.write(response); response_started = True; await writer.drain()
                        await relay(back, writer)
                        return
                async def disconnected():
                    await reader.read(1)
                tasks = [asyncio.create_task(routed()), asyncio.create_task(disconnected())]
            else:
                back, upstream = await asyncio.wait_for(asyncio.open_connection('127.0.0.1', self.backend), 10)
                upstream.write(head)
                await upstream.drain()
                response_started = True
                tasks = [asyncio.create_task(relay(reader, upstream)), asyncio.create_task(relay(back, writer))]
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
        except (ValueError, json.JSONDecodeError) as error:
            if not response_started:
                await self.reply(writer, 400, {'error': {'message': str(error)}})
        except (OSError, asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError):
            if not response_started:
                await self.reply(writer, 503, {'error': {'message': 'chat upstream unavailable'}})
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


async def main(args):
    bridge = Bridge(json.loads(Path(args.config).read_text()), args.backend)
    server = await asyncio.start_server(bridge.client, '127.0.0.1', args.port)
    async with server:
        await server.serve_forever()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--port', type=int, default=18193)
    parser.add_argument('--backend', type=int, default=8190)
    asyncio.run(main(parser.parse_args()))
