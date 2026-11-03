"""Persistent, file-scoped public HTTPS capabilities. No model/API access is shared."""
import asyncio
import hashlib
import hmac
import http.client
import json
import mimetypes
import os
from pathlib import Path
import re
import secrets
import sys
from functools import lru_cache
import urllib.parse
import urllib.request
import urllib.error

sys.path.append(str(Path(__file__).resolve().parent))
from png_integrity import (validate_png, MAX_BYTES as MAX_PNG_BYTES,
                           PNG_RECOVERY_BRIDGE_TIMEOUT, PNG_RECOVERY_PUBLIC_TIMEOUT)

JOB = r'(?:img|image|video)_[0-9a-f]{8,32}'
FILE = r'(?:image-\d+|\d+)\.png|video\.mp4'


def file_identity(file):
    stat=file.stat()
    return (stat.st_dev,stat.st_ino,stat.st_size,stat.st_mtime_ns,stat.st_ctime_ns)


@lru_cache(maxsize=128)
def validated_png_file(path,identity):
    file=Path(path)
    if file_identity(file)!=identity or identity[2]>MAX_PNG_BYTES:raise ValueError('cached PNG changed')
    validate_png(file.read_bytes())
    if file_identity(file)!=identity:raise ValueError('cached PNG changed during validation')
    return True


