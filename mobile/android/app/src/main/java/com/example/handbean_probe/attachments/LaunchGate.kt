package com.example.handbean_probe.attachments

import java.util.concurrent.atomic.AtomicReference

enum class LaunchPhase {
    PENDING,
    DISPATCHING,
    LAUNCHED,
    CANCELLED,
}

class LaunchGate {
    private val phase = AtomicReference(LaunchPhase.PENDING)

    fun phase(): LaunchPhase = phase.get()

    fun cancelBeforeLaunch(): Boolean =
        phase.compareAndSet(LaunchPhase.PENDING, LaunchPhase.CANCELLED)

    fun beginDispatch(): Boolean =
        phase.compareAndSet(LaunchPhase.PENDING, LaunchPhase.DISPATCHING)

    fun markLaunched(): Boolean =
        phase.compareAndSet(LaunchPhase.DISPATCHING, LaunchPhase.LAUNCHED)
}
