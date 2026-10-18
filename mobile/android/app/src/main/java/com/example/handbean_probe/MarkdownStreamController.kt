package com.example.handbean_probe

import java.util.regex.Pattern
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

internal data class MarkdownStreamConfig(
    val startDelayMs: Long = 80,
    val maxCommitFps: Int = 30,
    val minGraphemesPerSecond: Double = 40.0,
    val maxGraphemesPerSecond: Double = 1_000.0,
    val targetLatencyMs: Double = 900.0,
    val catchUpLatencyMs: Double = 350.0,
    val catchUpThreshold: Int = 600,
    val maxGraphemesPerCommit: Int = 80,
)

/**
 * Presentation-only pacing for one assistant message. The received source is
 * never changed; only [visible] is advanced, at grapheme boundaries.
 */
internal class MarkdownStreamController(
    private val config: MarkdownStreamConfig = MarkdownStreamConfig(),
) {
    var received: String = ""
        private set
    var visible: String = ""
        private set
    var streaming: Boolean = false
        private set

    private var startedAtMs = 0L
    private var lastCommitMs = 0L
    private var budget = 0.0
    private var currentRate = config.minGraphemesPerSecond

    fun update(source: String, isStreaming: Boolean, nowMs: Long): String {
        if (!isStreaming) {
            received = source
            visible = source
            streaming = false
            resetTiming(nowMs)
            return visible
        }

        if (!streaming || !source.startsWith(received)) {
            received = source
            visible = ""
            streaming = true
            resetTiming(nowMs)
            return visible
        }

        if (source != received) {
            val wasCaughtUp = visible == received
            val hadContent = received.isNotEmpty()
            received = source
            // Resume an already-started stream without another 80 ms delay,
            // but retain lastCommitMs so sparse one-character deltas cannot
            // bypass the global commit-rate cap.
            if (wasCaughtUp && hadContent) {
                startedAtMs = nowMs - config.startDelayMs
            } else if (!hadContent) {
                resetTiming(nowMs)
            }
        }
        return visible
    }

    fun tick(nowMs: Long): String {
        if (!streaming || visible == received || nowMs - startedAtMs < config.startDelayMs) {
            return visible
        }

        val minimumFrameMs = max(1L, 1_000L / max(1, config.maxCommitFps))
        val elapsedMs = min(100L, max(0L, nowMs - lastCommitMs))
        if (elapsedMs < minimumFrameMs) return visible

        lastCommitMs = nowMs
        val pending = received.length - visible.length
        val latency = if (pending > config.catchUpThreshold) config.catchUpLatencyMs else config.targetLatencyMs
        val targetRate = (pending / max(1.0, latency / 1_000.0))
            .coerceIn(config.minGraphemesPerSecond, config.maxGraphemesPerSecond)
        currentRate += (targetRate - currentRate) * 0.2
        budget += currentRate * elapsedMs / 1_000.0

        val count = min(floor(budget).toInt(), config.maxGraphemesPerCommit)
        if (count <= 0) return visible

        val end = Graphemes.endAfter(received, visible.length, count)
        if (end > visible.length) {
            visible = received.substring(0, end)
            budget = max(0.0, budget - count)
        }
        return visible
    }

    fun flush(): String {
        visible = received
        return visible
    }

    fun hasPending(): Boolean = streaming && visible != received

    private fun resetTiming(nowMs: Long, preserveRate: Boolean = false) {
        startedAtMs = nowMs
        lastCommitMs = nowMs
        budget = 0.0
        if (!preserveRate) currentRate = config.minGraphemesPerSecond
    }
}

private object Graphemes {
    // Java 9+ and Android's ICU-backed regex both implement \X as an extended
    // grapheme cluster, including combining marks and emoji ZWJ sequences.
    private val pattern = Pattern.compile("\\X")

    fun endAfter(source: String, start: Int, count: Int): Int {
        if (start >= source.length || count <= 0) return start
        val matcher = pattern.matcher(source)
        matcher.region(start, source.length)
        var end = start
        repeat(count) {
            if (!matcher.find()) return end
            end = matcher.end()
        }
        return end
    }
}
