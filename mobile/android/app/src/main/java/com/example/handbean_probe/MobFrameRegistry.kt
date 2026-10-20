package com.example.handbean_probe

import java.util.concurrent.ConcurrentHashMap

/** The single generation gate and coordinate store for MobBridge's rendered tree. */
internal class MobFrameRegistry {
    private val lock = Any()
    private var generation = 1L
    private val framesById = ConcurrentHashMap<String, FloatArray>()

    // Automation keeps its existing weakly consistent iteration from the NIF thread.
    val frames: Map<String, FloatArray> get() = framesById

    fun currentGeneration(): Long = synchronized(lock) { generation }

    fun record(id: String, generation: Long, x: Float, y: Float, w: Float, h: Float) {
        synchronized(lock) {
            if (generation < this.generation) return
            framesById[id] = floatArrayOf(x, y, w, h)
        }
    }

    // Check/write and bump/clear must take the same monitor: ordering alone
    // allows an outgoing layout to repopulate the map after a navigation clear.
    // MobBridge calls this in the same branch that advances navKey, before
    // publishing the incoming root. Trackers capture again on that slot epoch.
    fun advanceNavigation() {
        synchronized(lock) {
            generation++
            framesById.clear()
        }
    }

    // Same-screen removed ids and offscreen lazy rows retain their last frame,
    // as before. This registry does not add an id purge or an onDispose policy.
}
