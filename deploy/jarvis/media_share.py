"""Persistent, file-scoped public HTTPS capabilities. No model/API access is shared."""
import asyncio
import hashlib
import hmac
import json
import mimetypes
import os
from pathlib import Path
import re
import secrets
import urllib.parse

JOB = r'(?:img|image|video)_[0-9a-f]{8,32}'
FILE = r'(?:image-\d+|\d+)\.png|video\.mp4'


class MediaShare:
    def __init__(self, filename, hostname):
        cfg = json.loads(Path(filename).read_text())
        self.origin = 'https://' + hostname
        self.hostname = hostname
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

    async def serve(self, writer, method, target, headers):
        # Return 404 for invalid capabilities, without disclosing file existence.
        status = 404
        response_started = False
        try:
            file = self.locate(self.canonical(target))
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
