package com.example.handbean_probe.attachments

import java.io.File
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class ControlledImport(
    private val stagingRoot: File,
    private val executor: Executor = Executors.newSingleThreadExecutor(),
    val imageRewriter: ((File, String) -> File)? = null,
) {
    fun importAsync(
        requestId: String,
        source: ImportSource,
        origin: String,
        generation: Int,
        cancelled: AtomicBoolean,
        onResult: (requestId: String, generation: Int, ImportResult) -> Unit,
    ) {
        executor.execute {
            onResult(requestId, generation, importNow(source, origin, cancelled))
        }
    }

    fun importNow(
        source: ImportSource,
        origin: String,
        cancelled: AtomicBoolean = AtomicBoolean(false),
    ): ImportResult {
        if (cancelled.get()) return ImportResult.Cancelled
        val destDir = File(stagingRoot, "draft")
        destDir.mkdirs()
        val id = UUID.randomUUID().toString()
        val created = mutableListOf<File>()
        return try {
            source.openStream().use { input ->
                val bounded = PeekInputStream(input, 4096)
                val type = TypeNormalizer.normalize(source.declaredMime, source.displayName, bounded.head)
                    ?: return ImportResult.Error("unsupported_type")
                val max = if (TypeNormalizer.image(type)) {
                    AttachmentLimits.MAX_IMAGE_BYTES
                } else {
                    AttachmentLimits.MAX_TEXT_BYTES
                }
                val copied = BoundedCopy.copy(bounded, destDir, max, id).getOrElse {
                    return ImportResult.Error(it.message ?: "copy_failed")
                }
                created.add(copied)
                if (cancelled.get()) {
                    deleteAll(created)
                    return ImportResult.Cancelled
                }
                val actual = copied.length()
                if (actual <= 0L || actual > max) {
                    deleteAll(created)
                    return ImportResult.Error("too_large")
                }
                val finalFile = if (TypeNormalizer.image(type) && imageRewriter != null) {
                    imageRewriter.invoke(copied, type)
                } else {
                    copied
                }
                if (finalFile != copied) created.add(finalFile)
                if (cancelled.get()) {
                    deleteAll(created)
                    return ImportResult.Cancelled
                }
                val finalSize = finalFile.length()
                if (finalSize <= 0L || finalSize > max) {
                    deleteAll(created)
                    return ImportResult.Error("too_large")
                }
                ImportResult.Ok(
                    ImportedAttachment(
                        attachmentId = id,
                        source = origin,
                        displayName = source.displayName.substringAfterLast('/').ifBlank { "attachment" },
                        canonicalType = type,
                        sourceMime = source.declaredMime,
                        sizeBytes = finalSize,
                        controlledPath = finalFile.absolutePath,
                    ),
                )
            }
        } catch (e: java.util.concurrent.CancellationException) {
            deleteAll(created)
            throw e
        } catch (e: IllegalStateException) {
            deleteAll(created)
            ImportResult.Error(e.message ?: "import_failed")
        } catch (e: java.io.IOException) {
            deleteAll(created)
            ImportResult.Error(e.message ?: "import_failed")
        }
    }

    private fun deleteAll(files: List<File>) {
        files.forEach { it.delete() }
        files.mapNotNull { it.parentFile }.distinct().forEach { dir ->
            dir.listFiles()?.filter { it.name.endsWith(".partial") }?.forEach { it.delete() }
        }
    }
}

private class PeekInputStream(private val inner: java.io.InputStream, peek: Int) : java.io.InputStream() {
    val head: ByteArray
    private var replay = 0

    init {
        val buf = ByteArray(peek)
        val n = inner.read(buf)
        head = if (n <= 0) ByteArray(0) else buf.copyOf(n)
    }

    override fun read(): Int {
        if (replay < head.size) {
            val b = head[replay].toInt() and 0xFF
            replay += 1
            return b
        }
        return inner.read()
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (replay < head.size) {
            val n = minOf(len, head.size - replay)
            System.arraycopy(head, replay, b, off, n)
            replay += n
            return n
        }
        return inner.read(b, off, len)
    }
}
