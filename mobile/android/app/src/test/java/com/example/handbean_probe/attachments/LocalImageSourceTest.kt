package com.example.handbean_probe.attachments

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class LocalImageSourceTest {
    @Test
    fun rejectsRemoteAndSchemedSources() {
        assertNull(LocalImageSource.fileForPreview("https://example.com/a.png"))
        assertNull(LocalImageSource.fileForPreview("http://127.0.0.1/a.png"))
        assertNull(LocalImageSource.fileForPreview("content://media/external/images/1"))
        assertNull(LocalImageSource.fileForPreview("file:///sdcard/a.png"))
        assertNull(LocalImageSource.fileForPreview("photo.png"))
        assertNull(LocalImageSource.fileForPreview(null))
        assertNull(LocalImageSource.fileForPreview(""))
    }

    @Test
    fun acceptsAbsoluteLocalPath() {
        val file = LocalImageSource.fileForPreview("/data/user/0/app/cache/controlled_import/a.jpg")
        assertNotNull(file)
        assertEquals("/data/user/0/app/cache/controlled_import/a.jpg", file!!.absolutePath)
    }

    @Test
    fun authorizedUploadIsConversationUploadOnly() {
        val ok = "/data/user/0/app/files/workspace/.handbean/uploads/cid-1/att.png"
        assertNotNull(LocalImageSource.fileForAuthorizedUpload(ok))
        assertNull(LocalImageSource.fileForAuthorizedUpload("/data/user/0/app/cache/controlled_import/a.jpg"))
        assertNull(LocalImageSource.fileForAuthorizedUpload("/data/user/0/app/files/workspace/secret.png"))
        assertNull(LocalImageSource.fileForAuthorizedUpload("https://example.com/a.png"))
        assertNull(
            LocalImageSource.fileForAuthorizedUpload(
                "/data/user/0/app/files/workspace/.handbean/uploads/cid-1/../secret.png",
            ),
        )
    }

    @Test
    fun sampleSizeCapsLongEdge() {
        assertEquals(1, LocalImageSource.sampleSize(40, 40, 96))
        assertEquals(4, LocalImageSource.sampleSize(200, 80, 96))
        assertEquals(8, LocalImageSource.sampleSize(800, 600, 160))
    }
}
