package com.example.handbean_probe

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.matcher.RootMatchers.isDialog
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.BeforeClass
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Only run on the isolated, freshly packed foundation app; never a user's installation. */
@RunWith(AndroidJUnit4::class)
class MobBridgeHostTest {
    companion object {
        @JvmStatic
        @BeforeClass
        fun requireIsolatedPackage() {
            assumeTrue(BuildConfig.FOUNDATION_TEST_APP)
        }
    }

    @get:Rule val ui = createAndroidComposeRule<MainActivity>()

    @Test
    fun packagedBridgeKeepsRuntimeAssetsNavigationCallbacksAndNotificationDelivery() {
        ui.waitUntil(60_000) { MobBridge.rootState.value.node != null }
        val activity = ui.activity
        val otp = File(activity.filesDir, "otp")
        val marker = File(otp, ".installed_version")
        assertEquals(
            activity.packageManager.getPackageInfo(activity.packageName, 0).lastUpdateTime.toString(),
            marker.readText(),
        )
        assertTrue(File(otp, "mob_logo_dark.png").length() > 0)
        assertTrue(File(otp, "mob_logo_light.png").length() > 0)
        val sentinel = File(otp, "mobbridge-assets-test.txt")
        try {
            sentinel.writeText("桥接😀\nasset-preservation")
            MobRuntimeAssets.extractOtpIfNeeded(activity)
            assertEquals("桥接😀\nasset-preservation", sentinel.readText())
        } finally {
            sentinel.delete()
        }

        val delivered = mutableListOf<List<Any>>()
        val permissions = MobPermissions({ activity }) { pid, event, cap, status ->
            delivered.add(listOf(pid, event, cap, status))
        }
        ui.runOnUiThread { permissions.request(73L, "mobbridge_unknown_capability") }
        assertEquals(listOf(listOf(73L, "permission", "mobbridge_unknown_capability", "denied")), delivered)

        val original = requireNotNull(MobBridge.rootState.value.node)
        try {
            MobBridge.renderStatsEnable(true)
            for (transition in listOf("push", "none", "push")) {
                val before = MobBridge.rootState.value.navKey
                val generation = MobBridge.currentFrameGeneration()
                ui.runOnUiThread { MobBridge.setRootJson(fixture(), transition) }
                ui.waitUntil(5_000) { JSONObject(MobBridge.elementFrames()).has("mobbridge-fixture") }
                assertEquals(before + if (transition == "none") 0 else 1, MobBridge.rootState.value.navKey)
                if (transition == "none") {
                    assertEquals(generation, MobBridge.currentFrameGeneration())
                } else {
                    MobBridge.recordElementFrame("stale-fixture", generation, 0f, 0f, 1f, 1f)
                    assertFalse(JSONObject(MobBridge.elementFrames()).has("stale-fixture"))
                }
            }
            ui.waitUntil(5_000) { JSONObject(MobBridge.renderStats()).getLong("recorded") >= 3 }
            MobBridge.renderStatsEnable(false)
            val stats = JSONObject(MobBridge.renderStats())
            assertFalse(stats.getBoolean("enabled"))
            assertTrue(stats.getJSONArray("samples").length() >= 3)

            // Button delivery exercises the unchanged native callback on MobBridge.
            ui.runOnUiThread {
                MobBridge.alert_show("Bridge alert", "测试", """[{"label":"Bridge OK","action":"dismiss"}]""")
            }
            onView(withText("Bridge OK")).inRoot(isDialog()).perform(click())
            ui.runOnUiThread {
                MobBridge.action_sheet_show("Bridge actions", """[{"label":"Bridge cancel","style":"cancel","action":"dismiss"}]""")
            }
            onView(withText("Bridge cancel")).inRoot(isDialog()).perform(click())
        } finally {
            MobBridge.renderStatsEnable(false)
            ui.runOnUiThread { MobBridge.setRootJson(encode(original).toString(), "reset") }
        }

        val instrumentation = InstrumentationRegistry.getInstrumentation()
        if (Build.VERSION.SDK_INT >= 33) {
            instrumentation.uiAutomation.grantRuntimePermission(activity.packageName, android.Manifest.permission.POST_NOTIFICATIONS)
        }
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(NotificationChannel(
            io.mob.plugin.MobNotifyHub.CHANNEL_ID, "Bridge test", NotificationManager.IMPORTANCE_DEFAULT,
        ))
        val id = "mobbridge-receiver-test"
        try {
            val info = activity.packageManager.getReceiverInfo(
                android.content.ComponentName(activity, NotificationReceiver::class.java), 0,
            )
            assertFalse(info.exported)
            NotificationReceiver().onReceive(activity, Intent().apply {
                putExtra("id", id)
                putExtra("title", "Bridge notification")
                putExtra("body", "通知😀")
                putExtra("data", "{}")
            })
            ui.waitUntil(5_000) { manager.activeNotifications.any { it.id == id.hashCode() } }
            val notification = manager.activeNotifications.single { it.id == id.hashCode() }.notification
            assertEquals("Bridge notification", notification.extras.getString("android.title"))
            assertEquals("通知😀", notification.extras.getString("android.text"))
            assertTrue(notification.contentIntent != null)
        } finally {
            manager.cancel(id.hashCode())
        }
    }

    private fun fixture() = """{"type":"text","props":{"id":"mobbridge-fixture","text":"桥接测试😀"},"children":[]}"""

    private fun encode(node: MobNode): JSONObject = JSONObject()
        .put("type", node.type)
        .put("props", JSONObject(node.props))
        .put("children", JSONArray(node.children.map(::encode)))
}
