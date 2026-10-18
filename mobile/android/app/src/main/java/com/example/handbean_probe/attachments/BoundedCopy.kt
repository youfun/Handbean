package com.example.handbean_probe.attachments

import java.io.File
import java.io.InputStream
import java.util.UUID

object BoundedCopy {
    fun copy(
        input: InputStream,
        destDir: File,
        maxBytes: Long,
        id: String = UUID.randomUUID().toString(),
    ): Result<File> {
        destDir.mkdirs()
        val partial = File(destDir, "$id.partial")
        return try {
            var written = 0L
            partial.outputStream().use { out ->
                val buf = ByteArray(16 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    written += n
                    if (written > maxBytes) {
                        partial.delete()
                        return Result.failure(IllegalStateException("too_large"))
                    }
                    out.write(buf, 0, n)
                }
            }
            if (written == 0L) {
                partial.delete()
                return Result.failure(IllegalStateException("empty"))
            }
            val dest = File(destDir, id)
            if (!partial.renameTo(dest)) {
                partial.copyTo(dest, overwrite = true)
                partial.delete()
            }
            Result.success(dest)
        } catch (e: Exception) {
            partial.delete()
            Result.failure(e)
        }
    }
}
