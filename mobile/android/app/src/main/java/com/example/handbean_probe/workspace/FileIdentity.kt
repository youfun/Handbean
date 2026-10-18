package com.example.handbean_probe.workspace

/**
 * Shared open identity for chat artifacts and the file tree.
 * Only metadata — file bytes are read on the Android side.
 */
data class FileIdentity(
    val workspaceId: String,
    val workspaceRoot: String,
    val relativePath: String,
    val requestId: String,
    val generation: Long,
    val displayName: String,
    val kind: String,
    val mime: String = "",
) {
    fun token(): String = "$workspaceId|$relativePath|$requestId|$generation"
}
