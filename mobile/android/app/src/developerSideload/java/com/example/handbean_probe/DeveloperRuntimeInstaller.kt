package com.example.handbean_probe

import android.content.Context
import android.os.Build
import android.system.Os
import org.apache.commons.compress.archivers.tar.TarArchiveEntry
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.gzip.GzipCompressorInputStream
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.SimpleFileVisitor
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest
import java.util.ArrayDeque

/** Installs the signed, build-pinned Termux userspace before the BEAM starts. */
object DeveloperRuntimeInstaller {
    private const val ARCHIVE_ASSET = "termux-rootfs.tgz"
    private const val MANIFEST_ASSET = "termux-rootfs.json"
    private const val EXPECTED_PACKAGE = "io.hndbean"
    private const val EXPECTED_ABI = "arm64-v8a"
    private const val EXPECTED_PREFIX = "/data/data/io.hndbean/files/usr"
    private const val MAX_ENTRIES = 200_000
    private const val MAX_EXPANDED_BYTES = 2L * 1024L * 1024L * 1024L

    @JvmStatic
    fun install(context: Context) {
        require(context.packageName == EXPECTED_PACKAGE) { "unexpected developer package id" }
        require(Build.SUPPORTED_ABIS.firstOrNull() == EXPECTED_ABI) { "developer runtime requires arm64-v8a" }

        val files = context.filesDir.canonicalFile
        val manifestText = context.assets.open(MANIFEST_ASSET).bufferedReader().use { it.readText() }
        val manifest = JSONObject(manifestText)
        validateManifest(manifest)

        val expectedDigest = manifest.getString("archive_sha256").lowercase()
        val version = manifest.getString("version")
        val target = File(files, "usr")
        val marker = File(files, ".termux-rootfs.json")
        val lockFile = File(files, ".termux-rootfs.lock")

        RandomAccessFile(lockFile, "rw").channel.use { channel ->
            channel.lock().use {
                recoverTransaction(files, target, marker)
                if (installed(marker, target, version, expectedDigest)) return
                installLocked(context, files, target, marker, version, expectedDigest)
            }
        }
    }

    private fun validateManifest(manifest: JSONObject) {
        require(manifest.getString("version").isNotBlank()) { "missing rootfs version" }
        require(manifest.getString("abi") == EXPECTED_ABI) { "unexpected rootfs ABI" }
        require(manifest.getString("prefix") == EXPECTED_PREFIX) { "unexpected Termux prefix" }
        require(manifest.getString("archive_sha256").matches(Regex("[0-9a-fA-F]{64}"))) {
            "invalid rootfs SHA-256"
        }
    }

    private fun installed(
        marker: File,
        target: File,
        version: String,
        digest: String,
    ): Boolean {
        if (!File(target, "bin/bash").isFile || !File(target, "lib/libtermux-exec.so").isFile) {
            return false
        }

        return try {
            val saved = JSONObject(marker.readText())
            saved.getString("version") == version && saved.getString("archive_sha256") == digest
        } catch (_: Throwable) {
            false
        }
    }

    private fun installLocked(
        context: Context,
        files: File,
        target: File,
        marker: File,
        version: String,
        expectedDigest: String,
    ) {
        val nonce = "${android.os.Process.myPid()}-${System.nanoTime()}"
        val archive = File(context.cacheDir, "termux-rootfs-$nonce.tar.gz")
        val staging = File(files, ".termux-installing")
        val backup = File(files, ".termux-previous")
        val transaction = File(files, ".termux-install-transaction.json")

        deleteWithoutFollowingLinks(staging)
        require(!existsNoFollow(backup)) { "unreconciled rootfs backup" }

        try {
            copyAndVerifyArchive(context, archive, expectedDigest)
            extractArchive(archive, staging)
            val stagedUsr = File(staging, "usr")
            validateRuntime(stagedUsr)

            val hadTarget = existsNoFollow(target)
            writeTransaction(transaction, version, expectedDigest, "prepared", hadTarget)
            if (hadTarget) move(target, backup)
            move(stagedUsr, target)
            writeTransaction(transaction, version, expectedDigest, "published", hadTarget)
            writeMarker(marker, version, expectedDigest)
            deleteWithoutFollowingLinks(backup)
            Files.deleteIfExists(transaction.toPath())
        } catch (error: Throwable) {
            recoverTransaction(files, target, marker)
            throw error
        } finally {
            archive.delete()
            deleteWithoutFollowingLinks(staging)
        }
    }

