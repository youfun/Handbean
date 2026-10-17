package com.example.handbean_probe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkspaceImportTest {
    @Test
    fun repeatedImportCannotReplaceAnExistingProject() {
        val root = java.nio.file.Files.createTempDirectory("import-test").toFile()
        try {
            val first = WorkspaceImport.stageTree(root, "imp_repeat") {
                java.io.File(it, "keep").writeText("user edit")
            }.getOrThrow()
            assertTrue(WorkspaceImport.stageTree(root, "imp_repeat") {
                error("must not copy")
            }.isFailure)
            assertEquals("user edit", java.io.File(first, "keep").readText())
            assertTrue(WorkspaceImport.stageTree(root, "imp_failure") {
                java.io.File(it, "partial").writeText("partial")
                throw java.io.IOException("fixture")
            }.isFailure)
            assertFalse(java.io.File(root, ".staging/imp_failure").exists())
        } finally { root.deleteRecursively() }
    }

    @Test
    fun actualBytesEnforceBothLimitsAndCancellationDuringRead() {
        val counters = WorkspaceImport.Counters()
        WorkspaceImport.copyBounded("1234".byteInputStream(), java.io.ByteArrayOutputStream(),
            counters, "imp_bytes", maxFile = 4, maxTotal = 6)
        val tooLarge = runCatching {
            WorkspaceImport.copyBounded("abc".byteInputStream(), java.io.ByteArrayOutputStream(),
                counters, "imp_bytes", maxFile = 4, maxTotal = 6)
        }.exceptionOrNull()
        assertTrue(tooLarge is WorkspaceImport.TooLarge)
        assertTrue(runCatching {
            WorkspaceImport.copyBounded("12345".byteInputStream(), java.io.ByteArrayOutputStream(),
                WorkspaceImport.Counters(), "imp_file", maxFile = 4, maxTotal = 100)
        }.exceptionOrNull() is WorkspaceImport.TooLarge)
        val output = java.io.ByteArrayOutputStream()
        val input = object : java.io.ByteArrayInputStream(byteArrayOf(1, 2, 3)) {
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                WorkspaceImport.cancel("imp_cancel_read")
                WorkspaceImport.cancel("imp_other")
                return super.read(b, off, len)
            }
        }
        try {
            assertTrue(runCatching {
                WorkspaceImport.copyBounded(input, output, WorkspaceImport.Counters(), "imp_cancel_read")
            }.exceptionOrNull() is WorkspaceImport.Cancelled)
            assertEquals(0, output.size())
        } finally {
            WorkspaceImport.finish("imp_cancel_read")
            WorkspaceImport.finish("imp_other")
        }
    }

    @Test
    fun requestIdComesFromTheDirectoryEnvelope() {
        val json = """[{"kind":"directory","request_id":"imp_9"}]"""
        assertEquals("imp_9", WorkspaceImport.requestIdFromTypes(json))
        assertTrue(WorkspaceImport.isDirectoryPick(json))
        assertFalse(WorkspaceImport.isDirectoryPick("""[{"kind":"mime","value":"*/*"}]"""))
        assertNull(WorkspaceImport.requestIdFromTypes("""[{"kind":"directory"}]"""))
    }

    @Test
    fun documentNamesRejectPathEscapes() {
        assertTrue(WorkspaceImport.safeName("readme.md").isSuccess)
        assertTrue(WorkspaceImport.safeName("中文🙂.txt").isSuccess)
        assertTrue(WorkspaceImport.safeName("..").isFailure)
        assertTrue(WorkspaceImport.safeName("../etc").isFailure)
        assertTrue(WorkspaceImport.safeName("a/b").isFailure)
        assertTrue(WorkspaceImport.safeName("").isFailure)
    }
}
