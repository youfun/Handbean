package com.example.handbean_probe.attachments

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.util.UUID
import java.util.concurrent.Executor

class ShareIntakeLifecycleTest {
    @Before
    fun useInlineIo() {
        ShareIntake.io = Executor { it.run() }
        ShareIntake.deliverReady = { _, _ -> }
        ShareIntake.writeProbe = null
        ShareIntake.atomicRename = { from, to -> from.renameTo(to) }
        ShareIntake.resetBootRecoverForTest()
    }

    @Test
    fun admissionRejectsNinthStoredIntake() {
        val files = File(System.getProperty("java.io.tmpdir"), "share_admit_${System.nanoTime()}")
        repeat(ShareIntake.MAX_PENDING) { writeManifest(files, UUID.randomUUID().toString(), "pending_review") }
        assertEquals(ShareIntake.MAX_PENDING, ShareIntake.countActive(files))
        assertFalse(ShareIntake.admit(files))
        files.deleteRecursively()
    }

    @Test
    fun recoverInterruptedKeepsCompletedDescriptors() {
        val files = File(System.getProperty("java.io.tmpdir"), "share_rec_${System.nanoTime()}")
        val empty = UUID.randomUUID().toString()
        val partial = UUID.randomUUID().toString()
        writeManifest(files, empty, "received")
        writeManifest(
            files,
            partial,
            "importing",
            attachments = JSONArray().put(JSONObject().put("attachment_id", "kept")),
        )
        ShareIntake.recoverAfterDeath(files)
        assertEquals("failed", readState(files, empty))
        assertEquals("pending_review", readState(files, partial))
        val errors = JSONObject(File(ShareIntake.root(files), "$partial/manifest.json").readText())
            .getJSONArray("errors")
        assertTrue((0 until errors.length()).any { errors.getJSONObject(it).getString("reason") == "interrupted" })
        assertEquals(
            "kept",
            JSONObject(File(ShareIntake.root(files), "$partial/manifest.json").readText())
                .getJSONArray("attachments")
                .getJSONObject(0)
                .getString("attachment_id"),
        )
        files.deleteRecursively()
    }

    @Test
    fun discardWhileImportingPreventsResurrection() {
        val files = File(System.getProperty("java.io.tmpdir"), "share_can_${System.nanoTime()}")
        val id = UUID.randomUUID().toString()
        writeManifest(files, id, "importing")
        ShareIntake.requestCancel(id)
        ShareIntake.discard(files, id)
        assertFalse(File(ShareIntake.root(files), id).exists())
        assertTrue(ShareIntake.cancellation(id).get())
        File(ShareIntake.root(files), id).mkdirs()
        File(ShareIntake.root(files), "$id/manifest.json").writeText(
            org.json.JSONObject().put("intake_id", id).put("state", "pending_review").toString(),
        )
        ShareIntake.discard(files, id)
        assertFalse(File(ShareIntake.root(files), id).exists())
        assertTrue(ShareIntake.cancellation(id).get())
        files.deleteRecursively()
    }

    @Test
    fun writeAtomicIoFailureSurfacesStorageErrorAndLeavesFailed() {
        val files = File(System.getProperty("java.io.tmpdir"), "share_io_${System.nanoTime()}")
        val id = UUID.randomUUID().toString()
        writeManifest(files, id, "importing")
        val statuses = mutableListOf<String>()
        ShareIntake.deliverReady = { _, status -> statuses.add(status) }
        var remainingFails = 1
        ShareIntake.writeProbe = { _, _ ->
            if (remainingFails > 0) {
                remainingFails -= 1
                throw java.io.IOException("disk full")
            }
        }
        ShareIntake.recoverAfterDeath(files)
        assertEquals(listOf(ShareIntake.STORAGE_ERROR), statuses)
        assertEquals("failed", readState(files, id))
        val errors = JSONObject(File(ShareIntake.root(files), "$id/manifest.json").readText())
            .getJSONArray("errors")
        assertTrue((0 until errors.length()).any { errors.getJSONObject(it).getString("reason") == "storage_error" })
        files.deleteRecursively()
    }

    @Test
    fun secondBootRecoverPreservesMergedCurrentProcess() {
        val files = File(System.getProperty("java.io.tmpdir"), "share_hot_${System.nanoTime()}")
        val leftover = UUID.randomUUID().toString()
        val live = UUID.randomUUID().toString()
        writeManifest(files, leftover, "merged_current_process")
        ShareIntake.scheduleRecover(files)
        assertEquals("pending_review", readState(files, leftover))
        writeManifest(files, live, "merged_current_process")
        ShareIntake.scheduleRecover(files)
        ShareIntake.ensureBootRecover(files)
        assertEquals("merged_current_process", readState(files, live))
        assertEquals("pending_review", readState(files, leftover))
        files.deleteRecursively()
    }

    @Test
    fun renameFailureDoesNotCopyOverExistingManifest() {
        val files = File(System.getProperty("java.io.tmpdir"), "share_ren_${System.nanoTime()}")
        val id = UUID.randomUUID().toString()
        writeManifest(files, id, "importing")
        val before = File(ShareIntake.root(files), "$id/manifest.json").readText()
        val statuses = mutableListOf<String>()
        ShareIntake.deliverReady = { _, status -> statuses.add(status) }
        ShareIntake.atomicRename = { _, _ -> false }
        ShareIntake.recoverAfterDeath(files)
        assertEquals(before, File(ShareIntake.root(files), "$id/manifest.json").readText())
        assertEquals("importing", readState(files, id))
        assertEquals(listOf(ShareIntake.STORAGE_ERROR), statuses)
        assertFalse(File(ShareIntake.root(files), "$id/manifest.json.partial").exists())
        files.deleteRecursively()
    }

    @Test
    fun shareImporterUsesImageNormalizer() {
        val dir = File(System.getProperty("java.io.tmpdir"), "share_img_${System.nanoTime()}")
        val importer = ShareIntake.shareImporter(dir)
        assertSame(ShareIntake.shareImageRewriter, importer.imageRewriter)
        dir.deleteRecursively()
    }

    private fun writeManifest(
        filesDir: File,
        id: String,
        state: String,
        attachments: JSONArray = JSONArray(),
    ) {
        val dir = File(ShareIntake.root(filesDir), id)
        dir.mkdirs()
        File(dir, "manifest.json").writeText(
            JSONObject()
                .put("intake_id", id)
                .put("state", state)
                .put("text", "")
                .put("errors", JSONArray())
                .put("attachments", attachments)
                .toString(),
        )
    }

    private fun readState(filesDir: File, id: String): String =
        JSONObject(File(ShareIntake.root(filesDir), "$id/manifest.json").readText()).getString("state")
}