    internal fun recoverTransaction(files: File, target: File, marker: File) {
        val staging = File(files, ".termux-installing")
        val backup = File(files, ".termux-previous")
        val transaction = File(files, ".termux-install-transaction.json")
        if (!transaction.isFile) {
            if (existsNoFollow(backup) && !existsNoFollow(target)) move(backup, target)
            require(!existsNoFollow(backup)) { "rootfs backup exists without transaction" }
            deleteWithoutFollowingLinks(staging)
            return
        }

        val saved = JSONObject(transaction.readText())
        val version = saved.getString("version")
        val digest = saved.getString("archive_sha256")
        val state = saved.getString("state")
        val hadTarget = saved.getBoolean("had_target")
        require(state in setOf("prepared", "published")) { "invalid rootfs transaction state" }
        require(digest.matches(Regex("[0-9a-f]{64}"))) { "invalid rootfs transaction" }

        val publishable = runtimeValid(target)
        val commit = state == "published" && publishable || !hadTarget && publishable

        if (commit) {
            writeMarker(marker, version, digest)
            deleteWithoutFollowingLinks(backup)
        } else if (existsNoFollow(backup)) {
            deleteWithoutFollowingLinks(target)
            move(backup, target)
        } else if (!hadTarget) {
            deleteWithoutFollowingLinks(target)
        }

        deleteWithoutFollowingLinks(staging)
        Files.deleteIfExists(transaction.toPath())
    }

    private fun writeTransaction(
        transaction: File,
        version: String,
        digest: String,
        state: String,
        hadTarget: Boolean,
    ) {
        writeJsonAtomic(
            transaction,
            JSONObject()
                .put("version", version)
                .put("archive_sha256", digest)
                .put("state", state)
                .put("had_target", hadTarget),
        )
    }

