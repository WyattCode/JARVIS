package cc.odn.jarvis_android

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicInteger

/** One stream, one epoch. Writes never block the UI and old audio cannot survive clear(). */
class PcmPlayer(private val event: (Map<String, Any>) -> Unit) {
    private data class Chunk(val epoch: Int, val bytes: ByteArray)
    private val lock = Any()
    private val queue = LinkedBlockingQueue<Chunk>(300)
    private val pendingBytes = AtomicInteger(0)
    private val main = Handler(Looper.getMainLooper())
    private var track: AudioTrack? = null
    @Volatile private var epoch = 0
    @Volatile private var alive = true
    private val levels = PcmLevelTimeline()
    private var submitted = 0L
    private var rate = 24000
    @Volatile private var lastActive = false
    private val worker = Thread({ work() }, "jarvis-pcm-output").apply { start() }

    fun configure(sampleRate: Int, generation: Int) {
        require(sampleRate in 8000..192000)
        synchronized(lock) {
            epoch = generation; queue.clear(); pendingBytes.set(0)
            held = false
            track?.pause(); track?.flush(); track?.release(); track = null
            rate = sampleRate; submitted = 0; levels.clear()
            val min = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
            require(min > 0)
            track = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setAudioFormat(AudioFormat.Builder().setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setBufferSizeInBytes(maxOf(min, rate / 5)).setTransferMode(AudioTrack.MODE_STREAM).build()
                .also { require(it.state == AudioTrack.STATE_INITIALIZED); it.play() }
        }
        publish()
    }
    fun feed(generation: Int, bytes: ByteArray) {
        require(bytes.size % 2 == 0)
        if (bytes.isEmpty() || generation != epoch || !alive) return
        // Small bounded chunks keep cancellation responsive and provide real backpressure.
        var offset = 0
        while (offset < bytes.size && generation == epoch && alive) {
            val end = minOf(offset + 4800, bytes.size)
            val part = bytes.copyOfRange(offset, end)
            while (alive && generation == epoch) {
                val added = synchronized(lock) {
                    if (generation != epoch) return
                    pendingBytes.addAndGet(part.size)
                    if (queue.offer(Chunk(generation, part))) true else { pendingBytes.addAndGet(-part.size); false }
                }
                if (added) break
                Thread.sleep(8)
            }
            offset = end
        }
    }
    fun clear(generation: Int) {
        synchronized(lock) {
            epoch = generation; queue.clear(); pendingBytes.set(0); submitted = 0; levels.clear()
            held = false
            track?.pause(); track?.flush(); track?.play()
        }
        publish()
    }
    /** A held voice stays where it is (its samples wait in the track) and goes on from the same sample. */
    @Volatile private var held = false
    fun setPaused(paused: Boolean) {
        synchronized(lock) {
            held = paused
            val t = track ?: return
            if (paused) t.pause() else t.play()
        }
        publish()
    }
    fun stop() {
        synchronized(lock) {
            epoch++; queue.clear(); pendingBytes.set(0); submitted = 0; levels.clear()
            held = false
            track?.pause(); track?.flush(); track?.release(); track = null
        }
        publish()
    }
    fun close() { alive = false; worker.interrupt(); stop(); main.removeCallbacksAndMessages(null) }
    private fun work() {
        var lastReport = 0L
        while (alive) {
            try {
                val stillPlaying = synchronized(lock) { val played = (track?.playbackHeadPosition?.toLong() ?: 0L) and 0xffffffffL; track != null && submitted > played }
                // Publish the hardware drain BEFORE parking; otherwise short replies/voice
                // previews never emit their final inactive event until another chunk arrives.
                if (!stillPlaying && lastActive) publish()
                val chunk = if (stillPlaying) queue.poll(30, java.util.concurrent.TimeUnit.MILLISECONDS) else queue.take()
                if (chunk != null) {
                    var offset = 0
                    while (offset < chunk.bytes.size && alive) {
                        val written = synchronized(lock) {
                            if (chunk.epoch != epoch || track == null) -1 else {
                                val n = track!!.write(chunk.bytes, offset, chunk.bytes.size - offset, AudioTrack.WRITE_NON_BLOCKING)
                                if (n > 0) { levels.append(chunk.bytes, offset, n, submitted, rate); submitted += n / 2; pendingBytes.addAndGet(-n) }
                                n
                            }
                        }
                        if (written < 0) {
                            val failed = synchronized(lock) { chunk.epoch == epoch && track != null }
                            if (failed) {
                                stop()
                                main.post { event(mapOf("type" to "output_error")) }
                            }
                            break
                        }
                        if (written == 0) Thread.sleep(5) else offset += written
                    }
                }
                val now = android.os.SystemClock.elapsedRealtime()
                if (now - lastReport >= 80) { lastReport = now; publish() }
            } catch (_: InterruptedException) { if (!alive) return }
              catch (_: Exception) { stop(); main.post { event(mapOf("type" to "output_error")) } }
        }
    }
    private fun publish() {
        val data = synchronized(lock) {
            val played = (track?.playbackHeadPosition?.toLong() ?: 0L) and 0xffffffffL
            val frames = maxOf(0L, submitted - played) + maxOf(0, pendingBytes.get()) / 2
            val active = track != null && frames > 0
            // Report transitions and occupancy, based on the hardware playhead, not just queue emptiness.
            lastActive = active
            mapOf("type" to "playback", "active" to active, "buffered_frames" to frames, "sample_rate" to rate,
                "epoch" to epoch, "written_frames" to submitted, "played_frames" to played,
                "underruns" to (track?.underrunCount ?: 0),
                "monotonic_ms" to android.os.SystemClock.elapsedRealtime(),
                "rms" to if (active) levels.levelAt(played) else 0.0)
        }
        main.post { event(data) }
    }
}
