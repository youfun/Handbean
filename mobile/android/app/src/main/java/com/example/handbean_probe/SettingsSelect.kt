package com.example.handbean_probe

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

data class SettingsSelectOption(
    val text: String,
    val id: String?,
    val tapHandle: Int?,
    val selected: Boolean,
)

fun settingsSelectOptions(node: MobNode): List<SettingsSelectOption> {
    return node.children.map { child ->
        SettingsSelectOption(
            text = child.props["text"] as? String ?: "",
            id = child.props["id"] as? String,
            tapHandle = (child.props["on_tap"] as? Number)?.toInt(),
            selected = child.props["selected"] == true,
        )
    }
}

/**
 * Material dropdown for settings. Parent node must not carry on_tap — opening
 * is local Compose state. Options keep the existing child on_tap handles.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsSelect(
    node: MobNode,
    modifier: Modifier = Modifier,
    onOptionTap: (Int) -> Unit = { MobBridge.nativeSendTap(it) },
) {
    var expanded by remember { mutableStateOf(false) }
    val value = node.props["text"] as? String ?: ""
    val iconDescription = node.props["icon_content_description"] as? String ?: "Open menu"
    val selectId = node.props["id"] as? String
    // Read children every composition. `remember(node)` can keep an empty
    // first-frame list when the same slot is reused across a setRoot, and
    // ExposedDropdownMenu then paints only the 16dp chrome.
    val options = settingsSelectOptions(node)
    val textSize = (node.props["text_size"] as? Number)?.toFloat()?.sp ?: 14.sp
    val compact = node.props["compact"] == true
    val fillWidth = node.props["fill_width"] == true
    val background = colorProp(node.props["background"], Color(0xFFF4F3F0))
    val borderColor = colorProp(node.props["border_color"], Color.Unspecified)
    val borderWidth = (node.props["border_width"] as? Number)?.toFloat() ?: 0f
    val radius = (node.props["corner_radius"] as? Number)?.toFloat() ?: 8f
    val horizontalPadding =
        (node.props["padding_left"] as? Number)?.toFloat()
            ?: (node.props["padding_right"] as? Number)?.toFloat()
            ?: 12f
    val shape = RoundedCornerShape(radius.dp)

    // Row+menuAnchor on this Material3 BOM does not consume KEYCODE_BACK.
    // Without this, system/Espresso back finishes the Activity instead of the menu.
    BackHandler(enabled = expanded) { expanded = false }

    ExposedDropdownMenuBox(
        modifier = modifier
            .then(if (fillWidth) Modifier.fillMaxWidth() else Modifier)
            .then(if (selectId != null) Modifier.testTag(selectId) else Modifier),
        expanded = expanded,
        onExpandedChange = { expanded = it },
    ) {
        Row(
            modifier = Modifier
                .menuAnchor()
                .then(if (compact) Modifier else Modifier.fillMaxWidth())
                .heightIn(min = 48.dp)
                .semantics {
                    role = Role.DropdownList
                },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            var chrome = Modifier
                .then(if (compact) Modifier else Modifier.fillMaxWidth())
                .heightIn(min = if (compact) 36.dp else 48.dp)
                .clip(shape)
                .background(background, shape)

            if (borderColor != Color.Unspecified && borderWidth > 0f) {
                chrome = chrome.border(borderWidth.dp, borderColor, shape)
            }

            Row(
                modifier = chrome.padding(horizontal = horizontalPadding.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = value,
                    modifier = if (compact) Modifier.widthIn(max = 120.dp) else Modifier.weight(1f),
                    style = MaterialTheme.typography.bodyMedium.copy(fontSize = textSize),
                    maxLines = if (compact) 1 else Int.MAX_VALUE,
                    overflow = TextOverflow.Ellipsis,
                )
                Icon(
                    imageVector = Icons.Filled.ArrowDropDown,
                    contentDescription = iconDescription,
                    modifier = if (compact) Modifier.size(18.dp) else Modifier,
                )
            }
        }
        // ExposedDropdownMenu applies exposedDropdownSize() against the
        // menuAnchor. That anchor is a clipped 48dp Row, so remaining height
        // is ~0 and the popup is a dark 16dp bar with no items. DropdownMenu
        // is a window Popup and keeps the child on_tap items visible.
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier
                .widthIn(min = 200.dp)
                .heightIn(max = 320.dp),
        ) {
            options.forEach { option ->
                DropdownMenuItem(
                    text = { Text(option.text) },
                    onClick = {
                        expanded = false
                        option.tapHandle?.let(onOptionTap)
                    },
                    trailingIcon = if (option.selected) {
                        { Icon(Icons.Filled.Check, contentDescription = null) }
                    } else {
                        null
                    },
                    modifier = Modifier
                        .then(if (option.id != null) Modifier.testTag(option.id) else Modifier)
                        .semantics { selected = option.selected },
                )
            }
        }
    }
}

private fun colorProp(raw: Any?, fallback: Color): Color =
    when (raw) {
        is Number -> Color(raw.toLong())
        else -> fallback
    }
