package com.example.handbean_probe

import org.apache.commons.compress.archivers.tar.TarArchiveEntry
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.archivers.tar.TarArchiveOutputStream
import org.apache.commons.compress.compressors.gzip.GzipCompressorInputStream
import org.apache.commons.compress.compressors.gzip.GzipCompressorOutputStream
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.file.Files

class DeveloperRuntimeInstallerTest {
    @Test
    fun duplicateDestinationCannotReplaceDeferredSymlinkWithAFile() {
        val root = Files.createTempDirectory("developer-archive-test").toFile()
        val archive = File(root, "hostile.tar.gz")
        val staging = File(root, "staging")
        val outside = File(root, "outside")
        outside.writeText("preserved")

        GzipCompressorOutputStream(FileOutputStream(archive)).use { gzip ->
            TarArchiveOutputStream(gzip).use { tar ->
                val symlink = TarArchiveEntry("usr/p", TarArchiveEntry.LF_SYMLINK)
                symlink.linkName = "/data/data/io.hndbean/files/usr/bin/target"
                tar.putArchiveEntry(symlink)
                tar.closeArchiveEntry()

                val regular = TarArchiveEntry("usr/p")
                val body = "overwrite".toByteArray()
                regular.size = body.size.toLong()
                tar.putArchiveEntry(regular)
                tar.write(body)
                tar.closeArchiveEntry()
            }
        }

        try {
            val error = assertThrows(IllegalArgumentException::class.java) {
                DeveloperRuntimeInstaller.extractArchive(archive, staging)
            }
            assertTrue(error.message.orEmpty().contains("duplicate rootfs entry"))
            assertEquals("preserved", outside.readText())
        } finally {
            DeveloperRuntimeInstaller.deleteWithoutFollowingLinks(root)
        }
    }

    @Test
    fun absoluteSymlinkCannotNormalizeOutsidePrefix() {
        assertThrows(IllegalArgumentException::class.java) {
            DeveloperRuntimeInstaller.validateSymlink(
                "usr/p",
                "/data/data/io.hndbean/files/usr/../home/victim",
            )
        }
    }

    @Test
    fun generatedRootfsSymlinkGraphStaysInsidePrefixWhenAssetExists() {
        val archive = File("src/developerSideload/assets/termux-rootfs.tgz")
        assumeTrue("generate the developer rootfs to run this check", archive.isFile)
        val links = mutableListOf<Pair<String, String>>()

        TarArchiveInputStream(
            GzipCompressorInputStream(FileInputStream(archive)),
        ).use { tar ->
            while (true) {
                val entry = tar.nextEntry ?: break
                if (entry.isSymbolicLink) links += entry.name.trimEnd('/') to entry.linkName
            }
        }

        DeveloperRuntimeInstaller.validateSymlinkGraph(links)
        assertTrue(links.isNotEmpty())
    }

    @Test
    fun symlinkGraphCannotUseAnotherLinkToEscapePrefix() {
        val error = assertThrows(IllegalArgumentException::class.java) {
            DeveloperRuntimeInstaller.validateSymlinkGraph(
                listOf(
                    "usr/a" to ".",
                    "usr/b" to "a/../home",
                ),
            )
        }

        assertTrue(error.message.orEmpty().contains("escapes Termux prefix"))
    }

    @Test
    fun symlinkGraphCannotNormalizeAbsoluteTargetBeforeExpandingLinks() {
        val error = assertThrows(IllegalArgumentException::class.java) {
            DeveloperRuntimeInstaller.validateSymlinkGraph(
                listOf(
                    "usr/a" to ".",
                    "usr/b" to "/data/data/io.hndbean/files/usr/a/../home",
                ),
            )
        }

        assertTrue(error.message.orEmpty().contains("escapes Termux prefix"))
    }

