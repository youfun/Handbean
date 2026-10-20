package com.example.handbean_probe

import android.app.Activity
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import android.os.SystemClock
import android.speech.tts.TextToSpeech
import android.util.Log
import androidx.compose.foundation.layout.size
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import org.json.JSONObject

internal object MobAudio {
    // ── Audio recording ───────────────────────────────────────────────────
    private var audioRecorder: MediaRecorder? = null
    private var audioPath: String? = null
    private var audioStartMs: Long = 0
    private var audioPid: Long = 0

    fun audio_start_recording(pid: Long, optsJson: String) {
        audioPid = pid
        val activity = MobBridge.activity() ?: return
        activity.runOnUiThread {
            try {
                val tmp = File(activity.cacheDir, "mob_audio_${System.currentTimeMillis()}.m4a")
                audioPath = tmp.absolutePath
                audioStartMs = SystemClock.elapsedRealtime()
                val rec = if (android.os.Build.VERSION.SDK_INT >= 31)
                    MediaRecorder(activity)
                else @Suppress("DEPRECATION") MediaRecorder()
                rec.setAudioSource(MediaRecorder.AudioSource.MIC)
                rec.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                rec.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                rec.setOutputFile(audioPath)
                rec.prepare()
                rec.start()
                audioRecorder = rec
            } catch (e: Exception) {
                MobBridge.nativeDeliverAtom3(pid, "audio", "error", "setup_failed")
            }
        }
    }

    fun audio_stop_recording() {
        val rec = audioRecorder ?: return
        val pid = audioPid
        val path = audioPath ?: return
        val duration = (SystemClock.elapsedRealtime() - audioStartMs) / 1000.0
        audioRecorder = null
        try {
            rec.stop()
            rec.release()
            val json = """[{"path":"$path","duration":$duration}]"""
            MobBridge.nativeDeliverFileResult(pid, "audio", "recorded", json)
        } catch (e: Exception) {
            MobBridge.nativeDeliverAtom3(pid, "audio", "error", "stop_failed")
        }
    }

    // ── Audio input metering (mic level probe, no recording kept) ──────────
    // Pairs with Mob.Audio.start_input_metering/input_level/stop_input_metering
    // and the zig NIF (mob). MediaRecorder to a throwaway file with getMaxAmplitude
    // as the level; the NIF converts amplitude (0..32767, -1 = not metering) to dBFS.
    private var meterRecorder: MediaRecorder? = null
    private var meterPath: String? = null

    fun audio_start_input_metering() {
        val activity = MobBridge.activity() ?: return
        activity.runOnUiThread {
            try {
                val tmp = File(activity.cacheDir, "mob_meter_${System.currentTimeMillis()}.m4a")
                meterPath = tmp.absolutePath
                val rec = if (android.os.Build.VERSION.SDK_INT >= 31)
                    MediaRecorder(activity)
                else @Suppress("DEPRECATION") MediaRecorder()
                rec.setAudioSource(MediaRecorder.AudioSource.MIC)
                rec.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                rec.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                rec.setOutputFile(meterPath)
                rec.prepare()
                rec.start()
                meterRecorder = rec
            } catch (e: Exception) {
                meterRecorder = null
            }
        }
    }

    fun audio_input_level(): Int {
        val rec = meterRecorder ?: return -1
        return try { rec.maxAmplitude } catch (e: Exception) { -1 }
    }

    fun audio_stop_input_metering() {
        val rec = meterRecorder ?: return
        meterRecorder = null
        try {
            rec.stop()
            rec.release()
        } catch (e: Exception) {
        }
        meterPath?.let { runCatching { File(it).delete() } }
        meterPath = null
    }

    // ── Audio playback ─────────────────────────────────────────────────────
    private var audioPlayer: MediaPlayer? = null
    private var playbackPid: Long = 0
    private var playbackPath: String? = null

