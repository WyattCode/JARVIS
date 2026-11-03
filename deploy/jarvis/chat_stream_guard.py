"""Validate streamed chat completions without holding any visible output for the full reply."""
import asyncio
import json
import time


class SpeechVisibility:
    """Mirror voice/chunker.zig ThinkFilter + Lead for the publication decision.

    Original SSE data is preserved; this detector only decides when it contains
    text the voice service will retain, including tags split across deltas.
    """
    def __init__(self):
        self.inside = False
        self.think_tail = ''
        self.lead = ''
        self.deciding = True

    @staticmethod
    def prefix(text, tag):
        for n in range(min(len(text), len(tag)-1), 0, -1):
            if text.endswith(tag[:n]):return n
        return 0

    def think(self, text, last=False):
        buf = self.think_tail + text
        self.think_tail = ''
        out = []
        while buf:
            tag = '</think>' if self.inside else '<think>'
            pos = buf.find(tag)
            if pos >= 0:
                if not self.inside:out.append(buf[:pos])
                self.inside = not self.inside
                buf = buf[pos+len(tag):]
                continue
            keep = 0 if last else self.prefix(buf, tag)
            if not self.inside:out.append(buf[:len(buf)-keep] if keep else buf)
            if keep:self.think_tail = buf[-keep:]
            break
        return ''.join(out)

    @staticmethod
    def settled(text):
        # Zig's Lead uses ASCII punctuation and byte positions, not CJK stops.
        for i, char in enumerate(text):
            if char not in '.!?\n,;:':continue
            rest = text[i+1:]
            if char != '\n' and (not rest or rest[0] not in ' \t\r\n\x0b\x0c'):continue
            if char in ',;:' and len(text[:i+1].encode()) < 24:continue
            rest = rest.lstrip(' \t\r\n\x0b\x0c')
            return bool(rest) and not '</think>'.startswith(rest[:8])
        return False

    def feed(self, text='', last=False):
        self.lead += self.think(text, last)
        if self.deciding:
            pos = self.lead.find('</think>')
            if pos >= 0:
                self.deciding = False
                self.lead = self.lead[pos+8:].lstrip(' \t\r\n\x0b\x0c')
            elif not last and len(self.lead.encode()) < 240 and not self.settled(self.lead):
                return ''
            else:self.deciding = False
        # After the initial decision Zig removes stray closing tags, retaining
        # a possible partial closing tag until the next delta.
        text = self.lead.replace('</think>', '')
        keep = 0 if last else self.prefix(text, '</think>')
        self.lead = text[-keep:] if keep else ''
        return text[:-keep] if keep else text


ASCII_SPACE = b' \t\r\n\x0b\x0c'


def speakable(text):
    """Byte-for-byte equivalent of chunker.zig speakable; used only for detection."""
    data = text.encode()
    out = bytearray()
    i, line_start, link_end = 0, True, None
    while i < len(data):
        if line_start:
            while i < len(data) and data[i] in b' \t':i += 1
            j = i
            while j < len(data) and data[j] == ord('#'):j += 1
            if j > i:
                if j < len(data) and data[j] == ord(' '):i = j+1
            else:
                for marker in (b'- ', b'* ', b'+ ', '• '.encode()):
                    if data.startswith(marker, i):i += len(marker);break
            line_start = False
            continue
        if link_end and i == link_end[0]:
            i = link_end[1];link_end = None;continue
        b = data[i]
        if b in ASCII_SPACE:
            if out and out[-1] != ord(' '):out.append(ord(' '))
            line_start = b == ord('\n');i += 1
        elif b == ord('`'):i += 1
        elif b in b'*_':
            j = i
            while j < len(data) and data[j] == b:j += 1
            prev = data[i-1] if i else ord(' ')
            after = data[j] if j < len(data) else ord(' ')
            alnum = lambda x: 48 <= x <= 57 or 65 <= x <= 90 or 97 <= x <= 122
            keep = prev in ASCII_SPACE and after in ASCII_SPACE if b == ord('*') else alnum(prev) and alnum(after)
            if keep:out.extend(data[i:j])
            i = j
        elif (b == ord('[') or b == ord('!') and data[i:i+2] == b'![') and link_end is None:
            opening = i+1 if b == ord('!') else i
            k = opening+1
            while k < len(data) and data[k] not in b'[]\n':k += 1
            valid = k > opening+1 and data[k:k+2] == b']('
            end = k+2
            if valid:
                while end < len(data) and data[end] != ord(')') and data[end] not in ASCII_SPACE:end += 1
                valid = end < len(data) and data[end] == ord(')')
            if valid:link_end = (k, end+1);i = opening+1
            else:out.append(b);i += 1
        else:out.append(b);i += 1
    return out.rstrip(b' ').decode()


