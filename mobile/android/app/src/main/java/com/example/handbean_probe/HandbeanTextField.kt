package com.example.handbean_probe

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.*
import androidx.compose.ui.unit.sp

/** Compact native input using the same visual tokens as the LiveView composer. */
@Composable
fun HandbeanTextField(node: MobNode, modifier: Modifier) {
    var value by remember(node.props["value"], MobBridge.LocalSlotEpoch.current) {
        mutableStateOf(node.props["value"] as? String ?: "")
    }
    val secure = node.props["secure"] == true
    val multiline = node.props["multiline"] == true
    BasicTextField(
        value = value,
        onValueChange = {
            value = it
            (node.props["on_change"] as? Number)?.toInt()?.let { handle ->
                MobBridge.nativeSendChangeStr(handle, it)
            }
        },
        modifier = modifier,
        textStyle = TextStyle(color = Color(0xFF1A1815), fontSize = if (multiline) 16.sp else 13.sp),
        cursorBrush = SolidColor(Color(0xFF1A1815)),
        singleLine = !multiline,
        maxLines = if (multiline) 5 else 1,
        visualTransformation = if (secure) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(
            keyboardType = if (secure) KeyboardType.Password else if (node.props["keyboard"] == "url") KeyboardType.Uri else KeyboardType.Text,
            imeAction = if (node.props["return_key"] == "send") ImeAction.Send else ImeAction.Default
        ),
        keyboardActions = KeyboardActions(onSend = {
            (node.props["on_submit"] as? Number)?.toInt()?.let { MobBridge.nativeSendSubmit(it) }
        }),
        decorationBox = { inner ->
            Box {
                if (value.isEmpty()) Text(node.props["placeholder"] as? String ?: "",
                    color = Color(0xFF9C9590), fontSize = if (multiline) 16.sp else 13.sp)
                inner()
            }
        }
    )
}
