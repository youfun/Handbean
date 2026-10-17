package com.example.handbean_probe

/**
 * String contract shared with the Elixir side of Handbean Probe.
 *
 * Every literal here is matched byte-for-byte against something Elixir emits,
 * so keep the two in step:
 *
 * - [Elements]: `NativeUi.id/1` of a `button(..., :tag)` atom
 *   (`Atom.to_string/1`), e.g. `home_screen.ex` `@chat_taps`.
 * - [PlatformOps]: `"op"` values built by `HandbeanProbe.Platform.Request`
 *   (`lib/handbean_probe/platform/request.ex`) and consumed by `PlatformHost`.
 * - [FilePick]: `"kind"` values `NativeWorkspaceImport` sends through
 *   `Mob.Files.pick` for the SAF directory picker.
 * - [Types] / [Props]: product node types and props that `HandbeanRender`
 *   interprets on top of the stock Mob renderer.
 *
 * This file must stay free of Android imports so plain JUnit can load it.
 */
object BridgeIds {
    /** `props["id"]` values Kotlin searches for in the node tree. */
    object Elements {
        /** `button(gettext("Later"), :dismiss_approval)` in `native_approval.ex`. */
        const val DISMISS_APPROVAL = "dismiss_approval"
    }

    /** `payload["op"]` values for `MobBridge.platformCommand`. */
    object PlatformOps {
        const val IMPORT = "platform_import"
        const val EXPORT = "platform_export"
        const val SHARE_SNAPSHOT = "platform_share_snapshot"
        const val OPEN_SNAPSHOT = "platform_open_snapshot"
        const val OPEN_URL = "platform_open_url"
        const val SAVE_SNAPSHOT = "platform_save_snapshot"
        const val CLEANUP = "platform_cleanup"
        const val CANCEL = "platform_cancel"
        const val PICK_PHOTOS = "platform_pick_photos"
        const val SHARE_DISCARD = "platform_share_discard"
        const val SHARE_TEXT = "platform_share_text"
        const val DEVICE_CALENDAR = "platform_device_calendar"
        const val DEVICE_ALARM = "platform_device_alarm"
        const val APP_SETTINGS = "platform_app_settings"

        val all: Set<String> = setOf(
            IMPORT, EXPORT, SHARE_SNAPSHOT, OPEN_SNAPSHOT, OPEN_URL,
            SAVE_SNAPSHOT, CLEANUP, CANCEL, PICK_PHOTOS, SHARE_DISCARD, SHARE_TEXT,
            DEVICE_CALENDAR, DEVICE_ALARM, APP_SETTINGS,
        )
    }

    /** `Mob.Files.pick` type entries used by `NativeWorkspaceImport`. */
    object FilePick {
        const val KIND = "kind"
        const val REQUEST_ID = "request_id"
        const val KIND_DIRECTORY = "directory"
        const val KIND_CANCEL_DIRECTORY = "cancel_directory"
    }

    /** Product node types rendered by Handbean composables instead of stock Mob. */
    object Types {
        const val SETTINGS_SELECT = "settings_select"
        const val SETTINGS_BUTTON = "settings_button"
        const val FILE_VIEWER = "file_viewer"
        const val SCROLL = "scroll"
        const val TEXT = "text"
    }

    /** Product props layered on stock Mob nodes. */
    object Props {
        const val ID = "id"
        const val ON_TAP = "on_tap"
        const val ALIGN = "align"
        const val ALIGN_BASELINE = "baseline"
        const val BACKGROUND = "background"

        // HomeScreen shells (`home_screen/render.ex`, `native_approval.ex`).
        const val APPROVAL_DIALOG = "approval_dialog"
        const val HISTORY_SHELL = "history_shell"
        const val DRAWER_OPEN = "drawer_open"
        const val BACK_TARGET = "back_target"
        const val CHAT_NAVIGATION = "chat_navigation"

        // Scroll (`native_workspace_tree.ex`, `home_screen/render.ex`).
        const val RETAIN_SCROLL = "retain_scroll"
        const val STICK_TO_BOTTOM = "stick_to_bottom"

        // Text (`native_timeline.ex`).
        const val MARKDOWN = "markdown"
        const val MARKDOWN_STREAMING = "markdown_streaming"
        const val SELECTABLE = "selectable"

        // Text field (`native_ui.ex` `plain: true`).
        const val PLAIN = "plain"

        // Image (`native_local_image.ex`).
        const val LOCAL_ONLY = "local_only"
        const val UPLOAD_ONLY = "upload_only"
        const val MAX_DECODE_EDGE = "max_decode_edge"
        const val CONTENT_DESCRIPTION = "content_description"
        const val FALLBACK = "fallback"
    }
}
