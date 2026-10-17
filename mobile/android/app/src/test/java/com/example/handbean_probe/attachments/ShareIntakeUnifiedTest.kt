package com.example.handbean_probe.attachments

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.Executor

class ShareIntakeUnifiedTest {
    private val scripted = ScriptedExecutor()

    @Before
    fun useScriptedIo() {
        ShareIntake.io = scripted
        ShareIntake.deliverReady = { _, _ -> }
        ShareIntake.writeProbe = null
        ShareIntake.atomicRename = { from, to -> from.renameTo(to) }
        ShareIntake.resetBootRecoverForTest()
        scripted.clear()
    }

    @Test
    fun classifyKeepsImageAndGeneralConsumptionSeparate() {
        assertEquals(
            ShareIntake.CONSUMPTION_STRUCTURED,
            ShareIntake.classifyConsumption(emptyList()) { null },
        )
        assertEquals(
            ShareIntake.CONSUMPTION_STRUCTURED,
            ShareIntake.classifyConsumption(listOf("content://a/1", "content://a/2")) { "image/jpeg" },
        )
        assertEquals(
            ShareIntake.CONSUMPTION_WORKSPACE,
            ShareIntake.classifyConsumption(listOf("content://a/1", "content://a/doc")) { raw ->
                if (raw.endsWith("doc")) "application/pdf" else "image/png"
            },
        )
        assertEquals(
            ShareIntake.CONSUMPTION_WORKSPACE,
            ShareIntake.classifyConsumption(listOf("content://a/doc")) { "application/pdf" },
        )
    }

    @Test
    fun fifoUsesCreatedSeqAndOverflowIsVisible() {
        val files = File(System.getProperty("java.io.tmpdir"), "share_uni_${System.nanoTime()}")
        val statuses = mutableListOf<String>()
        ShareIntake.deliverReady = { _, status -> statuses.add(status) }
        val ids = (1..8).map { seq ->
            val id = UUID.randomUUID().toString()
            writeManifest(files, id, "pending_review", createdSeq = seq.toLong())
            id
        }
        assertEquals(ids, ShareIntake.listReviewIds(files))
        assertFalse(ShareIntake.admit(files))
        ShareIntake.io = Executor { it.run() }
        ShareIntake.ensureBootRecover(files)
        val extra = UUID.randomUUID().toString()
        assertEquals(ShareIntake.MAX_PENDING, ShareIntake.countActive(files))
        ShareIntake.deliverReady(extra, ShareIntake.OVERFLOW)
        assertEquals(listOf(ShareIntake.OVERFLOW), statuses)
        assertFalse(File(ShareIntake.root(files), extra).exists())
        files.deleteRecursively()
    }

    @Test
    fun fifoUsesCreatedAtWhenSeqResets() {
        val files = File(System.getProperty("java.io.tmpdir"), "share_fifo_${System.nanoTime()}")
        val older = UUID.randomUUID().toString()
        val newer = UUID.randomUUID().toString()
        writeManifest(files, older, "pending_review", createdSeq = 99, createdAt = 10)
        writeManifest(files, newer, "pending_review", createdSeq = 1, createdAt = 20)
        assertEquals(listOf(older, newer), ShareIntake.listReviewIds(files))
        files.deleteRecursively()
    }

    @Test
    fun allocateSeqSurvivesInMemoryReset() {
        val files = File(System.getProperty("java.io.tmpdir"), "share_seq_${System.nanoTime()}")
        val first = ShareIntake.allocateSeq(files)
        ShareIntake.resetBootRecoverForTest()
        val second = ShareIntake.allocateSeq(files)
        assertTrue(second > first)
        files.deleteRecursively()
    }

    @Test
    fun discardThenRecreateIsTerminalNotRetry() {
        val files = File(System.getProperty("java.io.tmpdir"), "share_re_${System.nanoTime()}")
        val cancelled = UUID.randomUUID().toString()
        writeManifest(files, cancelled, "pending_review")
        ShareIntake.io = Executor { it.run() }
        ShareIntake.discard(files, cancelled)
        assertFalse(File(ShareIntake.root(files), cancelled).exists())
        assertEquals(ShareIntake.ResumeAction.TERMINAL, ShareIntake.resumeAction(files, cancelled))
        val missing = UUID.randomUUID().toString()
        assertEquals(ShareIntake.ResumeAction.RETRY_IMPORT, ShareIntake.resumeAction(files, missing))
        files.deleteRecursively()
    }

    @Test
    fun cancelThenQueuedImportDoesNotResurrect() {
        val files = File(System.getProperty("java.io.tmpdir"), "share_int_${System.nanoTime()}")
        val id = UUID.randomUUID().toString()
        writeManifest(files, id, "importing")
        val later = ArrayDeque<Runnable>()
        ShareIntake.io = Executor { later.add(it) }
        ShareIntake.requestCancel(id)
        ShareIntake.discard(files, id)
        assertEquals(1, later.size)
        later.removeFirst().run()
        assertFalse(File(ShareIntake.root(files), id).exists())
        files.deleteRecursively()
    }

    @Test
    fun writeProbeInterleavesWithoutSleep() {
        val files = File(System.getProperty("java.io.tmpdir"), "share_probe_${System.nanoTime()}")
        val first = UUID.randomUUID().toString()
        val second = UUID.randomUUID().toString()
        writeManifest(files, first, "pending_review", createdSeq = 1)
        writeManifest(files, second, "pending_review", createdSeq = 2)
        assertEquals(listOf(first, second), ShareIntake.listReviewIds(files))
        val seen = mutableListOf<String>()
        ShareIntake.writeProbe = { file, json ->
            seen.add(json.optString("state") + ":" + file.parentFile?.name)
        }
        ShareIntake.io = Executor { it.run() }
        ShareIntake.resetBootRecoverForTest()
        writeManifest(files, first, "merged_current_process", createdSeq = 1)
        ShareIntake.recoverAfterDeath(files)
        assertTrue(seen.any { it.startsWith("pending_review") })
        files.deleteRecursively()
    }

    private fun writeManifest(
        filesDir: File,
        id: String,
        state: String,
        createdSeq: Long = 0,
        createdAt: Long = createdSeq,
    ) {
        val dir = File(ShareIntake.root(filesDir), id)
        dir.mkdirs()
        File(dir, "manifest.json").writeText(
            JSONObject()
                .put("intake_id", id)
                .put("state", state)
                .put("created_seq", createdSeq)
                .put("created_at", createdAt)
                .put("text", "")
                .put("errors", org.json.JSONArray())
                .put("attachments", org.json.JSONArray())
                .put("files", org.json.JSONArray())
                .toString(),
        )
    }

    private class ScriptedExecutor : Executor {
        private val q = ArrayDeque<Runnable>()
        override fun execute(command: Runnable) {
            q.add(command)
        }

        fun runOne() {
            q.removeFirst().run()
        }

        fun runAll() {
            while (q.isNotEmpty()) runOne()
        }

        fun clear() {
            q.clear()
        }
    }
}
