package com.example.handbean_probe.attachments

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

class AttachmentFoundationTest {
    @Test
    fun typeNormalizerAcceptsOctetStreamSource() {
        val type = TypeNormalizer.normalize(
            "application/octet-stream",
            "mod.ex",
            "defmodule X do\nend\n".toByteArray(),
        )
        assertEquals("text/x-source", type)
    }

    @Test
    fun typeNormalizerRejectsPdf() {
        assertNull(TypeNormalizer.normalize("application/pdf", "doc.pdf", "%PDF-1.4".toByteArray()))
    }

    @Test
    fun typeNormalizerRejectsDeclaredImageWithoutMagic() {
        assertNull(TypeNormalizer.normalize("image/png", "photo.png", "not-an-image".toByteArray()))
    }

    @Test
    fun typeNormalizerRejectsOctetPlaintextWithoutAllowedExt() {
        assertNull(TypeNormalizer.normalize("application/octet-stream", "note.bin", "hello".toByteArray()))
    }

    @Test
    fun boundedCopyStopsAtLimitAndCleansPartial() {
        val dir = File(System.getProperty("java.io.tmpdir"), "bounded_${System.nanoTime()}")
        dir.mkdirs()
        val result = BoundedCopy.copy(ByteArrayInputStream(ByteArray(64)), dir, 16)
        assertTrue(result.isFailure)
        assertTrue(dir.listFiles()?.none { it.extension == "partial" } != false)
        dir.deleteRecursively()
    }

    @Test
    fun controlledImportDoesNotNeedConversation() {
        val root = File(System.getProperty("java.io.tmpdir"), "import_${System.nanoTime()}")
        val importer = ControlledImport(root)
        val source = object : ImportSource {
            override val displayName = "note.txt"
            override val declaredMime = "text/plain"
            override val declaredSize: Long? = null
            override fun openStream() = ByteArrayInputStream("hello".toByteArray())
        }
        val result = importer.importNow(source, "test")
        val ok = result as ImportResult.Ok
        assertEquals("text/plain", ok.attachment.canonicalType)
        assertTrue(File(ok.attachment.controlledPath).exists())
        root.deleteRecursively()
    }

    @Test
    fun cancelledImportIsNotAnError() {
        val root = File(System.getProperty("java.io.tmpdir"), "importc_${System.nanoTime()}")
        val importer = ControlledImport(root)
        val source = object : ImportSource {
            override val displayName = "note.txt"
            override val declaredMime = "text/plain"
            override val declaredSize: Long? = null
            override fun openStream() = ByteArrayInputStream("hello".toByteArray())
        }
        val result = importer.importNow(source, "test", AtomicBoolean(true))
        assertEquals(ImportResult.Cancelled, result)
        root.deleteRecursively()
    }

    @Test
    fun exportCopyFailsWhenSourceChanges() {
        val dir = File(System.getProperty("java.io.tmpdir"), "exp_${System.nanoTime()}")
        dir.mkdirs()
        val source = File(dir, "src.txt")
        source.writeText("one")
        val destDir = File(dir, "snaps")
        val snap = ExportSnapshotCopy.copyChecked(source, destDir)
        assertTrue(File(snap.path).readText() == "one")
        ExportSnapshotCopy.cleanupOrphans(destDir, System.currentTimeMillis() + ExportLimits.TTL_MS + 1)
        assertTrue(destDir.listFiles().isNullOrEmpty())
        dir.deleteRecursively()
    }

    @Test
    fun exportSnapshotRecordsOwnerRequest() {
        val dir = File(System.getProperty("java.io.tmpdir"), "exp_owner_${System.nanoTime()}")
        dir.mkdirs()
        val source = File(dir, "src.txt")
        source.writeText("owned")
        val snap = ExportSnapshotCopy.copyChecked(source, File(dir, "snaps"), ownerRequestId = "owner-1")
        assertEquals("owner-1", snap.ownerRequestId)
        dir.deleteRecursively()
    }

    @Test
    fun snapshotPreparedByOneRequestCanOnlyBeSavedByItsExplicitOwner() {
        val dir = File(System.getProperty("java.io.tmpdir"), "exp_own2_${System.nanoTime()}")
        dir.mkdirs()
        val source = File(dir, "src.txt")
        source.writeText("owned")
        val handler = ExportSnapshotHandler(dir)
        val latch = java.util.concurrent.CountDownLatch(1)
        var snapId = ""
        handler.prepareAsync("prepare-request", source.absolutePath, dir.absolutePath, AtomicBoolean(false)) { _, snap, _ ->
            snapId = snap?.snapshotId ?: ""
            latch.countDown()
        }
        assertTrue(latch.await(5, java.util.concurrent.TimeUnit.SECONDS))
        assertTrue(snapId.isNotEmpty())
        assertNull(handler.get(snapId, "save-request"))
        assertEquals("prepare-request", handler.get(snapId, "prepare-request")?.ownerRequestId)
        handler.cancelOwned(snapId, "save-request")
        assertEquals("prepare-request", handler.get(snapId, "prepare-request")?.ownerRequestId)
        handler.cancelOwned(snapId, "prepare-request")
        assertNull(handler.get(snapId, "prepare-request"))
        dir.deleteRecursively()
    }

    @Test
    fun jpegExifOrientationReadsTag() {
        val jpeg = minimalJpegWithOrientation(6)
        assertEquals(6, ExifReader.orientation(jpeg))
    }

    private fun minimalJpegWithOrientation(orientation: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        out.write(byteArrayOf(0xFF.toByte(), 0xD8.toByte()))
        val tiff = ArrayList<Byte>()
        fun add(vararg b: Int) = b.forEach { tiff.add(it.toByte()) }
        add('I'.code, 'I'.code, 42, 0)
        add(8, 0, 0, 0)
        add(1, 0)
        add(0x12, 0x01, 3, 0, 1, 0, 0, 0, orientation, 0, 0, 0)
        val exif = ArrayList<Byte>()
        exif.addAll("Exif\u0000\u0000".toByteArray().toList())
        exif.addAll(tiff)
        val len = exif.size + 2
        out.write(byteArrayOf(0xFF.toByte(), 0xE1.toByte(), (len shr 8).toByte(), (len and 0xFF).toByte()))
        out.write(exif.toByteArray())
        out.write(byteArrayOf(0xFF.toByte(), 0xD9.toByte()))
        return out.toByteArray()
    }
}
