"""Fixed CPU effects after raw voice validation; identical for files and streams."""
import subprocess
import threading
import socket
import os

FFMPEG = os.environ.get('JARVIS_FFMPEG', 'ffmpeg')
COMMON = 'highpass=f=70,lowpass=f=11000,equalizer=f=240:t=q:w=0.8:g=1.5,equalizer=f=2700:t=q:w=0.8:g=2,acompressor=threshold=0.18:ratio=2:attack=8:release=100:makeup=1.2'
PRESETS = {
    'sterling': COMMON + ',rubberband=pitch=0.99:tempo=1.01',
    'nexus': COMMON + ',rubberband=pitch=0.95:tempo=0.99,aecho=0.9:0.95:7|13:0.055|0.035',
    'titan': COMMON + ',rubberband=pitch=0.89:tempo=0.97,aecho=0.9:0.95:6|11|17:0.13|0.09|0.06,equalizer=f=1100:t=q:w=1:g=2',
}


def command(voice, rate=None):
    args = [FFMPEG, '-nostdin', '-hide_banner', '-loglevel', 'error']
    if rate is not None:
        if not 16000 <= rate <= 96000:
            raise ValueError('invalid effect sample rate')
        args += ['-f', 's16le', '-ar', str(rate), '-ac', '1', '-blocksize', '4096']
    args += ['-i', 'pipe:0', '-af', PRESETS[voice] + ',alimiter=limit=0.89:level=false']
    args += ['-ar', str(rate or 44100), '-ac', '1', '-c:a', 'pcm_s16le', '-f', 's16le' if rate else 'wav', 'pipe:1']
    return args


def file_audio(data, voice):
    if voice not in PRESETS:
        return data
    result = subprocess.run(command(voice), input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, timeout=120, check=True)
    # A pipe's WAV header has unknown lengths. Rebuild a canonical header.
    import io
    import wave
    from drama3_worker import wav_header
    with wave.open(io.BytesIO(result.stdout), 'rb') as wav:
        pcm = wav.readframes(wav.getnframes())
        rate = wav.getframerate()
    return wav_header(rate, len(pcm)) + pcm


class EffectResponse:
    def __init__(self, response, voice):
        self.response = response
        self.voice = voice

    def __getattr__(self, key):
        return getattr(self.response, key)

    def close(self):
        self.response.close()

    def chunks(self):
        rate = int(self.headers.get('x-sample-rate', '0'))
        process = subprocess.Popen(command(self.voice, rate), stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        errors = []

        def feed():
            try:
                for block in self.response.chunks():
                    view = memoryview(block)
                    while view:
                        n = process.stdin.write(view)
                        if not n:
                            raise OSError('audio effect input closed')
                        view = view[n:]
            except BaseException as error:
                errors.append(error)
            finally:
                try:
                    process.stdin.close()
                except OSError:
                    pass

        worker = threading.Thread(target=feed, daemon=True)
        worker.start()
        try:
            pending = b''
            while True:
                block = process.stdout.read(8192)
                if not block:
                    break
                pending += block
                size = len(pending) & ~1
                if size:
                    yield pending[:size]
                    pending = pending[size:]
            if pending:
                raise RuntimeError('audio effect ended inside a PCM sample')
            worker.join(timeout=5)
            if worker.is_alive():
                raise RuntimeError('audio effect input did not finish')
            if errors:
                raise RuntimeError('audio effect upstream failed') from errors[0]
            if process.wait(timeout=5):
                raise RuntimeError('audio effect processing failed')
        finally:
            if process.poll() is None:
                process.kill()
            # Unblock a feeder reading a silent/stalled upstream before closing
            # its buffered file (which otherwise waits for the reader's lock).
            sock = getattr(self.response, 'sock', None)
            if worker.is_alive() and sock is not None:
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            self.response.close()
            process.wait(timeout=5)
            worker.join(timeout=5)
            process.stdout.close()


def stream_audio(response, voice):
    return EffectResponse(response, voice) if voice in PRESETS else response
