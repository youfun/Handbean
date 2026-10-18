package com.example.handbean_probe

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.List
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch

private data class ChatNavItem(val id: String, val summary: String)

/** Native, pixel-addressable chat timeline with local floating message navigation. */
@Composable
fun NativeChatScroll(
    node: MobNode,
    modifier: Modifier = Modifier,
    onTopReached: (Int) -> Unit = { MobBridge.nativeSendTopReached(it) },
    renderChild: @Composable (MobNode) -> Unit,
) {
    val timelineId = node.props["id"] as? String ?: "chat-timeline"
    key(timelineId) {
        NativeChatScrollForTimeline(node, timelineId, modifier, onTopReached, renderChild)
    }
}

@Composable
private fun NativeChatScrollForTimeline(
    node: MobNode,
    timelineId: String,
    modifier: Modifier,
    onTopReached: (Int) -> Unit,
    renderChild: @Composable (MobNode) -> Unit,
) {
    val density = LocalDensity.current
    val nearBottomPx = with(density) { 64.dp.roundToPx() }
    val markerSlopPx = with(density) { 96.dp.roundToPx() }
    val scrollState = rememberScrollState()
    val scope = rememberCoroutineScope()
    val offsets = remember { mutableStateMapOf<String, Int>() }
    val users = node.children.mapNotNull { child ->
        val id = child.props["nav_user_id"] as? String ?: return@mapNotNull null
        ChatNavItem(id, child.props["nav_user_summary"] as? String ?: "")
    }
    var menuOpen by remember { mutableStateOf(false) }
    var previousMax by remember { mutableIntStateOf(0) }
    val historyBefore = node.props["history_before"] as? String
    val currentHistoryBefore by rememberUpdatedState(historyBefore)
    var previousHistoryBefore by remember(timelineId) { mutableStateOf(historyBefore) }
    val topHandle by rememberUpdatedState((node.props["on_top_reached"] as? Number)?.toInt())
    val currentOnTopReached by rememberUpdatedState(onTopReached)

    val handle = remember(timelineId) { MobBridge.scrollHandle(timelineId) }
    LaunchedEffect(handle, scrollState) {
        handle.scrollState = scrollState
        handle.horizontal = false
    }
    LaunchedEffect(scrollState) {
        var previous = scrollState.value
        snapshotFlow { scrollState.value }.drop(1).collectLatest { current ->
            if (current == 0 && previous > 0) {
                topHandle?.let(currentOnTopReached)
            }
            previous = current
        }
    }
    LaunchedEffect(scrollState) {
        snapshotFlow { scrollState.maxValue }.collectLatest { maximum ->
            if (maximum != Int.MAX_VALUE) {
                val prepended =
                    previousMax > 0 && maximum > previousMax &&
                        currentHistoryBefore != previousHistoryBefore
                val followedBeforeGrowth = previousMax == 0 ||
                    scrollState.value >= previousMax - nearBottomPx
                when {
                    prepended -> scrollState.scrollTo(
                        (scrollState.value + maximum - previousMax).coerceIn(0, maximum),
                    )
                    followedBeforeGrowth -> scrollState.scrollTo(maximum)
                }
                previousMax = maximum
                previousHistoryBefore = currentHistoryBefore
            }
        }
    }

    val awayFromBottom = scrollState.maxValue - scrollState.value > nearBottomPx
    val currentIndex = users.indexOfLast { (offsets[it.id] ?: Int.MAX_VALUE) <= scrollState.value + markerSlopPx }
        .coerceAtLeast(0)

    Box(modifier = modifier.fillMaxSize()) {
        Column(
            Modifier
                .fillMaxSize()
                .onGloballyPositioned { handle.viewportPx = it.size.height }
                .verticalScroll(scrollState),
        ) {
            node.children.forEach { child ->
                val userId = child.props["nav_user_id"] as? String
                Box(
                    Modifier.onGloballyPositioned { coordinates ->
                        if (userId != null) offsets[userId] = coordinates.positionInParent().y.toInt()
                    },
                ) { renderChild(child) }
            }
        }

        if (users.isNotEmpty() && (users.size >= 2 || awayFromBottom)) {
            Surface(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 12.dp, bottom = 12.dp)
                    .border(1.dp, Color(0xFFE4E0DA), RoundedCornerShape(20.dp)),
                shape = RoundedCornerShape(20.dp),
                color = Color.White,
                shadowElevation = 1.dp,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (users.size >= 2) {
                        ChatNavButton("chat-nav-toggle", "消息列表") { menuOpen = !menuOpen }
                        DropdownMenu(
                            expanded = menuOpen,
                            onDismissRequest = { menuOpen = false },
                            modifier = Modifier
                                .testTag("chat-nav-panel")
                                .background(Color(0xFFFAF9F7))
                                .widthIn(max = 300.dp)
                                .heightIn(max = 320.dp),
                        ) {
                            Text(
                                "${currentIndex + 1} / ${users.size}",
                                style = MaterialTheme.typography.labelMedium,
                                fontSize = 12.sp,
                                color = Color(0xFF6F6963),
                                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                            )
                            users.forEachIndexed { index, item ->
                                Row(
                                    Modifier
                                        .testTag("chat-nav-item-${item.id}")
                                        .background(
                                            if (index == currentIndex) Color(0xFFF0EEEA)
                                            else Color.Transparent,
                                        )
                                        .clickable {
                                            menuOpen = false
                                            offsets[item.id]?.let { target ->
                                                scope.launch {
                                                    scrollState.animateScrollTo(target.coerceIn(0, scrollState.maxValue))
                                                }
                                            }
                                        }
                                        .padding(horizontal = 16.dp, vertical = 12.dp),
                                ) {
                                    Text(
                                        "${if (index == currentIndex) "✓ " else ""}${index + 1}. ${item.summary}",
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        fontSize = 13.sp,
                                        lineHeight = 18.sp,
                                        color = Color(0xFF1A1815),
                                    )
                                }
                            }
                        }
                    }
                    if (awayFromBottom) {
                        ChatNavButton("chat-nav-bottom", "滚动到底部") {
                            scope.launch { scrollState.animateScrollTo(scrollState.maxValue) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ChatNavButton(tag: String, description: String, onClick: () -> Unit) {
    Box(
        Modifier
            .size(40.dp)
            .testTag(tag)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = if (tag == "chat-nav-toggle") Icons.Default.List else Icons.Default.ArrowDownward,
            contentDescription = description,
            modifier = Modifier.size(18.dp),
            tint = Color(0xFF333333),
        )
    }
}