class SpeechChunks:
    """Match the native chunk boundaries before applying markdown cleanup."""
    def __init__(self):
        self.pending = ''
        self.emitted = 0

    def boundary(self):
        text = self.pending
        clause = space = None
        for i, char in enumerate(text):
            if i == 280:return clause if clause is not None else space if space is not None else i
            if char == '\n':
                if not self.emitted or i >= 40:return i
                space = i
            elif char in '.!?…。！？':
                cjk = char in '。！？'
                j = i+1
                if not cjk:
                    while j < len(text) and text[j] in '.!?…':j += 1
                run_end = j
                while j < len(text) and text[j] in '\"\')]*_”’」』）':j += 1
                if j >= len(text):return None
                end = cjk or text[j] in ASCII_SPACE.decode()
                before = text[:i]
                k = len(before)
                while k and (before[k-1] == '.' or before[k-1].isascii() and before[k-1].isalpha()):k -= 1
                word = before[k:]
                abbr = len(word) == 1 and word.isascii() and word.isalpha() or word.lower() in ('mr','mrs','ms','dr','st','prof','sr','jr','vs','etc','e.g','i.e')
                if end and not (run_end == i+1 and char == '.' and abbr) and j <= 280 and (not self.emitted or j >= 40):return j
            elif char in ',;:' and i+1 < len(text) and text[i+1] in ASCII_SPACE.decode():
                clause = i+1
                if not self.emitted and i+1 >= 24:return i+1
            elif char in ASCII_SPACE.decode():space = i
        return None

    def feed(self, text, last=False):
        self.pending += text
        result = []
        while True:
            self.pending = self.pending.lstrip(ASCII_SPACE.decode())
            end = self.boundary() if self.pending else None
            if end is None:break
            result.append(self.pending[:end].rstrip(ASCII_SPACE.decode()))
            self.pending = self.pending[end:]
            self.emitted += 1
        if last:
            rest = self.pending.strip(ASCII_SPACE.decode())
            self.pending = ''
            if rest:result.append(rest);self.emitted += 1
        return result


class SpeechContent:
    def __init__(self):
        self.visible = SpeechVisibility()
        self.chunks = SpeechChunks()

    def feed(self, text='', last=False):
        chunks = self.chunks.feed(self.visible.feed(text, last), last)
        return any(speakable(chunk) for chunk in chunks)


def validated_choices(value):
    if not isinstance(value, dict) or 'error' in value:raise OSError('invalid chat stream event')
    choices = value.get('choices', [])
    if not isinstance(choices, list):raise OSError('chat choices must be an array')
    def index(x):return isinstance(x, int) and not isinstance(x, bool) and 0 <= x <= 1024
    def optional_string(obj, field):
        if obj.get(field) is not None and not isinstance(obj[field], str):raise OSError('invalid chat '+field)
    for choice in choices:
        if not isinstance(choice, dict) or not index(choice.get('index', 0)):raise OSError('invalid chat choice')
        optional_string(choice, 'finish_reason')
        delta = choice.get('delta', {})
        if not isinstance(delta, dict):raise OSError('invalid chat delta')
        optional_string(delta, 'content')
        calls = delta.get('tool_calls')
        if calls is not None:
            if not isinstance(calls, list):raise OSError('invalid tool calls')
            for call in calls:
                if not isinstance(call, dict) or not index(call.get('index', 0)) or call.get('index', 0) > 64:raise OSError('invalid tool call')
                optional_string(call, 'id');optional_string(call, 'type')
                function = call.get('function')
                if function is not None:
                    if not isinstance(function, dict):raise OSError('invalid tool function')
                    optional_string(function, 'name');optional_string(function, 'arguments')
    return choices