    private fun copyAndVerifyArchive(context: Context, destination: File, expectedDigest: String) {
        val digest = MessageDigest.getInstance("SHA-256")
        context.assets.open(ARCHIVE_ASSET).use { input ->
            BufferedOutputStream(FileOutputStream(destination)).use { output ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    if (read == 0) continue
                    digest.update(buffer, 0, read)
                    output.write(buffer, 0, read)
                }
            }
        }

        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        require(actual == expectedDigest) { "rootfs asset SHA-256 mismatch" }
    }

    internal fun extractArchive(archive: File, staging: File) {
        require(staging.mkdirs()) { "cannot create rootfs staging directory" }
        val stagingPath = staging.canonicalFile.toPath()
        val destinations = mutableSetOf<String>()
        val symbolicLinks = mutableListOf<Triple<File, String, String>>()
        val hardLinks = mutableListOf<Pair<File, File>>()
        val directoryModes = mutableListOf<Pair<File, Int>>()
        var entries = 0
        var expanded = 0L

        TarArchiveInputStream(
            GzipCompressorInputStream(BufferedInputStream(FileInputStream(archive))),
        ).use { tar ->
            while (true) {
                val entry = tar.nextEntry ?: break
                entries += 1
                require(entries <= MAX_ENTRIES) { "rootfs has too many entries" }
                expanded += entry.size.coerceAtLeast(0)
                require(expanded <= MAX_EXPANDED_BYTES) { "rootfs exceeds expanded size limit" }

                val name = safeEntryName(entry)
                require(destinations.add(name)) { "duplicate rootfs entry: $name" }
                val output = stagingPath.resolve(name).normalize()
                require(output.startsWith(stagingPath)) { "rootfs path traversal" }
                val file = output.toFile()

                when {
                    entry.isDirectory -> {
                        require(file.mkdirs() || file.isDirectory) { "cannot create rootfs directory" }
                        directoryModes += file to entry.mode
                    }

                    entry.isSymbolicLink -> {
                        validateSymlink(name, entry.linkName)
                        symbolicLinks += Triple(file, name, entry.linkName)
                    }

                    entry.isLink -> {
                        ensureParent(file)
                        val targetName = normalizeHardLink(entry.linkName)
                        val linkTarget = stagingPath.resolve(targetName).normalize()
                        require(linkTarget.startsWith(stagingPath)) { "hardlink escapes rootfs" }
                        hardLinks += file to linkTarget.toFile()
                    }

                    entry.isFile -> {
                        ensureParent(file)
                        Files.newOutputStream(
                            file.toPath(),
                            StandardOpenOption.CREATE_NEW,
                            StandardOpenOption.WRITE,
                        ).buffered().use { outputStream ->
                            tar.copyTo(outputStream)
                        }
                        chmod(file, entry.mode)
                    }

                    else -> throw IllegalArgumentException("unsupported rootfs entry type: $name")
                }
            }
        }

        validateSymlinkGraph(symbolicLinks.map { (_, name, target) -> name to target })

        symbolicLinks.forEach { (_, name, _) ->
            require(destinations.none { it != name && it.startsWith("$name/") }) {
                "rootfs entry descends through symlink: $name"
            }
        }

        createHardLinks(hardLinks)
        symbolicLinks.forEach { (link, _, target) ->
            ensureParent(link)
            Os.symlink(target, link.absolutePath)
        }
        directoryModes.asReversed().forEach { (directory, mode) -> chmod(directory, mode) }
    }

    private fun createHardLinks(links: List<Pair<File, File>>) {
        val remaining = links.toMutableList()
        while (remaining.isNotEmpty()) {
            var progressed = false
            val iterator = remaining.iterator()
            while (iterator.hasNext()) {
                val (link, target) = iterator.next()
                if (Files.isRegularFile(target.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                    ensureParent(link)
                    Os.link(target.absolutePath, link.absolutePath)
                    iterator.remove()
                    progressed = true
                }
            }
            require(progressed) { "hardlink target is missing or is not a regular staged file" }
        }
    }

    private fun safeEntryName(entry: TarArchiveEntry): String {
        val normalized = entry.name.removePrefix("./").trimEnd('/')
        require(normalized == "usr" || normalized.startsWith("usr/")) {
            "rootfs entry must be under usr"
        }
        require(
            !normalized.startsWith("/") &&
                normalized.split('/').none { it in setOf(".", "..", "") },
        ) { "invalid rootfs entry path" }
        return normalized
    }

    private fun normalizeHardLink(linkName: String): String {
        val normalized = linkName.removePrefix("./")
        require(normalized == "usr" || normalized.startsWith("usr/")) { "hardlink target outside usr" }
        require(normalized.split('/').none { it in setOf(".", "..", "") }) {
            "invalid hardlink target"
        }
        return normalized
    }

    internal fun validateSymlink(entryName: String, linkName: String) {
        require(linkName.isNotBlank() && '\u0000' !in linkName) { "invalid symlink target" }
        if (linkName.startsWith('/')) {
            require(linkName == EXPECTED_PREFIX || linkName.startsWith("$EXPECTED_PREFIX/")) {
                "absolute symlink target outside Termux prefix"
            }
            val expected = Paths.get(EXPECTED_PREFIX)
            val normalized = Paths.get(linkName).normalize()
            require(normalized == expected || normalized.startsWith(expected)) {
                "absolute symlink target outside Termux prefix"
            }
            return
        }

        val logicalParent = requireNotNull(File("/$entryName").parentFile).toPath()
        val logicalTarget = logicalParent.resolve(linkName).normalize()
        val logicalRoot = Paths.get("/usr")
        require(logicalTarget == logicalRoot || logicalTarget.startsWith(logicalRoot)) {
            "relative symlink target escapes usr"
        }
    }

    internal fun validateSymlinkGraph(links: List<Pair<String, String>>) {
        val targets = links.toMap()

        links.forEach { (name, target) ->
            val current = name.split('/').dropLast(1).toMutableList()
            val remaining = ArrayDeque<String>()
            enqueueSymlinkTarget(target, current, remaining)
            var expansions = 0

            while (remaining.isNotEmpty()) {
                when (val component = remaining.removeFirst()) {
                    "", "." -> Unit
                    ".." -> {
                        require(current.size > 1) { "symlink graph escapes Termux prefix: $name" }
                        current.removeAt(current.lastIndex)
                    }

                    else -> {
                        current += component
                        val nestedTarget = targets[current.joinToString("/")]
                        if (nestedTarget != null) {
                            expansions += 1
                            require(expansions <= links.size) { "symlink graph contains a cycle: $name" }
                            current.removeAt(current.lastIndex)
                            enqueueSymlinkTarget(nestedTarget, current, remaining)
                        }
                    }
                }
            }
        }
    }

    private fun enqueueSymlinkTarget(
        target: String,
        current: MutableList<String>,
        remaining: ArrayDeque<String>,
    ) {
        val components =
            if (target.startsWith('/')) {
                require(target == EXPECTED_PREFIX || target.startsWith("$EXPECTED_PREFIX/")) {
                    "absolute symlink target outside Termux prefix"
                }
                current.clear()
                current += "usr"
                target
                    .removePrefix(EXPECTED_PREFIX)
                    .trimStart('/')
                    .split('/')
            } else {
                target.split('/')
            }

        components.asReversed().forEach(remaining::addFirst)
    }

    private fun ensureParent(file: File) {
        val parent = requireNotNull(file.parentFile)
        require(parent.mkdirs() || parent.isDirectory) { "cannot create rootfs parent" }
    }

    private fun chmod(file: File, archiveMode: Int) {
        Os.chmod(file.absolutePath, archiveMode and 0xFFF)
    }

    private fun validateRuntime(root: File) {
        require(File(root, "bin/bash").isFile) { "rootfs has no bash" }
        require(File(root, "bin/elixir").isFile) { "rootfs has no elixir" }
        require(File(root, "bin/erl").isFile) { "rootfs has no erl" }
        require(File(root, "bin/iex").isFile) { "rootfs has no iex" }
        require(File(root, "bin/mix").isFile) { "rootfs has no mix" }
        require(File(root, "bin/python").exists() || File(root, "bin/python3").exists()) {
            "rootfs has no Python"
        }
        require(File(root, "bin/node").isFile) { "rootfs has no Node.js" }
        require(File(root, "lib/libtermux-exec.so").isFile) { "rootfs has no termux-exec" }
    }

    private fun runtimeValid(root: File): Boolean =
        try {
            validateRuntime(root)
            true
        } catch (_: Throwable) {
            false
        }

    private fun writeMarker(marker: File, version: String, digest: String) {
        writeJsonAtomic(
            marker,
            JSONObject()
                .put("version", version)
                .put("archive_sha256", digest),
        )
    }

    private fun writeJsonAtomic(destination: File, value: JSONObject) {
        val temporary = File(requireNotNull(destination.parentFile), "${destination.name}.new")
        deleteWithoutFollowingLinks(temporary)
        Files.newOutputStream(
            temporary.toPath(),
            StandardOpenOption.CREATE_NEW,
            StandardOpenOption.WRITE,
        ).bufferedWriter().use { it.write(value.toString()) }
        move(temporary, destination)
    }

    private fun existsNoFollow(file: File): Boolean =
        Files.exists(file.toPath(), LinkOption.NOFOLLOW_LINKS)

    internal fun deleteWithoutFollowingLinks(file: File) {
        if (!existsNoFollow(file)) return

        Files.walkFileTree(
            file.toPath(),
            object : SimpleFileVisitor<Path>() {
                override fun visitFile(path: Path, attrs: BasicFileAttributes): FileVisitResult {
                    Files.deleteIfExists(path)
                    return FileVisitResult.CONTINUE
                }

                override fun postVisitDirectory(directory: Path, error: java.io.IOException?): FileVisitResult {
                    if (error != null) throw error
                    Files.deleteIfExists(directory)
                    return FileVisitResult.CONTINUE
                }
            },
        )
    }

    private fun move(source: File, destination: File) {
        try {
            Files.move(
                source.toPath(),
                destination.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
            Files.move(source.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }
}
