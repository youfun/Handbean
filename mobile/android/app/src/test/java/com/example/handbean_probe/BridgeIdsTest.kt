package com.example.handbean_probe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pins the Kotlin side of the Elixir string contract. */
class BridgeIdsTest {
    @Test
    fun dismissApprovalMatchesElixirButtonTag() {
        // native_approval.ex: button(gettext("Later"), :dismiss_approval) → NativeUi.id/1 → Atom.to_string
        assertEquals("dismiss_approval", BridgeIds.Elements.DISMISS_APPROVAL)
    }

    @Test
    fun platformOpsMatchRequestModule() {
        // lib/handbean_probe/platform/request.ex op_name/1 + platform.ex literals
        val expected = setOf(
            "platform_import", "platform_export", "platform_share_snapshot",
            "platform_open_snapshot", "platform_open_url", "platform_save_snapshot",
            "platform_cleanup", "platform_cancel", "platform_pick_photos", "platform_share_discard",
            "platform_share_text", "platform_device_calendar", "platform_device_alarm",
            "platform_app_settings",
        )
        assertEquals(expected, BridgeIds.PlatformOps.all)
        assertEquals(expected.size, BridgeIds.PlatformOps.all.size)
    }

    @Test
    fun filePickKindsMatchNativeWorkspaceImport() {
        // native_workspace_import.ex send_picker([%{"kind" => ..., "request_id" => ...}])
        assertEquals("directory", BridgeIds.FilePick.KIND_DIRECTORY)
        assertEquals("cancel_directory", BridgeIds.FilePick.KIND_CANCEL_DIRECTORY)
        val json = """[{"kind":"directory","request_id":"imp_ab12"}]"""
        assertTrue(WorkspaceImport.isDirectoryPick(json))
        assertEquals("imp_ab12", WorkspaceImport.requestIdFromTypes(json))
        assertTrue(WorkspaceImport.isCancellation("""[{"kind":"cancel_directory","request_id":"imp_ab12"}]"""))
    }
}