class MediaShare:
    def __init__(self, filename, hostname, recovery_port=None):
        cfg = json.loads(Path(filename).read_text())
        self.origin = 'https://' + hostname
        self.hostname = hostname
        if recovery_port is not None and (type(recovery_port) is not int or not 1<=recovery_port<=65535):raise ValueError('invalid media recovery port')
        self.recovery_port=recovery_port
        self.png_repairs={}
        self.roots = [Path(p).resolve(strict=True) for p in cfg['roots']]
        keyfile = Path(cfg['key_file'])
        keyfile.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            fd = os.open(keyfile, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            pass
        else:
            with os.fdopen(fd, 'wb') as file:
                file.write(secrets.token_bytes(32))
        if keyfile.stat().st_mode & 0o077:
            raise ValueError('media signing key must be private')
        self.key = keyfile.read_bytes()
        if len(self.key) != 32:
            raise ValueError('invalid media signing key')

    def canonical(self, value):
        if not isinstance(value, str):
            raise ValueError('media path must be a string')
        u = urllib.parse.urlsplit(value)
        if u.scheme or u.netloc:
            if u.scheme != 'https' or u.netloc != self.hostname:
                raise ValueError('only local media can be shared')
        if u.query or u.fragment:
            raise ValueError('unexpected media parameters')
        path = u.path
        shared = re.fullmatch(r'/media/([0-9a-f]{64})/('+JOB+r')/('+FILE+r')', path)
        if shared:
            relative = shared[2] + '/' + shared[3]
            if not hmac.compare_digest(self.signature(relative), shared[1]):
                raise ValueError('invalid media capability')
            return relative
        m = re.fullmatch(r'/v1/files/('+JOB+r')/('+FILE+r')', path)
        if m:
            return m[1] + '/' + m[2]
        m = re.fullmatch(r'/v1/videos/(video_[0-9a-f]{8,32})/content', path)
        if m:
            return m[1] + '/video.mp4'
        raise ValueError('only generated images and videos can be shared')

    def signature(self, relative):
        return hmac.new(self.key, relative.encode(), hashlib.sha256).hexdigest()

    def locate(self, relative):
        for root in self.roots:
            candidate = (root / relative).resolve()
            if candidate.is_relative_to(root) and candidate.is_file():
                return candidate
        raise FileNotFoundError('generated media is not available locally')

    def url(self, path):
        relative = self.canonical(path)
        self.locate(relative)
        return self.origin + '/media/' + self.signature(relative) + '/' + relative

    def checked_png(self,relative):
        # An old root may still contain a damaged copy after the bridge repaired
        # the primary cache. Prefer any valid file within the configured roots.
        for root in self.roots:
            candidate=(root/relative).resolve()
            if not candidate.is_relative_to(root) or not candidate.is_file():continue
            try:
                validated_png_file(str(candidate),file_identity(candidate))
                return candidate
            except (OSError,ValueError):continue
        raise ValueError('generated PNG is not valid locally')

    async def recover_png(self,relative):
        if not self.recovery_port:raise ValueError('media recovery is unavailable')
        async def repair():
            def request():
                url=f'http://127.0.0.1:{self.recovery_port}/v1/files/'+relative
                opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
                try:
                    with opener.open(urllib.request.Request(url,method='HEAD'),timeout=PNG_RECOVERY_BRIDGE_TIMEOUT+1) as response:
                        if response.status!=200:raise ValueError('media recovery failed')
                except urllib.error.HTTPError as error:
                    error.close()
                    raise ValueError('media recovery failed') from error
                except http.client.HTTPException as error:
                    raise ValueError('media recovery response incomplete') from error
            async with asyncio.timeout(PNG_RECOVERY_PUBLIC_TIMEOUT):
                await asyncio.to_thread(request)
                return await asyncio.to_thread(self.checked_png,relative)
        task=self.png_repairs.get(relative)
        if task is None:
            task=asyncio.create_task(repair());self.png_repairs[relative]=task
            def completed(done):
                if self.png_repairs.get(relative) is done:self.png_repairs.pop(relative,None)
                if not done.cancelled():done.exception()
            task.add_done_callback(completed)
        return await asyncio.shield(task)

    def rewrite(self, value):
        if isinstance(value, list):
            return [self.rewrite(v) for v in value]
        if isinstance(value, dict):
            return {k: self.rewrite(v) for k, v in value.items()}
        if isinstance(value, str) and value.startswith(('/v1/files/', '/v1/videos/')):
            try:
                return self.url(value)
            except (ValueError, OSError):
                pass
        return value

    def rewrite_mcp(self, value):
        """Sign structured media paths, including JSON-encoded task summaries."""
        rewritten = self.rewrite(value)
        if not isinstance(rewritten, dict):
            return rewritten
        result = rewritten.get('result')
        if not isinstance(result, dict) or not isinstance(result.get('content'), list):
            return rewritten
        def resource_url(url):
            if not isinstance(url, str):
                return url
            signed = self.rewrite(url)
            if signed != url:
                return signed
            # Audio/transcripts remain protected by personal login. Absolute
            # same-origin URLs are usable by an authenticated external client,
            # without granting these files anonymous media capabilities.
            if re.fullmatch(r'/v1/files/(?:img|image|video|speech|transcription)_[A-Za-z0-9_-]{1,64}/[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', url):
                return self.origin + url
            return url
        for item in result['content']:
            if isinstance(item, dict) and item.get('type') == 'resource_link':
                item['uri'] = resource_url(item.get('uri'))
            if not isinstance(item, dict) or item.get('type') != 'text' or not isinstance(item.get('text'), str):
                continue
            try:
                job = json.loads(item['text'])
            except (ValueError, TypeError):
                continue
            if not isinstance(job, dict) or not isinstance(job.get('id'), str) or not re.fullmatch(r'(?:img|image|video|speech|transcription)_[A-Za-z0-9_-]{1,64}', job['id']):
                continue
            # Only task resource fields have media semantics. Natural-language
            # answers, prompts, errors and unrelated JSON strings stay intact.
            changed = False
            for key in ('files', 'urls'):
                if isinstance(job.get(key), list):
                    links = [resource_url(url) for url in job[key]]
                    changed = changed or links != job[key]
                    job[key] = links
            if changed:
                item['text'] = json.dumps(job, ensure_ascii=False)
        return rewritten

    async def serve(self, writer, method, target, headers):
        # Return 404 for invalid capabilities, without disclosing file existence.
        status = 404
        response_started = False
        try:
            relative=self.canonical(target)
            file = await asyncio.to_thread(self.locate,relative)
            if file.suffix.lower()=='.png':
                try:file=await asyncio.to_thread(self.checked_png,relative)
                except (ValueError,OSError):
                    status=503
                    file=await self.recover_png(relative)
            size = file.stat().st_size
            start, end, status = 0, size - 1, 200
            extra = ''
            ranges = headers.get(b'range', [])
            if ranges:
                m = re.fullmatch(r'bytes=(\d*)-(\d*)', ranges[0]) if len(ranges) == 1 else None
                if not m or not any(m.groups()):
                    raise IndexError(size)
                if m[1]:
                    start = int(m[1]); end = min(size - 1, int(m[2])) if m[2] else size - 1
                else:
                    suffix = int(m[2]); start = max(0, size - suffix)
                    if not suffix:
                        raise IndexError(size)
                if start >= size or start > end:
                    raise IndexError(size)
                status = 206
                extra = f'Content-Range: bytes {start}-{end}/{size}\r\n'
            mime = mimetypes.guess_type(file.name)[0]
            length = max(0, end-start+1)
            response_started = True
            writer.write((f'HTTP/1.1 {status} '+('Partial Content' if status==206 else 'OK')+f'\r\nContent-Type: {mime}\r\nContent-Length: {length}\r\nAccept-Ranges: bytes\r\nContent-Disposition: inline; filename="{file.name}"\r\nCache-Control: public, max-age=3600\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nAccess-Control-Allow-Origin: *\r\n'+extra+'Connection: close\r\n\r\n').encode())
            await writer.drain()
            if method == 'HEAD':
                return
            with file.open('rb') as src:
                src.seek(start)
                remaining = length
                while remaining:
                    chunk = await asyncio.to_thread(src.read, min(65536, remaining))
                    if not chunk:
                        break
                    remaining -= len(chunk)
                    writer.write(chunk)
                    await writer.drain()
            return
        except IndexError as error:
            status = 416
            extra = f'Content-Range: bytes */{error.args[0]}\r\n'
        except (ValueError, OSError):
            if response_started:
                raise
            extra = ''
        writer.write(f'HTTP/1.1 {status} Error\r\nContent-Length: 0\r\n{extra}Cache-Control: no-store\r\nConnection: close\r\n\r\n'.encode())
        await writer.drain()
