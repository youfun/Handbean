package com.example.handbean_probe.attachments

/** Pure lifecycle state for the single Android CreateDocument result slot. */
class SaveResultSlot {
    sealed class State {
        object Empty : State()
        data class Pending(val requestId: String) : State()
        data class Dispatching(val requestId: String) : State()
        data class Accepted(val requestId: String) : State()
        data class Unknown(val requestId: String) : State()
    }

    private var state: State = State.Empty

    @Synchronized
    fun reserve(requestId: String): Boolean {
        if (requestId.isBlank() || state !is State.Empty) return false
        state = State.Pending(requestId)
        return true
    }

    @Synchronized
    fun beginDispatch(requestId: String): Boolean {
        if (state != State.Pending(requestId)) return false
        state = State.Dispatching(requestId)
        return true
    }

    @Synchronized
    fun accepted(requestId: String): Boolean {
        if (state != State.Dispatching(requestId)) return false
        state = State.Accepted(requestId)
        return true
    }

    /** Cancellation after dispatch leaves a tombstone because Android still owes a result. */
    @Synchronized
    fun cancel(requestId: String): Boolean = when (state) {
        State.Pending(requestId) -> {
            state = State.Empty
            false
        }
        State.Dispatching(requestId), State.Accepted(requestId) -> {
            state = State.Unknown(requestId)
            true
        }
        else -> false
    }

    @Synchronized
    fun consume(callbackRequestId: String?): String? {
        val current = state
        val expected = when (current) {
            is State.Accepted -> current.requestId
            is State.Unknown -> current.requestId
            else -> return null
        }
        if (callbackRequestId != expected) return null
        state = State.Empty
        return expected
    }

    @Synchronized
    fun requestId(): String? = when (val current = state) {
        is State.Pending -> current.requestId
        is State.Dispatching -> current.requestId
        is State.Accepted -> current.requestId
        is State.Unknown -> current.requestId
        State.Empty -> null
    }

    @Synchronized
    fun clearAfterActivityFinish() {
        state = State.Empty
    }
}

object PlatformCancelCommand {
    fun targetRequestId(commandRequestId: String, payloadTarget: String?): String? {
        val target = payloadTarget?.trim().orEmpty()
        if (target.isEmpty() || target == commandRequestId) return null
        return target
    }
}

class RequestCompletion {
    sealed class State {
        object Pending : State()
        object Finished : State()
    }

    private var state: State = State.Pending

    @Synchronized
    fun finishOnce(): Boolean {
        if (state is State.Finished) return false
        state = State.Finished
        return true
    }
}
