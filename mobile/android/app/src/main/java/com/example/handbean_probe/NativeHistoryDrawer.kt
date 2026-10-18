package com.example.handbean_probe

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp

/** Keep the chat mounted, with a visible strip to dismiss the history drawer. */
@Composable
fun NativeHistoryDrawer(
    open: Boolean,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
    drawer: @Composable () -> Unit,
) {
    BackHandler(enabled = open, onBack = onDismiss)
    BoxWithConstraints(modifier.fillMaxSize()) {
        content()
        if (open) {
            Box(
                Modifier.fillMaxSize()
                    .testTag("history-scrim")
                    .background(Color.Black.copy(alpha = 0.08f))
                    .clickable(onClickLabel = "关闭对话列表", onClick = onDismiss)
            )
            Surface(
                modifier = Modifier
                    .width(minOf(maxWidth * 0.84f, 360.dp))
                    .fillMaxHeight()
                    .testTag("history-drawer"),
                color = Color(0xFFFAF9F7),
                shape = RoundedCornerShape(topEnd = 12.dp, bottomEnd = 12.dp),
                shadowElevation = 4.dp,
            ) { drawer() }
        }
    }
}
