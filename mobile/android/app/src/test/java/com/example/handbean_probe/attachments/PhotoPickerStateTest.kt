package com.example.handbean_probe.attachments

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

class PhotoPickerStateTest {
    @Test
    fun slotStaysOccupiedUntilFinishSoSecondRequestCannotResetFlags() {
        val slot = PhotoPickSlot()
        assertTrue(slot.reserve("pick-1"))
        assertTrue(slot.beginDispatch("pick-1"))
        assertTrue(slot.accepted("pick-1"))
        assertFalse(slot.reserve("pick-2"))
        assertEquals("pick-1", slot.requestId())
        assertEquals("pick-1", slot.finish("pick-1"))
        assertNull(slot.requestId())
        assertTrue(slot.reserve("pick-2"))
    }

    @Test
    fun staleOrCancelledCallbackDoesNotFinishAnotherRequest() {
        val slot = PhotoPickSlot()
        slot.restoreAccepted("pick-live")
        assertNull(slot.finish("pick-old"))
        assertEquals("pick-live", slot.requestId())
        assertTrue(slot.cancel("pick-live"))
        assertEquals("pick-live", slot.consume("pick-live"))
    }

    @Test
    fun restoreDoesNotClearExistingSessionCancel() {
        PhotoPickerHost.restore("pick-restore", 3)
        PhotoPickerHost.currentSession()!!.cancelled.set(true)
        PhotoPickerHost.restore("pick-restore", 3)
        assertEquals("pick-restore", PhotoPickerHost.currentSession()!!.requestId)
        assertTrue(PhotoPickerHost.currentSession()!!.cancelled.get())
    }

    @Test
    fun perSessionCancelDoesNotAffectOtherSession() {
        val a = PhotoPickSession("a", 1)
        val b = PhotoPickSession("b", 2)
        a.cancelled.set(true)
        assertTrue(a.cancelled.get())
        assertFalse(b.cancelled.get())
        assertNotEquals(a.cancelled, b.cancelled)
    }

    @Test
    fun cancelledImportDeletesProducedFiles() {
        val dir = File(System.getProperty("java.io.tmpdir"), "photo_rel_${System.nanoTime()}")
        dir.mkdirs()
        val file = File(dir, "late.jpg")
        file.writeText("x")
        val cancelled = AtomicBoolean(true)
        val importer = ControlledImport(dir)
        val source = object : ImportSource {
            override val displayName = "late.jpg"
            override val declaredMime = "image/jpeg"
            override val declaredSize: Long? = 1
            override fun openStream() = file.inputStream()
        }
        assertEquals(ImportResult.Cancelled, importer.importNow(source, "photo", cancelled))
        dir.deleteRecursively()
    }
}