    fun audio_play(pid: Long, path: String, optsJson: String) {
        playbackPid  = pid
        playbackPath = path
        val activity = MobBridge.activity() ?: return
        activity.runOnUiThread {
            try {
                audioPlayer?.release()
                audioPlayer = null
                val opts = org.json.JSONObject(optsJson)
                val loop   = opts.optBoolean("loop", false)
                val volume = opts.optDouble("volume", 1.0).toFloat()
                val player = MediaPlayer()
                player.setDataSource(path)
                player.isLooping = loop
                player.setVolume(volume, volume)
                player.setOnCompletionListener {
                    val p = playbackPid
                    val pp = playbackPath ?: ""
                    audioPlayer = null
                    playbackPath = null
                    val json = """[{"path":"$pp"}]"""
                    MobBridge.nativeDeliverFileResult(p, "audio", "playback_finished", json)
                }
                player.setOnErrorListener { _, _, _ ->
                    val p = playbackPid
                    audioPlayer = null
                    playbackPath = null
                    MobBridge.nativeDeliverAtom3(p, "audio", "playback_error", "player_error")
                    true
                }
                player.prepare()
                player.start()
                audioPlayer = player
            } catch (e: Exception) {
                MobBridge.nativeDeliverAtom3(pid, "audio", "playback_error", "setup_failed")
            }
        }
    }

    // ── Scheduled audio playback (sample-accurate sync) ───────────────────
    //
    // Schedules `path` to start at absolute local wall-clock time `atWallMs`
    // (in `System.currentTimeMillis()` terms). Each scheduled note runs on
    // a dedicated audio-priority thread that sleeps until just before the
    // target moment, busy-waits the final ~3 ms for precise wakeup, then
    // writes the entire WAV to a freshly-built AudioTrack in STATIC mode
    // and calls play(). The audio hardware clock then fires the samples
    // at its sample rate.
    //
    // Per-device calibration: `AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER`
    // gives the device's native low-latency buffer hint; we subtract that
    // converted-to-ms from the target as our best estimate of end-to-end
    // output latency. Pro-audio capable devices report tiny values
    // (~2 ms); budget devices report larger (~20–40 ms).
    private val scheduledTracks = mutableListOf<AudioTrack>()
    private var cachedOutputLatencyMs: Long = -1L

    // WAV-header cache. Re-parsing the chunk walker each call costs
    // ~5–10 ms. Cache the format/offset record (small) — NOT the PCM
    // bytes, which can be tens of MB per stem. Streaming reads happen
    // from disk via RandomAccessFile inside the audio thread.
    private val wavCache = java.util.concurrent.ConcurrentHashMap<String, WavInfo>()

    // Pre-warm flag: at the first audio_play_at we play a brief silent
    // buffer so the audio HAL is hot before the first real note hits.
    // Without this the first note inherits cold-start latency.
    private var audioWarmedUp = false

    private fun warmUpAudio() {
        if (audioWarmedUp) return
        audioWarmedUp = true
        try {
            val minBuf = AudioTrack.getMinBufferSize(
                44100, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT,
            )
            val warm = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(44100)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setBufferSizeInBytes(minBuf)
                .setTransferMode(AudioTrack.MODE_STATIC)
                .build()
            val silence = ByteArray(minBuf)
            warm.write(silence, 0, silence.size)
            warm.setVolume(0f)
            warm.play()
            android.os.Handler(MobBridge.activity()?.mainLooper ?: return).postDelayed({
                try { warm.stop(); warm.release() } catch (_: Exception) {}
            }, 200)
        } catch (_: Exception) {}
    }

