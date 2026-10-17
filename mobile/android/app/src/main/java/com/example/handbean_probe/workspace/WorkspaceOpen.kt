package com.example.handbean_probe.workspace

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.Closeable
import java.io.File
import java.io.FileDescriptor
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CharsetDecoder
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

/**
 * One [Os.open] for in-app view. Flags are `O_RDONLY|O_NONBLOCK|O_NOFOLLOW`
 * so a FIFO or final symlink does not block or follow. [Os.fstat] must be a
 * regular file. `/proc/self/fd/<ParcelFileDescriptor.fd>` must stay under
 * the workspace. Missing proc or fstat fails closed.
 *
 * The fd is the authorized inode. A later rename of that inode is the same
 * file, not a different one. read / bounds / decode use this fd.
 */
object WorkspaceOpen {
    const val MAX_TEXT_BYTES = 1024 * 1024
    const val BINARY_PROBE = 8192
    const val MAX_IMAGE_EDGE = 4096
    const val MAX_IMAGE_PIXELS = 16_777_216
    const val MAX_ENCODED_BYTES = 32L * 1024L * 1024L

    class Opened(
        private val pfd: ParcelFileDescriptor,
        val size: Long,
    ) : Closeable {
        val fd: FileDescriptor get() = pfd.fileDescriptor
        override fun close() {
            pfd.close()
        }
    }

    data class TextResult(
        val text: String = "",
        val truncated: Boolean = false,
        val binary: Boolean = false,
        val invalidUtf8: Boolean = false,
        val error: String? = null,
        val byteCount: Int = 0,
    )

    fun namedFile(identity: FileIdentity): File? {
        if (identity.workspaceRoot.isBlank() || identity.relativePath.isBlank()) return null
        if (identity.relativePath.contains('\u0000')) return null
        val parts = identity.relativePath.replace('\\', '/').split('/')
        if (parts.any { it.isEmpty() || it == ".." }) return null
        val root = File(identity.workspaceRoot).absoluteFile.normalize()
        if (!root.isAbsolute) return null
        val file = File(root, parts.joinToString(File.separator)).normalize()
        if (!stringContained(file, root)) return null
        return file
    }

    fun contained(file: File, root: File): Boolean {
        val resolved = file.canonicalFile
        val rootResolved = root.canonicalFile
        return resolved == rootResolved ||
            resolved.path.startsWith(rootResolved.path + File.separator)
    }

    fun openChecked(identity: FileIdentity): Opened {
        val file = namedFile(identity) ?: throw IOException("invalid_path")
        val flags = OsConstants.O_RDONLY or OsConstants.O_NONBLOCK or OsConstants.O_NOFOLLOW
        val raw: FileDescriptor = try {
            Os.open(file.absolutePath, flags, 0)
        } catch (error: ErrnoException) {
            throw IOException(error.message ?: "open_failed", error)
        }
        var pfd: ParcelFileDescriptor? = null
        try {
            val st = Os.fstat(raw)
            if (!OsConstants.S_ISREG(st.st_mode)) {
                throw IOException("not_regular")
            }
            if (st.st_size > MAX_ENCODED_BYTES && identity.kind == "image") {
                throw IOException("too_large")
            }
            pfd = ParcelFileDescriptor.dup(raw)
            val proc = File("/proc/self/fd/${pfd.fd}")
            if (!proc.exists()) throw IOException("fd_path_unavailable")
            if (!contained(proc, File(identity.workspaceRoot))) {
                throw IOException("outside_workspace")
            }
            val opened = Opened(pfd, st.st_size)
            pfd = null
            return opened
        } catch (error: ErrnoException) {
            throw IOException(error.message ?: "fstat_failed", error)
        } finally {
            try {
                Os.close(raw)
            } catch (_: ErrnoException) {
            }
            pfd?.close()
        }
    }

    fun readText(identity: FileIdentity): TextResult {
        return try {
            openChecked(identity).use { opened ->
                val (bytes, truncated) = readBounded(opened.fd)
                decodeText(bytes, truncated)
            }
        } catch (error: IOException) {
            TextResult(error = error.message ?: "read_failed")
        } catch (error: ErrnoException) {
            TextResult(error = error.message ?: "read_failed")
        }
    }