    @Test
    fun cleanupDeletesLinkWithoutFollowingIt() {
        val root = Files.createTempDirectory("developer-cleanup-test").toFile()
        val preserved = File(root, "preserved").apply { mkdirs() }
        val sentinel = File(preserved, "sentinel").apply { writeText("keep") }
        val doomed = File(root, "doomed").apply { mkdirs() }
        Files.createSymbolicLink(File(doomed, "outside").toPath(), preserved.toPath())

        DeveloperRuntimeInstaller.deleteWithoutFollowingLinks(doomed)

        assertFalse(doomed.exists())
        assertEquals("keep", sentinel.readText())
        DeveloperRuntimeInstaller.deleteWithoutFollowingLinks(root)
    }

    @Test
    fun preparedUpgradeBeforeFirstRenameKeepsOriginalTarget() {
        val files = Files.createTempDirectory("developer-prepared-test").toFile()
        val target = File(files, "usr")
        val staging = File(files, ".termux-installing")
        val marker = File(files, ".termux-rootfs.json")
        createValidRuntime(target, "old")
        createValidRuntime(File(staging, "usr"), "new")
        writeTransaction(files, "prepared", hadTarget = true)

        DeveloperRuntimeInstaller.recoverTransaction(files, target, marker)

        assertEquals("old", File(target, "identity").readText())
        assertFalse(staging.exists())
        assertFalse(File(files, ".termux-install-transaction.json").exists())
        DeveloperRuntimeInstaller.deleteWithoutFollowingLinks(files)
    }

    @Test
    fun preparedUpgradeRestoresStableBackupAfterInterruption() {
        val files = Files.createTempDirectory("developer-recovery-test").toFile()
        val target = File(files, "usr")
        val backup = File(files, ".termux-previous")
        val marker = File(files, ".termux-rootfs.json")
        createValidRuntime(backup, "old")
        createValidRuntime(target, "new")
        writeTransaction(files, "prepared", hadTarget = true)

        DeveloperRuntimeInstaller.recoverTransaction(files, target, marker)

        assertEquals("old", File(target, "identity").readText())
        assertFalse(backup.exists())
        assertFalse(File(files, ".termux-install-transaction.json").exists())
        DeveloperRuntimeInstaller.deleteWithoutFollowingLinks(files)
    }

    @Test
    fun publishedUpgradeCommitsMarkerAndRemovesBackup() {
        val files = Files.createTempDirectory("developer-commit-test").toFile()
        val target = File(files, "usr")
        val backup = File(files, ".termux-previous")
        val marker = File(files, ".termux-rootfs.json")
        createValidRuntime(backup, "old")
        createValidRuntime(target, "new")
        writeTransaction(files, "published", hadTarget = true)

        DeveloperRuntimeInstaller.recoverTransaction(files, target, marker)

        assertEquals("new", File(target, "identity").readText())
        assertFalse(backup.exists())
        val saved = JSONObject(marker.readText())
        assertEquals("v1", saved.getString("version"))
        assertEquals("a".repeat(64), saved.getString("archive_sha256"))
        DeveloperRuntimeInstaller.deleteWithoutFollowingLinks(files)
    }

    private fun createValidRuntime(root: File, identity: String) {
        File(root, "bin").mkdirs()
        File(root, "lib").mkdirs()
        File(root, "bin/bash").writeText("bash")
        File(root, "bin/elixir").writeText("elixir")
        File(root, "bin/erl").writeText("erl")
        File(root, "bin/iex").writeText("iex")
        File(root, "bin/mix").writeText("mix")
        File(root, "bin/python").writeText("python")
        File(root, "bin/node").writeText("node")
        File(root, "lib/libtermux-exec.so").writeText("exec")
        File(root, "identity").writeText(identity)
    }

    private fun writeTransaction(files: File, state: String, hadTarget: Boolean) {
        File(files, ".termux-install-transaction.json").writeText(
            JSONObject()
                .put("version", "v1")
                .put("archive_sha256", "a".repeat(64))
                .put("state", state)
                .put("had_target", hadTarget)
                .toString(),
        )
    }
}
