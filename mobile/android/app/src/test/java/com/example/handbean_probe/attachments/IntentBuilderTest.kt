package com.example.handbean_probe.attachments

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class IntentBuilderTest {
    @Test
    fun launchGateCancelWinsOnlyFromPending() {
        val gate = LaunchGate()
        assertTrue(gate.cancelBeforeLaunch())
        assertEquals(LaunchPhase.CANCELLED, gate.phase())
        assertTrue(!gate.beginDispatch())
    }

    @Test
    fun launchGateDispatchThenCancelDoesNotRewind() {
        val gate = LaunchGate()
        assertTrue(gate.beginDispatch())
        assertTrue(!gate.cancelBeforeLaunch())
        assertTrue(gate.markLaunched())
        assertEquals(LaunchPhase.LAUNCHED, gate.phase())
    }

    @Test
    fun launchGateCancelWinsBeforeDispatch() {
        val gate = LaunchGate()
        assertTrue(gate.cancelBeforeLaunch())
        assertTrue(!gate.beginDispatch())
        assertEquals(LaunchPhase.CANCELLED, gate.phase())
    }

    @Test
    fun safeBasenameKeepsReportNameAndDropsPaths() {
        assertEquals("acceptance-report.txt", IntentBuilder.safeBasename("acceptance-report.txt"))
        assertEquals("acceptance-report.txt", IntentBuilder.safeBasename("out/acceptance-report.txt"))
        assertEquals("acceptance-report.txt", IntentBuilder.safeBasename("/tmp/ws/acceptance-report.txt"))
        assertEquals("file", IntentBuilder.safeBasename(".."))
        assertEquals("file", IntentBuilder.safeBasename("/"))
    }

    @Test
    fun mimeForPdfAndZip() {
        assertEquals("application/pdf", IntentBuilder.mimeForName("report.pdf"))
        assertEquals("application/zip", IntentBuilder.mimeForName("code.zip"))
        assertEquals("image/png", IntentBuilder.mimeForName("shot.PNG"))
    }

    @Test
    fun exportProviderMimeMatchesIntentTypeForTxtPdfZip() {
        for (name in listOf("acceptance-report.txt", "notes.md", "doc.pdf", "pack.zip")) {
            val intentMime = IntentBuilder.mimeForName(name)
            assertEquals(intentMime, ExportFileProvider.mimeForDisplayName(name))
            assertEquals(intentMime, ExportFileProvider.mimeForDisplayName("out/$name"))
        }
        assertEquals("text/plain", ExportFileProvider.mimeForDisplayName("acceptance-report.txt"))
        assertEquals("application/pdf", ExportFileProvider.mimeForDisplayName("doc.pdf"))
        assertEquals("application/zip", ExportFileProvider.mimeForDisplayName("pack.zip"))
        assertEquals("application/octet-stream", ExportFileProvider.mimeForDisplayName(null))
        assertEquals("application/octet-stream", ExportFileProvider.mimeForDisplayName(""))
    }
}
