package com.example.handbean_probe

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.example.handbean_probe.workspace.FileIdentity
import com.example.handbean_probe.workspace.WorkspaceOpen
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.IOException

/**
 * Real [android.system.Os] fd checks. Do not run on the shared ARC device.
 */
@RunWith(AndroidJUnit4::class)
class WorkspaceOpenFdTest {
    @Test
    fun openRegularFileReadsSameFd() {
        val dir = File.createTempFile("wsfd", "dir").apply {
            delete()
            mkdirs()
        }
        val file = File(dir, "note.txt")
        file.writeText("你好")
        val identity = FileIdentity(
            workspaceId = "ws",
            workspaceRoot = dir.absolutePath,
            relativePath = "note.txt",
            requestId = "r",
            generation = 1,
            displayName = "note.txt",
            kind = "text",
        )
        val result = WorkspaceOpen.readText(identity)
        assertEquals("你好", result.text)
        dir.deleteRecursively()
    }

    @Test
    fun openRefusesFinalSymlink() {
        val dir = File.createTempFile("wsfd", "dir").apply {
            delete()
            mkdirs()
        }
        val file = File(dir, "note.txt")
        file.writeText("x")
        val link = File(dir, "alias.txt")
        java.nio.file.Files.createSymbolicLink(link.toPath(), file.toPath())
        val identity = FileIdentity(
            workspaceId = "ws",
            workspaceRoot = dir.absolutePath,
            relativePath = "alias.txt",
            requestId = "r",
            generation = 1,
            displayName = "alias.txt",
            kind = "text",
        )
        val result = WorkspaceOpen.readText(identity)
        assertTrue(result.error != null)
        dir.deleteRecursively()
    }

    @Test
    fun missingProcOrOpenFailsClosed() {
        val identity = FileIdentity(
            workspaceId = "ws",
            workspaceRoot = "/no/such/workspace",
            relativePath = "a.txt",
            requestId = "r",
            generation = 1,
            displayName = "a.txt",
            kind = "text",
        )
        try {
            WorkspaceOpen.openChecked(identity)
            throw AssertionError("expected fail closed")
        } catch (_: IOException) {
        }
    }
}
