package com.example.handbean_probe

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.espresso.Espresso.pressBack
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class NativeHistoryDrawerTest {
    @get:Rule val ui = createComposeRule()

    @Test fun drawerLeavesChatVisibleDismissesAndKeepsChatMounted() {
        val open = mutableStateOf(false)
        var disposed = 0
        var chatClicks = 0
        ui.setContent {
            NativeHistoryDrawer(open.value, { open.value = false }, content = {
                DisposableEffect(Unit) { onDispose { disposed++ } }
                Box(Modifier.fillMaxSize().testTag("chat").clickable { chatClicks++ }) { Text("Current chat") }
            }, drawer = { Text("History", Modifier.testTag("history-content")) })
        }
        ui.runOnIdle { open.value = true }
        ui.onNodeWithTag("history-scrim").performTouchInput { click(Offset(width - 4f, height / 2f)) }
        ui.onNodeWithTag("history-drawer").assertDoesNotExist()
        ui.runOnIdle { assertEquals(0, chatClicks); assertEquals(0, disposed); open.value = true }
        pressBack()
        ui.onNodeWithTag("history-drawer").assertDoesNotExist()
        ui.runOnIdle { assertEquals(0, disposed) }
    }
}
