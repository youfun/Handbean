package com.example.handbean_probe

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager

internal object MobWebMotion {
    // ── WebView ────────────────────────────────────────────────────────────
    @Volatile var webView: android.webkit.WebView? = null

    fun webview_eval_js(code: String) {
        val wv = webView ?: return
        MobBridge.activity()?.runOnUiThread { wv.evaluateJavascript(code, null) }
    }

    fun webview_post_message(json: String) {
        val escaped = json.replace("\\", "\\\\").replace("'", "\\'")
        webview_eval_js("window.mob&&window.mob._dispatch('$escaped')")
    }

    fun webview_can_go_back(): Boolean {
        val wv = webView ?: return false
        val latch = java.util.concurrent.CountDownLatch(1)
        var result = false
        MobBridge.activity()?.runOnUiThread {
            result = wv.canGoBack()
            latch.countDown()
        } ?: latch.countDown()
        latch.await(1, java.util.concurrent.TimeUnit.SECONDS)
        return result
    }

    fun webview_go_back() {
        val wv = webView ?: return
        MobBridge.activity()?.runOnUiThread { wv.goBack() }
    }

    // ── Motion sensors ─────────────────────────────────────────────────────
    private var sensorManager: SensorManager? = null
    private var sensorListener: SensorEventListener? = null
    private var motionPid: Long = 0
    private var accelData = floatArrayOf(0f, 0f, 0f)
    private var gyroData  = floatArrayOf(0f, 0f, 0f)
    private var magData   = floatArrayOf(0f, 0f, 0f)
    private var headingDeg = -1.0   // <0 => unavailable; delivered as nil
    private var hasMag = false

    // `spec` is "<interval>" or "<interval>,magnetometer" — the sensor request is
    // encoded in the string by nif_motion_start (the JNI signature stays
    // (JLjava/lang/String;)V). We only register the magnetometer + rotation-vector
    // when the app asked for it, so a plain accel/gyro consumer never pays the
    // extra sensor cost nor gets a 5-key map it didn't request.
    fun motion_start(pid: Long, spec: String) {
        motionPid = pid
        val parts = spec.split(",")
        val intervalMs = parts.getOrNull(0)?.toLongOrNull() ?: 100L
        val wantMag = parts.contains("magnetometer")
        val activity = MobBridge.activity() ?: return
        val sm = activity.getSystemService(android.content.Context.SENSOR_SERVICE) as SensorManager
        sensorManager = sm
        // hasMag drives the map shape only when the caller wanted the compass:
        // requested + hardware => real mag/heading; requested + no hardware =>
        // NaN mag / heading -1 sentinels (the native layer maps them to nil) so
        // the mag/heading keys are always present when :magnetometer was asked for.
        hasMag = wantMag && sm.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD) != null
        val rot = FloatArray(9)
        val orientation = FloatArray(3)
        val listener = object : SensorEventListener {
            var lastSendMs = 0L
            override fun onSensorChanged(event: SensorEvent) {
                when (event.sensor.type) {
                    Sensor.TYPE_ACCELEROMETER  -> accelData = event.values.copyOf()
                    Sensor.TYPE_GYROSCOPE      -> gyroData  = event.values.copyOf()
                    Sensor.TYPE_MAGNETIC_FIELD -> magData   = event.values.copyOf()
                    Sensor.TYPE_ROTATION_VECTOR -> {
                        SensorManager.getRotationMatrixFromVector(rot, event.values)
                        SensorManager.getOrientation(rot, orientation)
                        var az = Math.toDegrees(orientation[0].toDouble())
                        if (az < 0.0) az += 360.0
                        headingDeg = az
                    }
                }
                val now = System.currentTimeMillis()
                if (now - lastSendMs >= intervalMs) {
                    lastSendMs = now
                    if (wantMag) {
                        val nan = Double.NaN
                        MobBridge.nativeDeliverMotionMag(pid,
                            accelData[0].toDouble(), accelData[1].toDouble(), accelData[2].toDouble(),
                            gyroData[0].toDouble(),  gyroData[1].toDouble(),  gyroData[2].toDouble(),
                            if (hasMag) magData[0].toDouble() else nan,
                            if (hasMag) magData[1].toDouble() else nan,
                            if (hasMag) magData[2].toDouble() else nan,
                            if (hasMag) headingDeg else -1.0, now)
                    } else {
                        MobBridge.nativeDeliverMotion(pid,
                            accelData[0].toDouble(), accelData[1].toDouble(), accelData[2].toDouble(),
                            gyroData[0].toDouble(),  gyroData[1].toDouble(),  gyroData[2].toDouble(),
                            now)
                    }
                }
            }
            override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}
        }
        sensorListener = listener
        sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let {
            sm.registerListener(listener, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
        sm.getDefaultSensor(Sensor.TYPE_GYROSCOPE)?.let {
            sm.registerListener(listener, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
        if (hasMag) {
            sm.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD)?.let {
                sm.registerListener(listener, it, SensorManager.SENSOR_DELAY_NORMAL)
            }
            sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)?.let {
                sm.registerListener(listener, it, SensorManager.SENSOR_DELAY_NORMAL)
            }
        }
    }

    fun motion_stop() {
        sensorListener?.let { sensorManager?.unregisterListener(it) }
        sensorListener = null
    }
}
