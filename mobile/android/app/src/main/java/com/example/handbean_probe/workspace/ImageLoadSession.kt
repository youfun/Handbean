package com.example.handbean_probe.workspace

import java.util.concurrent.atomic.AtomicLong

/**
 * Generation gate for image decode. A stale bitmap that was never given to
 * Compose is recycled here. The viewer must not recycle a bitmap still
 * assigned to [androidx.compose.foundation.Image].
 */
class ImageLoadSession<T>(
    private val recycle: (T) -> Unit = {},
) {
    private val generation = AtomicLong(0)

    fun nextToken(): Long = generation.incrementAndGet()

    fun invalidate() {
        generation.incrementAndGet()
    }

    fun accept(token: Long, result: T?): T? {
        if (generation.get() != token) {
            if (result != null) recycle(result)
            return null
        }
        return result
    }

    fun currentGeneration(): Long = generation.get()
}
