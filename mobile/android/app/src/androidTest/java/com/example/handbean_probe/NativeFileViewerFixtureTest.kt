package com.example.handbean_probe

import android.graphics.Bitmap
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import com.example.handbean_probe.workspace.FILE_VIEWER_FIT_TAG
import com.example.handbean_probe.workspace.FILE_VIEWER_IMAGE_TAG
import com.example.handbean_probe.workspace.FILE_VIEWER_STATUS_TAG
import com.example.handbean_probe.workspace.FILE_VIEWER_TAG
import com.example.handbean_probe.workspace.FILE_VIEWER_TEXT_TAG
import com.example.handbean_probe.workspace.FILE_VIEWER_WRAP_TAG
import com.example.handbean_probe.workspace.FileIdentity
import com.example.handbean_probe.workspace.NativeFileViewer
import com.example.handbean_probe.workspace.WorkspaceOpen
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class NativeFileViewerFixtureTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private fun identity(kind: String) = FileIdentity(
        workspaceId = "ws",
        workspaceRoot = "/unused",
        relativePath = "note.txt",
        requestId = "req",
        generation = 1,
        displayName = "note.txt",
        kind = kind,
    )

    @Test
    fun showsSelectableChineseSourceAndTogglesWrap() {
        composeTestRule.setContent {
            NativeFileViewer(
                identity = identity("text"),
                textReader = {
                    WorkspaceOpen.TextResult("你好\n源码", truncated = false, byteCount = 10)
                },
            )
        }
        composeTestRule.onNodeWithTag(FILE_VIEWER_TAG).assertIsDisplayed()
        composeTestRule.waitUntil(3_000) {
            composeTestRule.onAllNodes(androidx.compose.ui.test.hasTestTag(FILE_VIEWER_TEXT_TAG))
                .fetchSemanticsNodes()
                .isNotEmpty()
        }
        composeTestRule.onNodeWithTag(FILE_VIEWER_TEXT_TAG).assertTextEquals("你好\n源码")
        composeTestRule.onNodeWithTag(FILE_VIEWER_WRAP_TAG).assertTextEquals("换行").performClick()
        composeTestRule.onNodeWithTag(FILE_VIEWER_WRAP_TAG).assertTextEquals("不换行")
    }

    @Test
    fun invalidUtf8IsNotBlankSuccess() {
        composeTestRule.setContent {
            NativeFileViewer(
                identity = identity("text"),
                textReader = { WorkspaceOpen.TextResult(invalidUtf8 = true) },
            )
        }
        composeTestRule.waitUntil(3_000) {
            composeTestRule.onAllNodes(
                hasTestTag(FILE_VIEWER_STATUS_TAG) and hasText("invalid_utf8"),
            ).fetchSemanticsNodes().isNotEmpty()
        }
        composeTestRule.onNodeWithTag(FILE_VIEWER_STATUS_TAG).assertTextEquals("invalid_utf8")
    }

    @Test
    fun imageShowsFitControl() {
        val bmp = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888)
        composeTestRule.setContent {
            NativeFileViewer(
                identity = identity("image"),
                imageDecoder = { bmp },
            )
        }
        composeTestRule.waitUntil(3_000) {
            composeTestRule.onAllNodes(androidx.compose.ui.test.hasTestTag(FILE_VIEWER_FIT_TAG))
                .fetchSemanticsNodes()
                .isNotEmpty()
        }
        composeTestRule.onNodeWithTag(FILE_VIEWER_FIT_TAG).assertIsDisplayed().performClick()
        composeTestRule.onNodeWithTag(FILE_VIEWER_IMAGE_TAG).assertIsDisplayed()
    }

    @Test
    fun ioFailureShowsError() {
        composeTestRule.setContent {
            NativeFileViewer(
                identity = identity("text"),
                textReader = { throw java.io.IOException("boom") },
            )
        }
        composeTestRule.waitUntil(3_000) {
            composeTestRule.onAllNodes(
                hasTestTag(FILE_VIEWER_STATUS_TAG) and hasText("error"),
            ).fetchSemanticsNodes().isNotEmpty()
        }
        composeTestRule.onNodeWithTag(FILE_VIEWER_STATUS_TAG).assertTextEquals("error")
    }

    @Test
    fun closingDuringDecodeRecyclesTheUnshownBitmap() {
        val visible = mutableStateOf(true)
        val started = CountDownLatch(1)
        val finish = CountDownLatch(1)
        val bitmap = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888)
        composeTestRule.setContent {
            if (visible.value) {
                NativeFileViewer(
                    identity = identity("image"),
                    imageDecoder = {
                        started.countDown()
                        check(finish.await(5, TimeUnit.SECONDS))
                        bitmap
                    },
                )
            }
        }
        try {
            assertTrue(started.await(3, TimeUnit.SECONDS))
            composeTestRule.runOnIdle { visible.value = false }
            composeTestRule.waitForIdle()
        } finally {
            finish.countDown()
        }
        composeTestRule.waitUntil(3_000) { bitmap.isRecycled }
    }
}
