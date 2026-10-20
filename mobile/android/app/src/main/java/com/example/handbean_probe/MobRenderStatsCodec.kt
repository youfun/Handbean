package com.example.handbean_probe

/** Wire encoding only; sampling, the ring buffer and frame callbacks belong to MobBridge. */
internal object MobRenderStatsCodec {
    class FrameSample(val applyUs: Double, val seq: Long, val transition: String)

    fun encode(enabled: Boolean, recorded: Long, capacity: Int, samples: List<FrameSample>): String {
        val dropped = if (recorded > capacity) recorded - capacity else 0L
        val out = StringBuilder(64 + samples.size * 64)
        out.append("{\"enabled\":").append(enabled)
            .append(",\"recorded\":").append(recorded)
            .append(",\"dropped\":").append(dropped)
            .append(",\"samples\":[")
        samples.forEachIndexed { i, sample ->
            if (i > 0) out.append(',')
            out.append("{\"apply_us\":").append(sample.applyUs)
                .append(",\"transition\":\"").append(jsonEscape(sample.transition))
                .append("\",\"seq\":").append(sample.seq).append('}')
        }
        return out.append("]}").toString()
    }

    // Transitions arrive as arbitrary atoms, not a closed vocabulary.
    private fun jsonEscape(value: String): String {
        val out = StringBuilder(value.length + 8)
        for (c in value) {
            when {
                c == '"' -> out.append("\\\"")
                c == '\\' -> out.append("\\\\")
                c < ' ' -> out.append(String.format("\\u%04x", c.code))
                else -> out.append(c)
            }
        }
        return out.toString()
    }
}