    fun decodeImage(identity: FileIdentity): Bitmap? {
        return try {
            openChecked(identity).use { opened ->
                val fd = opened.fd
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFileDescriptor(fd, null, bounds)
                if (rejectBounds(bounds.outWidth, bounds.outHeight)) return null
                Os.lseek(fd, 0, OsConstants.SEEK_SET)
                val opts = BitmapFactory.Options().apply {
                    inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight)
                }
                BitmapFactory.decodeFileDescriptor(fd, null, opts)
            }
        } catch (_: IOException) {
            null
        } catch (_: ErrnoException) {
            null
        }
    }

    fun decodeText(bytes: ByteArray, truncated: Boolean): TextResult {
        if (isBinary(bytes)) {
            return TextResult(binary = true, truncated = truncated, byteCount = bytes.size)
        }
        val stripped = stripBom(bytes)
        return when (val text = decodeUtf8(stripped, truncated)) {
            null -> TextResult(invalidUtf8 = true, truncated = truncated, byteCount = bytes.size)
            else -> TextResult(text = text, truncated = truncated, byteCount = bytes.size)
        }
    }

    fun sampleSize(width: Int, height: Int, maxEdge: Int = MAX_IMAGE_EDGE): Int {
        if (width <= 0 || height <= 0) return 1
        val cap = maxEdge.coerceAtLeast(1)
        var sample = 1
        while (width / sample > cap || height / sample > cap) {
            sample *= 2
        }
        return sample
    }

    fun rejectBounds(width: Int, height: Int): Boolean {
        if (width <= 0 || height <= 0) return true
        return width.toLong() * height.toLong() > MAX_IMAGE_PIXELS
    }

    fun isBinary(bytes: ByteArray): Boolean {
        val n = minOf(bytes.size, BINARY_PROBE)
        for (i in 0 until n) {
            if (bytes[i] == 0.toByte()) return true
        }
        return false
    }

    fun stripBom(bytes: ByteArray): ByteArray {
        if (bytes.size >= 3 &&
            bytes[0] == 0xEF.toByte() &&
            bytes[1] == 0xBB.toByte() &&
            bytes[2] == 0xBF.toByte()
        ) {
            return bytes.copyOfRange(3, bytes.size)
        }
        return bytes
    }

    /**
     * Strict UTF-8 via [CharsetDecoder] REPORT. Incomplete trailing bytes are
     * dropped only when [truncated] is the 1 MiB cap. A real EOF fragment or
     * any malformed interior sequence is invalid.
     */
    fun decodeUtf8(bytes: ByteArray, truncated: Boolean): String? {
        val decoder = utf8Decoder()
        return if (truncated) {
            decodeAllowingCapTail(decoder, bytes)
        } else {
            try {
                decoder.decode(ByteBuffer.wrap(bytes)).toString()
            } catch (_: CharacterCodingException) {
                null
            }
        }
    }

    private fun utf8Decoder(): CharsetDecoder =
        StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)

    private fun decodeAllowingCapTail(decoder: CharsetDecoder, bytes: ByteArray): String? {
        val input = ByteBuffer.wrap(bytes)
        val output = CharBuffer.allocate(bytes.size + 1)
        val first = decoder.decode(input, output, false)
        if (first.isError || first.isOverflow) return null
        if (!input.hasRemaining()) {
            val end = decoder.decode(ByteBuffer.allocate(0), output, true)
            if (end.isError) return null
            val flushed = decoder.flush(output)
            if (flushed.isError) return null
        }
        output.flip()
        return output.toString()
    }

    private fun readBounded(fd: FileDescriptor): Pair<ByteArray, Boolean> {
        val buf = ByteArray(MAX_TEXT_BYTES + 1)
        var offset = 0
        while (offset < buf.size) {
            val n = Os.read(fd, buf, offset, buf.size - offset)
            if (n <= 0) break
            offset += n
        }
        val truncated = offset > MAX_TEXT_BYTES
        return buf.copyOf(minOf(offset, MAX_TEXT_BYTES)) to truncated
    }

    private fun stringContained(file: File, root: File): Boolean {
        val path = file.path
        val prefix = root.path
        return path == prefix || path.startsWith(prefix + File.separator)
    }
}