async def entity_lines(reader, headers):
    """Decode HTTP framing, then yield bounded SSE lines (including newlines)."""
    pending = bytearray()
    async def blocks():
        if headers.get(b'transfer-encoding', b'').lower() == b'chunked':
            while True:
                raw = await asyncio.wait_for(reader.readline(), 60)
                if not raw.endswith(b'\r\n'):
                    raise OSError('incomplete HTTP chunk size')
                size = int(raw.split(b';', 1)[0].strip(), 16)
                if size < 0 or size > 32*1024*1024:
                    raise OSError('HTTP chunk too large')
                if size == 0:
                    while True:
                        trailer = await asyncio.wait_for(reader.readline(), 60)
                        if trailer == b'\r\n':break
                        if not trailer:raise OSError('incomplete HTTP trailers')
                    return
                remaining = size
                while remaining:
                    data = await asyncio.wait_for(reader.read(min(65536, remaining)), 60)
                    if not data:raise asyncio.IncompleteReadError(b'', remaining)
                    remaining -= len(data)
                    yield data
                if await asyncio.wait_for(reader.readexactly(2), 60) != b'\r\n':
                    raise OSError('invalid HTTP chunk ending')
        elif b'content-length' in headers:
            remaining = int(headers[b'content-length'])
            if remaining < 0:raise OSError('invalid content length')
            while remaining:
                data = await asyncio.wait_for(reader.read(min(65536, remaining)), 60)
                if not data:raise asyncio.IncompleteReadError(b'', remaining)
                remaining -= len(data)
                yield data
        else:
            while True:
                data = await asyncio.wait_for(reader.read(65536), 60)
                if not data:return
                yield data
    async for data in blocks():
        pending.extend(data)
        while True:
            pos = pending.find(b'\n')
            if pos < 0:break
            if pos > 1024*1024:raise OSError('SSE line too large')
            line = bytes(pending[:pos+1]);del pending[:pos+1]
            yield line
        if len(pending)>1024*1024:raise OSError('SSE line too large')
    if pending:yield bytes(pending)


async def guarded_stream(reader, headers, publish, entry, policy=None):
    """publish(headers/body bytes) only on visible text or a tool call; False means a clean empty completion.

    Never retry after publishing a tool call or text. Broken streams are failures,
    not empty completions. Reasoning-only output is not a speakable reply.
    """
    buffered = bytearray()
    committed = False
    ended = False
    finish = None
    visibility = {}

    async def commit():
        nonlocal committed
        committed = True
        entry['first_visible_ms'] = round((time.monotonic()-entry['_started'])*1000)
        entry['published'] = True
        await publish(bytes(buffered))
        buffered.clear()
    lines = entity_lines(reader, headers)
    if policy is not None:lines = policy.lines(lines)
    async for line in lines:
        was_committed = committed
        if not committed:
            buffered.extend(line)
            if len(buffered)>1024*1024:raise OSError('chat prelude too large')
        if not line.startswith(b'data:'):
            if committed:await publish(line)
            continue
        data = line[5:].strip()
        if data == b'[DONE]':
            if not committed and any(detector.feed(last=True) for detector in visibility.values()):
                await commit()
            if was_committed:await publish(line)
            if committed:await publish(b'\n')  # complete the final SSE event for browser parsers
            ended = True
            break
        try:value=json.loads(data)
        except (ValueError, UnicodeError):raise OSError('invalid chat stream event')
        choices = validated_choices(value)
        if was_committed:await publish(line)
        for choice in choices:
            delta = choice.get('delta') or {}
            if choice.get('finish_reason') is not None:finish=choice['finish_reason']
            text=delta.get('content')
            detector = visibility.setdefault(choice.get('index', 0), SpeechContent())
            visible = detector.feed(text) if isinstance(text, str) else False
            if not committed and (visible or delta.get('tool_calls')):
                await commit()
    if not ended:raise OSError('chat stream ended without DONE')
    if not committed and finish not in ('stop', 'length'):
        raise OSError('chat stream has no completed answer')
    return committed
