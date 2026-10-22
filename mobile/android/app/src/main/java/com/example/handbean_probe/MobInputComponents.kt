package com.example.handbean_probe

import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

@Composable
internal fun MobButton(node: MobNode, modifier: Modifier) {
    val label       = node.props["text"] as? String ?: ""
    val tapHandle   = intProp(node.props, "on_tap")
    val bgColor     = colorProp(node.props, "background")
    val cornerRad   = floatProp(node.props, "corner_radius") ?: 0f

    val fillWidth = boolProp(node.props, "fill_width") ?: false

    val colors = if (bgColor != Color.Unspecified)
        ButtonDefaults.buttonColors(containerColor = bgColor)
    else
        ButtonDefaults.buttonColors()

    // fill_width and corner_radius are driven by Elixir props (set in component
    // defaults but overridable per-node). Shape overrides M3's stadium default.
    Button(
        onClick  = { tapHandle?.let { MobBridge.nativeSendTap(it) } },
        modifier = if (fillWidth) modifier.fillMaxWidth() else modifier,
        colors   = colors,
        shape    = RoundedCornerShape(cornerRad.dp),
    ) {
        val textColor = colorProp(node.props, "text_color")
        val fontSize  = sizeProp(node.props, "text_size")
        Text(text = label, color = textColor, fontSize = fontSize,
             maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
internal fun MobTextField(node: MobNode, modifier: Modifier) {
    if (HandbeanRender.renderPlainTextField(node, modifier)) return
    val changeHandle  = intProp(node.props, "on_change")
    val focusHandle   = intProp(node.props, "on_focus")
    val blurHandle    = intProp(node.props, "on_blur")
    val submitHandle  = intProp(node.props, "on_submit")
    val placeholder   = node.props["placeholder"] as? String ?: ""
    val keyboardController = LocalSoftwareKeyboardController.current

    val isSecure = boolProp(node.props, "secure") ?: false
    // `secure: true` overrides any explicit `keyboard:` choice — Compose's
    // PasswordVisualTransformation pairs naturally with KeyboardType.Password
    // (autocorrect off, no suggestions strip). Apps wanting numeric PINs that
    // still mask the input should layer their own masking on a Number keyboard.
    val keyboardType = if (isSecure) {
        KeyboardType.Password
    } else when (node.props["keyboard"] as? String) {
        "number"  -> KeyboardType.Number
        "decimal" -> KeyboardType.Decimal
        "email"   -> KeyboardType.Email
        "phone"   -> KeyboardType.Phone
        "url"     -> KeyboardType.Uri
        else      -> KeyboardType.Text
    }
    val imeAction = when (node.props["return_key"] as? String) {
        "next"   -> ImeAction.Next
        "go"     -> ImeAction.Go
        "search" -> ImeAction.Search
        "send"   -> ImeAction.Send
        else     -> ImeAction.Done
    }

    // Epoch in the key, because the composition survives navigation (MOB-146).
    // `node.props["value"]` alone re-seeds only when the incoming screen's
    // value DIFFERS — and two screens whose field is empty is the common case,
    // so a push would carry the user's typed text into the new screen's field.
    var localValue by remember(node.props["value"], MobBridge.LocalSlotEpoch.current) {
        mutableStateOf(node.props["value"] as? String ?: "")
    }

    // Only fill width when explicitly asked. The unconditional fillMaxWidth
    // we used to apply broke layouts like ImperialInput's row of three
    // text_fields — the first field swallowed all the row's width and the
    // siblings got 0 px (silently invisible).
    val fillWidth = boolProp(node.props, "fill_width") ?: false
    val tfModifier = if (fillWidth) modifier.fillMaxWidth() else modifier

    TextField(
        value         = localValue,
        onValueChange = { new ->
            localValue = new
            changeHandle?.let { MobBridge.nativeSendChangeStr(it, new) }
        },
        placeholder   = { Text(placeholder) },
        modifier      = tfModifier
            .onFocusChanged { state ->
                if (state.isFocused) focusHandle?.let { MobBridge.nativeSendFocus(it) }
                else                 blurHandle?.let  { MobBridge.nativeSendBlur(it)  }
            },
        singleLine      = boolProp(node.props, "multiline") != true,
        maxLines        = if (boolProp(node.props, "multiline") == true) 5 else 1,
        visualTransformation =
            if (isSecure) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType, imeAction = imeAction),
        keyboardActions = KeyboardActions(onAny = {
            submitHandle?.let { MobBridge.nativeSendSubmit(it) }
            // dismiss for terminal actions; Next intentionally keeps keyboard open
            if (imeAction != ImeAction.Next) keyboardController?.hide()
        }),
    )
}

@Composable
internal fun MobToggle(node: MobNode, modifier: Modifier) {
    val handle  = intProp(node.props, "on_change")
    val checked = boolProp(node.props, "value") ?: false
    val color   = colorProp(node.props, "color")
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically) {
        node.props["label"]?.let {
            Text(text = it as String, modifier = Modifier.weight(1f))
        }
        Switch(
            checked         = checked,
            onCheckedChange = { new -> handle?.let { MobBridge.nativeSendChangeBool(it, new) } },
            colors          = SwitchDefaults.colors(
                checkedThumbColor = Color.White,
                checkedTrackColor = if (color != Color.Unspecified) color else Color(0xFF1A1815),
                uncheckedThumbColor = Color(0xFF1A1815),
                uncheckedTrackColor = Color(0xFFE4E0DA),
            ),
        )
    }
}

@Composable
internal fun MobSlider(node: MobNode, modifier: Modifier) {
    val handle   = intProp(node.props, "on_change")
    val minVal   = floatProp(node.props, "min") ?: 0f
    val maxVal   = floatProp(node.props, "max") ?: 1f
    val color    = colorProp(node.props, "color")
    // Same reasoning as the text field: identical values across a navigation
    // would otherwise carry the old screen's thumb position into the new one.
    var localVal by remember(node.props["value"], MobBridge.LocalSlotEpoch.current) {
        mutableStateOf(floatProp(node.props, "value") ?: minVal)
    }
    Slider(
        value         = localVal,
        onValueChange = { new ->
            localVal = new
            handle?.let { MobBridge.nativeSendChangeFloat(it, new) }
        },
        valueRange    = minVal..maxVal,
        modifier      = modifier.fillMaxWidth(),
        colors        = if (color != Color.Unspecified)
            SliderDefaults.colors(thumbColor = color, activeTrackColor = color)
        else
            SliderDefaults.colors(),
    )
}