    private fun outputLatencyMs(): Long {
        if (cachedOutputLatencyMs >= 0) return cachedOutputLatencyMs
        val activity = MobBridge.activity() ?: return 0L
        val am = activity.getSystemService(Activity.AUDIO_SERVICE) as? AudioManager
        val frames = am?.getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)?.toIntOrNull() ?: 1024
        val rate = am?.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull() ?: 44100
        cachedOutputLatencyMs = (frames * 1000L) / rate
        Log.i("MobBridge", "audio output latency: ${cachedOutputLatencyMs}ms (frames=$frames rate=$rate)")
        return cachedOutputLatencyMs
    }

    // Minimal WAV chunk walker. Handles the canonical RIFF/WAVE format with
    // any number of intermediate chunks (LIST, INFO, etc.) between `fmt ` and
    // `data`. Returns the raw PCM data + sample rate + channel count, or null
    // if the file isn't a 16-bit PCM WAV.
    // WAV header info — the bare minimum needed to open an AudioTrack
    // and seek to the PCM data. We deliberately do NOT keep the PCM
    // bytes in memory; for multi-MB stems that'd be wasteful. Instead
    // we cache this little record and stream from disk at play time.
    private data class WavInfo(
        val sampleRate: Int,
        val channels: Int,
        val dataOffset: Long,
        val dataLength: Long,
    )

    private fun decodeWavHeader(path: String): WavInfo? {
        val file = java.io.File(path)
        if (!file.exists()) return null

        val raf = java.io.RandomAccessFile(file, "r")
        try {
            val riff = ByteArray(12)
            if (raf.read(riff) < 12) return null
            if (String(riff, 0, 4) != "RIFF") return null
            if (String(riff, 8, 4) != "WAVE") return null

            var sampleRate = 0
            var channels = 0
            var bitsPerSample = 0

            while (raf.filePointer < file.length() - 8) {
                val hdr = ByteArray(8)
                if (raf.read(hdr) < 8) return null
                val tag = String(hdr, 0, 4)
                val sz = ((hdr[4].toInt() and 0xff)) or
                    ((hdr[5].toInt() and 0xff) shl 8) or
                    ((hdr[6].toInt() and 0xff) shl 16) or
                    ((hdr[7].toInt() and 0xff) shl 24)

                when (tag) {
                    "fmt " -> {
                        val fmt = ByteArray(sz)
                        if (raf.read(fmt) < sz) return null
                        channels = (fmt[2].toInt() and 0xff) or
                            ((fmt[3].toInt() and 0xff) shl 8)
                        sampleRate = ((fmt[4].toInt() and 0xff)) or
                            ((fmt[5].toInt() and 0xff) shl 8) or
                            ((fmt[6].toInt() and 0xff) shl 16) or
                            ((fmt[7].toInt() and 0xff) shl 24)
                        bitsPerSample = (fmt[14].toInt() and 0xff) or
                            ((fmt[15].toInt() and 0xff) shl 8)
                    }
                    "data" -> {
                        if (bitsPerSample != 16 || channels !in 1..2) return null
                        return WavInfo(sampleRate, channels, raf.filePointer, sz.toLong())
                    }
                    else -> raf.seek(raf.filePointer + sz)
                }
            }
            return null
        } finally {
            raf.close()
        }
    }

    fun audio_play_at(pid: Long, path: String, optsJson: String, atWallMsStr: String) {
        val atWallMs = atWallMsStr.toLongOrNull() ?: return

        // One background thread per scheduled note. The thread sleeps
        // until the target moment (minus the device's measured output
        // latency), then writes the entire audio buffer to a freshly
        // created AudioTrack. The audio hardware clock then fires the
        // samples at its sample rate, giving us sub-buffer-tick accuracy
        // from the moment the write completes.
        //
        // Why not stream silence ahead of time on the audio thread? Mid-
        // range Android devices struggle when many AudioTracks are
        // simultaneously feeding silence chunks — buffer-underrun
        // glitches result. This "sleep, then write the audio in one shot"
        // approach trades ~10–20 ms of scheduler jitter on each note's
        // start for clean playback. For multi-device sync within a single
        // device class (e.g. two Motos), they share the same jitter
        // distribution and still line up.
        warmUpAudio()

        Thread {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO)
            var track: AudioTrack? = null
            var raf: java.io.RandomAccessFile? = null
            try {
                val opts = org.json.JSONObject(optsJson)
                val volume = opts.optDouble("volume", 1.0).toFloat()

                val info = wavCache.getOrPut(path) {
                    decodeWavHeader(path) ?: run {
                        Log.w("MobBridge", "audio_play_at: cannot decode $path")
                        return@Thread
                    }
                }

                // Coarse sleep + fine busy-wait. Thread.sleep accuracy is
                // ~5–10 ms even at audio priority — enough to be audible.
                // Sleep until ~3 ms before target, then spin to hit the
                // exact moment.
                val target = atWallMs - outputLatencyMs()
                val coarseSleep = target - System.currentTimeMillis() - 3L
                if (coarseSleep > 0) Thread.sleep(coarseSleep)
                while (System.currentTimeMillis() < target) {
                    // Busy-wait the final ~3 ms.
                }

                val channelMask = if (info.channels == 1) {
                    AudioFormat.CHANNEL_OUT_MONO
                } else {
                    AudioFormat.CHANNEL_OUT_STEREO
                }
                val minBuf = AudioTrack.getMinBufferSize(
                    info.sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT,
                )
                // ~160 ms of headroom in the track buffer. STREAM mode
                // lets the feeder loop write() block naturally when the
                // buffer is full — no manual chunking math needed.
                val bufferSize = minBuf * 16

                track = AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build(),
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(info.sampleRate)
                            .setChannelMask(channelMask)
                            .build(),
                    )
                    .setBufferSizeInBytes(bufferSize)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()

                track.setVolume(volume)
                track.play()
                synchronized(scheduledTracks) { scheduledTracks.add(track) }

                // Stream PCM from disk in 64 KB chunks. `write()` blocks
                // when the track's internal buffer is full, which is
                // exactly the backpressure we want — the audio hardware
                // drains at its sample rate, the feeder writes only as
                // fast as the device consumes.
                raf = java.io.RandomAccessFile(path, "r")
                raf.seek(info.dataOffset)
                val chunk = ByteArray(64 * 1024)
                var remaining = info.dataLength
                while (remaining > 0) {
                    val toRead = minOf(chunk.size.toLong(), remaining).toInt()
                    val read = raf.read(chunk, 0, toRead)
                    if (read <= 0) break
                    val written = track.write(chunk, 0, read)
                    if (written <= 0) break
                    remaining -= written
                }
            } catch (e: Exception) {
                Log.e("MobBridge", "audio_play_at failed: ${e.message}", e)
            } finally {
                try { raf?.close() } catch (_: Exception) {}
                if (track != null) {
                    try { track!!.stop(); track!!.release() } catch (_: Exception) {}
                    synchronized(scheduledTracks) { scheduledTracks.remove(track) }
                }
            }
        }.apply {
            isDaemon = true
            name = "MobAudioPlayAt"
            start()
        }
    }

    fun audio_stop_playback() {
        // Stop the legacy MediaPlayer path (used by audio_play for short
        // tones) AND the scheduled AudioTrack path (used by audio_play_at
        // for full-song streams). Earlier this function bailed early
        // with `audioPlayer ?: return` when no MediaPlayer was active,
        // leaving scheduled tracks running.
        audioPlayer?.let { p ->
            audioPlayer = null
            playbackPath = null
            try { p.stop(); p.release() } catch (_: Exception) {}
        }
        synchronized(scheduledTracks) {
            for (t in scheduledTracks) {
                try { t.stop(); t.release() } catch (_: Exception) {}
            }
            scheduledTracks.clear()
        }
    }

    fun audio_set_volume(volStr: String) {
        val vol = volStr.toFloatOrNull() ?: 1.0f
        audioPlayer?.setVolume(vol, vol)
        synchronized(scheduledTracks) {
            for (t in scheduledTracks) {
                try { t.setVolume(vol) } catch (_: Exception) {}
            }
        }
    }


    // ── Text-to-speech ──────────────────────────────────────────────────────
    // TextToSpeech initializes asynchronously; we keep one engine alive and
    // queue the first utterance until onInit fires.
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var ttsPending: Pair<String, String>? = null

    /** Called from nif_tts_speak via JNI — speaks text via TextToSpeech.
     *  optsJson may carry {"rate":Float,"pitch":Float,"voice":"en-US"} (all optional). */
    fun ttsSpeak(text: String, optsJson: String) {
        val activity = MobBridge.activity() ?: return
        activity.runOnUiThread {
            if (tts == null) {
                tts = TextToSpeech(activity.applicationContext) { status ->
                    ttsReady = status == TextToSpeech.SUCCESS
                    val pending = ttsPending
                    ttsPending = null
                    if (ttsReady && pending != null) speakNow(pending.first, pending.second)
                }
            }
            if (ttsReady) speakNow(text, optsJson) else ttsPending = text to optsJson
        }
    }

    private fun speakNow(text: String, optsJson: String) {
        val engine = tts ?: return
        try {
            val opts = org.json.JSONObject(optsJson)
            if (opts.has("rate")) engine.setSpeechRate(opts.getDouble("rate").toFloat())
            if (opts.has("pitch")) engine.setPitch(opts.getDouble("pitch").toFloat())
            if (opts.has("voice"))
                engine.setLanguage(java.util.Locale.forLanguageTag(opts.getString("voice")))
        } catch (_: Exception) {
        }
        engine.speak(text, TextToSpeech.QUEUE_ADD, null, "mob_tts_${System.currentTimeMillis()}")
    }

    /** Called from nif_tts_stop via JNI — stops any in-progress speech immediately. */
    fun ttsStop() {
        tts?.stop()
    }


    /** Called from nif_audio_output_status via JNI — reads system audio config
     *  so Mob.Audio.output_status/0 can answer "is sound configured to play".
     *  Returns float[4] = [volume0..1, muted(0/1), routeCode, otherAudio(0/1)].
     *  routeCode: 1=speaker 2=headphones 3=bluetooth 4=receiver 0=none. */
    fun audioOutputStatus(): FloatArray {
        val activity = MobBridge.activity() ?: return FloatArray(4)
        val am = activity.getSystemService(Activity.AUDIO_SERVICE) as? AudioManager
            ?: return FloatArray(4)
        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC).toFloat()
        val cur = am.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat()
        val volume = if (max > 0f) cur / max else 0f
        val muted =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                am.isStreamMute(AudioManager.STREAM_MUSIC)
            ) {
                1f
            } else {
                0f
            }
        val other = if (am.isMusicActive) 1f else 0f
        // Best-effort active route: Android routes media to BT/wired when one
        // is connected, so pick the highest-priority connected output.
        var route = 1f // builtin speaker
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            var hasBt = false
            var hasWired = false
            for (d in am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
                when (d.type) {
                    android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                    android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                    -> hasBt = true
                    android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                    android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET,
                    android.media.AudioDeviceInfo.TYPE_USB_HEADSET,
                    -> hasWired = true
                }
            }
            route = if (hasBt) 3f else if (hasWired) 2f else 1f
        }
        return floatArrayOf(volume, muted, route, other)
    }

    /** Called from nif_audio_output_level via JNI — reads the actual output
     *  signal level so Mob.Audio.output_level/1 can tell live audio from
     *  silence. Meters Mob.Audio's OWN player session (`source` == "mob") with a
     *  short-lived Visualizer; RECORD_AUDIO is sufficient for an own-session tap.
     *
     *  Returns: float[2] = [rms_db, peak_db] on success, else a length-1 error
     *  code the NIF maps to an atom — 1 unsupported_on_platform, 2
     *  needs_record_audio, 3 not_playing.
     *
     *  "mix" (the global output mix) is unsupported: attaching a Visualizer to
     *  session 0 is privileged on modern Android (ERROR_NO_INIT for a normal
     *  app), so global device-audio capture lives in a separate
     *  MediaProjection-based plugin, not here. */
    fun audioOutputLevel(source: String): FloatArray {
        if (source != "mob") return floatArrayOf(1f) // unsupported_on_platform
        val sessionId = audioPlayer?.audioSessionId ?: return floatArrayOf(3f) // not_playing
        return try {
            val v = android.media.audiofx.Visualizer(sessionId)
            try {
                v.measurementMode = android.media.audiofx.Visualizer.MEASUREMENT_MODE_PEAK_RMS
                v.captureSize = android.media.audiofx.Visualizer.getCaptureSizeRange()[1]
                v.enabled = true
                // Let the measurement window collect a few audio frames before
                // reading; an immediate read returns the silence sentinel.
                Thread.sleep(60)
                val m = android.media.audiofx.Visualizer.MeasurementPeakRms()
                val rc = v.getMeasurementPeakRms(m)
                v.enabled = false
                if (rc != android.media.audiofx.Visualizer.SUCCESS) {
                    floatArrayOf(2f) // needs_record_audio (most common measure failure)
                } else {
                    // mPeak / mRms are in millibels (1/100 dB).
                    floatArrayOf(m.mRms / 100f, m.mPeak / 100f)
                }
            } finally {
                v.release()
            }
        } catch (e: Throwable) {
            // Usually a SecurityException: RECORD_AUDIO not granted at runtime.
            android.util.Log.w("MobBridge", "audioOutputLevel($source) failed: ${e.message}")
            floatArrayOf(2f) // needs_record_audio
        }
    }
}
