"""Bounded integrity checks for generated PNGs; no optional imaging dependency."""
import struct
import zlib

MAX_BYTES = 32 * 1024 * 1024

# Keep the public waiter longer than the bridge's complete repair operation.
# A download may consume the total budget plus its final blocked socket read.
PNG_RECOVERY_DOWNLOAD_TIMEOUT = 3
PNG_RECOVERY_DOWNLOAD_BUDGET = 6
PNG_RECOVERY_BRIDGE_TIMEOUT = 10
PNG_RECOVERY_PUBLIC_TIMEOUT = 12


def validate_png(data):
    if len(data) > MAX_BYTES or data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('invalid PNG signature or size')
    offset = 8
    header = None
    compressed = []
    palette = False
    idat_ended = False
    ended = False
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError('truncated PNG chunk')
        length = struct.unpack_from('>I', data, offset)[0]
        end = offset + 12 + length
        if end > len(data):
            raise ValueError('truncated PNG chunk data')
        tag = data[offset + 4:offset + 8]
        payload = memoryview(data)[offset + 8:offset + 8 + length]
        crc = struct.unpack_from('>I', data, offset + 8 + length)[0]
        if zlib.crc32(payload, zlib.crc32(tag)) & 0xffffffff != crc:
            raise ValueError('PNG chunk CRC mismatch')
        if header is None and tag != b'IHDR':
            raise ValueError('PNG header must be first')
        if tag == b'IHDR':
            if header is not None or length != 13:
                raise ValueError('invalid PNG header')
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', payload)
            depths = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8), 4: (8, 16), 6: (8, 16)}
            if not (0 < width <= 2752 and 0 < height <= 2752 and width * height <= 4300800):
                raise ValueError('PNG dimensions exceed image limits')
            if color not in depths or depth not in depths[color] or compression or filtering or interlace not in (0, 1):
                raise ValueError('invalid PNG format')
            header = (width, height, depth, color, interlace)
        elif tag == b'PLTE':
            if palette or compressed or not length or length % 3 or length > 768 or header[3] in (0, 4):
                raise ValueError('invalid PNG palette')
            if header[3] == 3 and length // 3 > 1 << header[2]:
                raise ValueError('PNG palette exceeds bit depth')
            palette = True
        elif tag == b'IDAT':
            if idat_ended or header[3] == 3 and not palette:
                raise ValueError('invalid PNG image chunk order')
            compressed.append(payload)
        elif tag == b'IEND':
            if length or not compressed or end != len(data):
                raise ValueError('invalid PNG end')
            ended = True
            break
        elif not tag or not tag[0] & 32:
            raise ValueError('unsupported critical PNG chunk')
        if tag != b'IDAT' and compressed:
            idat_ended = True
        offset = end
    if not ended:
        raise ValueError('PNG end missing')
    width, height, depth, color, interlace = header
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]
    passes = [(0, 0, 1, 1)] if not interlace else [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
    rows = []
    for x, y, dx, dy in passes:
        w, h = max(0, (width - x + dx - 1) // dx), max(0, (height - y + dy - 1) // dy)
        if w and h:
            rows.append(((w * channels * depth + 7) // 8, h))
    expected = sum((stride + 1) * count for stride, count in rows)
    raw = bytearray()
    stream = zlib.decompressobj()
    try:
        for block in compressed:
            raw.extend(stream.decompress(block, expected - len(raw) + 1))
            if len(raw) > expected or stream.unconsumed_tail or stream.unused_data:
                raise ValueError('PNG image data exceeds expected size')
    except zlib.error as error:
        raise ValueError('invalid PNG compressed data') from error
    if not stream.eof or len(raw) != expected:
        raise ValueError('incomplete PNG image data')
    position = 0
    for stride, count in rows:
        for _ in range(count):
            if raw[position] > 4:
                raise ValueError('invalid PNG row filter')
            position += stride + 1
    return width, height
