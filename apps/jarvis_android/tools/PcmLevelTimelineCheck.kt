package ai.jarvis.app.android

import kotlin.math.abs

fun main() {
    val levels = PcmLevelTimeline()
    val pcm = ByteArray(1920) { index -> if (index >= 960 && index % 2 == 1) 64 else 0 }
    levels.append(pcm, 0, pcm.size, 1000, 24000)
    check(levels.levelAt(999) == 0.0) // Not started: queued future sound is not visible yet.
    check(levels.levelAt(1000) == 0.0)
    check(levels.levelAt(1479) == 0.0)
    check(abs(levels.levelAt(1480) - .5) < .00001)
    check(levels.levelAt(1960) == 0.0) // Drained playback returns to silence.
    levels.clear()
    levels.append(pcm, 960, 960, 0, 24000) // A partial nonblocking write uses its actual offset.
    check(abs(levels.levelAt(0) - .5) < .00001)
    levels.clear()
    check(levels.levelAt(0) == 0.0) // Interrupted audio cannot survive clear().
    val negative = ByteArray(960) { index -> if (index % 2 == 1) (-128).toByte() else 0 }
    levels.append(negative, 0, 960, 0, 24000)
    check(abs(levels.levelAt(0) - 1.0) < .00001)
    println("PASS: hardware playhead timing, silence, partial writes, signed PCM, drain and clear")
}
