package com.example.handbean_probe

import android.app.Activity

internal object MobRuntimeAssets {
    /**
     * Extract the bundled OTP tree once per app update (lastUpdateTime).
     * Deploy builds without otp.zip keep their adb-pushed tree untouched.
     */
    fun extractOtpIfNeeded(activity: Activity) {
        val assetList = try { activity.assets.list("") ?: emptyArray() } catch (_: Exception) { return }
        if ("otp.zip" !in assetList) return

        val otpDir = java.io.File(activity.filesDir, "otp")
        val marker = java.io.File(otpDir, ".installed_version")
        val expectedVersion = activity.packageManager
            .getPackageInfo(activity.packageName, 0).lastUpdateTime.toString()

        if (marker.exists() && marker.readText() == expectedVersion) return

        if (otpDir.exists()) otpDir.deleteRecursively()
        otpDir.mkdirs()

        activity.assets.open("otp.zip").use { input ->
            java.util.zip.ZipInputStream(java.io.BufferedInputStream(input)).use { zis ->
                val buffer = ByteArray(8192)
                while (true) {
                    val entry = zis.nextEntry ?: break
                    val out = java.io.File(otpDir, entry.name)
                    if (entry.isDirectory) {
                        out.mkdirs()
                    } else {
                        out.parentFile?.mkdirs()
                        java.io.FileOutputStream(out).use { fos ->
                            var n = zis.read(buffer)
                            while (n != -1) { fos.write(buffer, 0, n); n = zis.read(buffer) }
                        }
                    }
                    zis.closeEntry()
                }
            }
        }

        marker.writeText(expectedVersion)
        android.util.Log.i("MobBridge", "extracted OTP runtime, version=$expectedVersion")
    }

    /** Extract Mob logo PNGs to the OTP root so Elixir can reference them. */
    fun copyMobLogos(activity: Activity) {
        val otpDir = java.io.File(activity.filesDir, "otp").also { it.mkdirs() }
        listOf("mob_logo_dark.png", "mob_logo_light.png").forEach { name ->
            try {
                activity.assets.open(name).use { input ->
                    java.io.File(otpDir, name).outputStream().use { output -> input.copyTo(output) }
                }
            } catch (e: Exception) {
                android.util.Log.w("MobBridge", "Could not copy logo asset $name: $e")
            }
        }
    }
}
