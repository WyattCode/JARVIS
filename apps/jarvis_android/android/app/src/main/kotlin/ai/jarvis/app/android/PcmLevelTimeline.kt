package ai.jarvis.app.android

import java.util.ArrayDeque
import kotlin.math.sqrt

/** Tiny RMS envelopes indexed by submitted frames, never by download/queue arrival. */
internal class PcmLevelTimeline {
    private data class Span(val start: Long, val end: Long, val rms: Double)
    private val spans = ArrayDeque<Span>()
    fun clear() = spans.clear()
    fun append(bytes: ByteArray, offset: Int, length: Int, firstFrame: Long, rate: Int) {
        val end = offset + length
        val window = maxOf(1, rate / 50) * 2 // 20ms, constant memory independent of reply size.
        var at = offset
        while (at + 1 < end) {
            val stop = minOf(at + window, end)
            var sum = 0.0
            var i = at
            while (i + 1 < stop) {
                val sample = (((bytes[i].toInt() and 255) or (bytes[i + 1].toInt() shl 8)).toShort()).toDouble() / 32768.0
                sum += sample * sample
                i += 2
            }
            val count = (i - at) / 2
            if (count > 0) {
                val start = firstFrame + (at - offset) / 2
                spans.addLast(Span(start, start + count, sqrt(sum / count)))
            }
            at = i
        }
        while (spans.size > 600) spans.removeFirst()
    }
    fun levelAt(played: Long): Double {
        while (spans.isNotEmpty() && spans.first.end <= played) spans.removeFirst()
        val span = spans.peekFirst() ?: return 0.0
        return if (played >= span.start && played < span.end) span.rms else 0.0
    }
}
