"""Small JSON HTTP client with bounded framing, size and whole-request lifetime."""
import asyncio
import json
import ssl
import urllib.parse

DEFAULT_MAX_BYTES = 4 * 1024 * 1024


class BoundedHTTPError(OSError):
    pass


async def read_json_response(reader, head, *, timeout=15, max_bytes=DEFAULT_MAX_BYTES):
    """Read an already received response head and its JSON body; never follow redirects."""
    try:
        async with asyncio.timeout(timeout):
            if len(head) > 65536 or not head.endswith(b'\r\n\r\n'):
                raise ValueError('invalid upstream response head')
            lines = head[:-4].split(b'\r\n')
            version, code, *_ = lines[0].split(b' ')
            if version not in (b'HTTP/1.0', b'HTTP/1.1') or not code.isdigit():
                raise ValueError('invalid upstream status')
            if not 200 <= int(code) < 300:
                raise BoundedHTTPError('upstream HTTP '+code.decode('ascii'))
            headers = {}
            for line in lines[1:]:
                key, sep, value = line.partition(b':')
                if not sep or not key or key.strip() != key:
                    raise ValueError('invalid upstream header')
                key = key.lower()
                if key in headers and key in (b'content-length', b'transfer-encoding', b'content-encoding'):
                    raise ValueError('ambiguous upstream framing')
                headers[key] = value.strip()
            length, transfer = headers.get(b'content-length'), headers.get(b'transfer-encoding')
            if headers.get(b'content-encoding', b'identity').lower() not in (b'', b'identity'):
                raise ValueError('unsupported upstream content encoding')
            if length is not None and transfer is not None:
                raise ValueError('ambiguous upstream framing')
            if transfer is not None:
                if transfer.lower() != b'chunked':
                    raise ValueError('unsupported upstream transfer encoding')
                data = bytearray()
                while True:
                    line = await reader.readuntil(b'\r\n')
                    token = line[:-2].split(b';', 1)[0]
                    if len(line) > 8192 or not token or any(c not in b'0123456789abcdefABCDEF' for c in token):
                        raise ValueError('invalid upstream chunk')
                    size = int(token, 16)
                    if len(data) + size > max_bytes:
                        raise ValueError('upstream response is too large')
                    if not size:
                        trailers = 0
                        while True:
                            line = await reader.readuntil(b'\r\n'); trailers += len(line)
                            if trailers > 8192:
                                raise ValueError('upstream trailers are too large')
                            if line == b'\r\n': break
                        break
                    chunk = await reader.readexactly(size + 2)
                    if chunk[-2:] != b'\r\n': raise ValueError('invalid upstream chunk terminator')
                    data.extend(chunk[:-2])
            elif length is not None:
                if not length.isdigit() or int(length) > max_bytes:
                    raise ValueError('invalid upstream content length')
                data = await reader.readexactly(int(length))
            else:
                data = bytearray()
                while chunk := await reader.read(min(65536, max_bytes + 1 - len(data))):
                    data.extend(chunk)
                    if len(data) > max_bytes: raise ValueError('upstream response is too large')
            # MCP may contain large inline image data. Parsing it must not hold
            # the event loop used by unrelated status and voice requests.
            return await asyncio.to_thread(json.loads, data)
    except (OSError, ValueError, asyncio.IncompleteReadError, asyncio.LimitOverrunError) as error:
        raise BoundedHTTPError('invalid or incomplete upstream JSON response') from error


async def request_json(url, *, method='GET', body=None, headers=None, timeout=3.0, max_bytes=DEFAULT_MAX_BYTES):
    """Fetch JSON without proxy environment variables; cancellation closes the socket."""
    writer = None
    try:
        async with asyncio.timeout(timeout):
            target = urllib.parse.urlsplit(url)
            if target.scheme not in ('http', 'https') or not target.hostname or target.username is not None or target.password is not None or target.fragment:
                raise ValueError('invalid upstream URL')
            if method not in ('GET', 'POST', 'HEAD'): raise ValueError('unsupported JSON request method')
            route = urllib.parse.urlunsplit(('', '', target.path or '/', target.query, ''))
            if any(c.isspace() for c in route): raise ValueError('invalid upstream request target')
            tls = ssl.create_default_context() if target.scheme == 'https' else None
            reader, writer = await asyncio.open_connection(target.hostname, target.port or (443 if tls else 80), ssl=tls, limit=65536)
            fields = {'Host': target.netloc, 'Connection': 'close', 'Accept-Encoding': 'identity'}
            for key, value in (headers or {}).items():
                if not isinstance(key, str) or not isinstance(value, str) or not key or any(c in key + value for c in '\r\n'):
                    raise ValueError('invalid upstream request header')
                if key.lower() in ('host', 'connection', 'content-length', 'transfer-encoding'):
                    raise ValueError('reserved upstream request header')
                fields[key] = value
            if body is not None:
                if not isinstance(body, bytes): raise ValueError('request body must be bytes')
                fields['Content-Length'] = str(len(body))
            request = method+' '+route+' HTTP/1.1\r\n'+''.join(k+': '+v+'\r\n' for k,v in fields.items())+'\r\n'
            writer.write(request.encode('latin-1') + (body or b'')); await writer.drain()
            head = await reader.readuntil(b'\r\n\r\n')
            return await read_json_response(reader, head, timeout=timeout, max_bytes=max_bytes)
    except (OSError, ValueError, asyncio.IncompleteReadError, asyncio.LimitOverrunError) as error:
        raise BoundedHTTPError('upstream JSON request failed') from error
    finally:
        if writer is not None:
            writer.close()
            # A peer cannot prolong teardown beyond the request budget. The
            # transport is already closed; do not await a TLS close handshake.
