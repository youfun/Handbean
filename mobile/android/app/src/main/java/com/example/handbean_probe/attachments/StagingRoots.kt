package com.example.handbean_probe.attachments

import java.io.File

object StagingRoots {
    fun controlledImport(cacheDir: String): String =
        File(cacheDir, "controlled_import").absolutePath

    fun shareIntake(filesDir: String): String =
        File(filesDir, ShareIntake.DIR_NAME).absolutePath
}
