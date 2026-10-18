package com.example.handbean_probe

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Settings-only action. Visual chrome is 36–40dp for a short line; the
 * clickable box is at least 48dp. Incoming [modifier] is parent extras
 * (weight / offset tracking) — not node padding — so min-height does not
 * stack on Mob text padding the way chat [button] nodes do.
 */
@Composable
fun SettingsButton(
    node: MobNode,
    modifier: Modifier = Modifier,
    onTap: (Int) -> Unit = { MobBridge.nativeSendTap(it) },
) {
    val label = node.props["text"] as? String ?: ""
    val tapHandle = (node.props["on_tap"] as? Number)?.toInt()
    val buttonId = node.props["id"] as? String
    val fillWidth = node.props["fill_width"] == true
    val textSize = (node.props["text_size"] as? Number)?.toFloat()?.sp ?: 13.sp
    val textColor = colorPropValue(node.props["text_color"], Color(0xFF1A1815))
    val background = colorPropValue(node.props["background"], Color(0xFFF4F3F0))
    val borderColor = colorPropValue(node.props["border_color"], Color.Unspecified)
    val borderWidth = (node.props["border_width"] as? Number)?.toFloat() ?: 0f
    val radius = (node.props["corner_radius"] as? Number)?.toFloat() ?: 8f
    val shape = RoundedCornerShape(radius.dp)
    val align = when (node.props["text_align"] as? String) {
        "center" -> TextAlign.Center
        "right" -> TextAlign.End
        else -> TextAlign.Start
    }
    val disabled = node.props["disabled"] == true

    val hitModifier = modifier
        .then(if (fillWidth) Modifier.fillMaxWidth() else Modifier)
        .heightIn(min = 48.dp)
        .then(if (buttonId != null) Modifier.testTag(buttonId) else Modifier)
        .semantics { role = Role.Button }
        .clickable(enabled = !disabled && tapHandle != null) {
            tapHandle?.let(onTap)
        }

    Box(modifier = hitModifier, contentAlignment = Alignment.Center) {
        var chrome = Modifier
            .then(if (buttonId != null) Modifier.testTag("$buttonId-chrome") else Modifier)
            .then(if (fillWidth) Modifier.fillMaxWidth() else Modifier.widthIn(min = 48.dp))
            .heightIn(min = 36.dp)
            .clip(shape)
            .background(background, shape)
        if (borderColor != Color.Unspecified && borderWidth > 0f) {
            chrome = chrome.border(borderWidth.dp, borderColor, shape)
        }
        Box(
            modifier = chrome.padding(horizontal = 12.dp, vertical = 8.dp),
            contentAlignment = when (align) {
                TextAlign.Center -> Alignment.Center
                TextAlign.End -> Alignment.CenterEnd
                else -> Alignment.CenterStart
            },
        ) {
            Text(
                text = label,
                color = textColor,
                fontSize = textSize,
                textAlign = align,
                style = TextStyle(fontSize = textSize),
                overflow = TextOverflow.Clip,
                modifier = if (fillWidth) Modifier.fillMaxWidth() else Modifier,
            )
        }
    }
}

private fun colorPropValue(raw: Any?, fallback: Color): Color =
    when (raw) {
        is Number -> Color(raw.toLong())
        else -> fallback
    }
