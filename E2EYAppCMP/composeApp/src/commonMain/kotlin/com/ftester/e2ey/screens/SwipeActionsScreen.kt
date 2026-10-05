package com.ftester.e2ey.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.AnchoredDraggableState
import androidx.compose.foundation.gestures.DraggableAnchors
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.anchoredDraggable
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.gestures.animateTo
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.ftester.e2ey.ui.TaggedButton
import com.ftester.e2ey.ui.TaggedText
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

private enum class RowPos { Closed, Actions, Full, Pin }

// A4: AnchoredDraggable の自前スワイプ行。Closed / Actions(右側のボタン) / Full(行幅 = 即削除) / Pin(左側のボタン)。
// ボタンは該当の向きへ動いている間だけ木に出す(払うまで居ない)。
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SwipeRow(n: Int, onAction: (String) -> Unit, onDelete: () -> Unit) {
    val density = LocalDensity.current
    val actionsPx = with(density) { 160.dp.toPx() }
    val pinPx = with(density) { 80.dp.toPx() }
    val state = remember { AnchoredDraggableState(RowPos.Closed) }
    val scope = rememberCoroutineScope()
    var widthPx by remember { mutableStateOf(0f) }

    LaunchedEffect(widthPx) {
        if (widthPx > 0f) {
            state.updateAnchors(DraggableAnchors {
                RowPos.Closed at 0f
                RowPos.Actions at -actionsPx
                RowPos.Full at -widthPx
                RowPos.Pin at pinPx
            })
        }
    }
    val offset = if (state.offset.isNaN()) 0f else state.offset
    LaunchedEffect(state.settledValue) {
        if (state.settledValue == RowPos.Full) { onAction("row$n:delete"); onDelete() }
    }
    fun close() { scope.launch { state.animateTo(RowPos.Closed) } }

    Box(modifier = Modifier.fillMaxWidth().height(64.dp).onSizeChanged { widthPx = it.width.toFloat() }.testTag("sw_row_$n")) {
        if (offset < 0f) {
            Row(modifier = Modifier.align(Alignment.CenterEnd).fillMaxSize(), horizontalArrangement = Arrangement.End) {
                TaggedButton("btn_sw_archive_$n", "アーカイブ", Modifier.width(80.dp)) { onAction("row$n:archive"); close() }
                TaggedButton("btn_sw_delete_$n", "削除", Modifier.width(80.dp)) { onAction("row$n:delete"); onDelete() }
            }
        }
        if (offset > 0f) {
            Row(modifier = Modifier.align(Alignment.CenterStart).fillMaxSize()) {
                TaggedButton("btn_sw_pin_$n", "ピン留め", Modifier.width(80.dp)) { onAction("row$n:pin"); close() }
            }
        }
        Box(
            modifier = Modifier
                .offset { IntOffset(offset.roundToInt(), 0) }
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.surface)
                .anchoredDraggable(state, Orientation.Horizontal)
                .clickable {
                    if (state.settledValue == RowPos.Closed) onAction("row$n:open") else close()
                }
                .padding(horizontal = 16.dp),
            contentAlignment = Alignment.CenterStart
        ) { Text("スワイプ行 $n") }
    }
}

@Composable
private fun ReplyRow(n: Int, onReply: (String) -> Unit) {
    var dx by remember { mutableStateOf(0f) }
    var widthPx by remember { mutableStateOf(0f) }
    Box(modifier = Modifier.fillMaxWidth().height(56.dp).onSizeChanged { widthPx = it.width.toFloat() }) {
        Box(
            modifier = Modifier
                .offset { IntOffset(dx.roundToInt(), 0) }
                .fillMaxSize()
                .background(Color(0xFFF0F0F0))
                .testTag("reply_row_$n")
                .draggable(
                    orientation = Orientation.Horizontal,
                    state = rememberDraggableState { delta -> dx = (dx + delta).coerceAtLeast(0f) },
                    onDragStopped = {
                        if (dx > widthPx * 0.25f) onReply("reply_row_$n")
                        dx = 0f
                    }
                )
                .padding(horizontal = 16.dp),
            contentAlignment = Alignment.CenterStart
        ) { Text("返信行 $n") }
    }
}

@Composable
fun SwipeActionsScreen() {
    var rows by remember { mutableStateOf((1..6).toList()) }
    var result by remember { mutableStateOf("none") }
    var reply by remember { mutableStateOf("none") }
    Column(modifier = Modifier.fillMaxSize()) {
        Column(modifier = Modifier.fillMaxWidth().padding(16.dp, 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            TaggedText("txt_swipe_actions_result", "action=$result")
            TaggedText("txt_swipe_actions_count", "rows=${rows.size}")
            TaggedText("txt_reply_target", "reply=$reply")
        }
        Column(modifier = Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState())) {
            for (n in rows) {
                key(n) { SwipeRow(n, onAction = { result = it }, onDelete = { rows = rows - n }) }
            }
            for (n in 1..3) ReplyRow(n) { reply = it }
        }
    }
}
