package com.ftester.e2ex.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.TaggedText
import kotlin.math.roundToInt

private const val ROW_HEIGHT_DP = 56

// Compose/Foundation に並べ替えの定番コンポーネントは無い(契約 §並べ替え)ので、
// 長押し+ドラッグ+しきい値超えで自前実装。1回の pointer イベントが複数スロットぶんの移動量を
// 運んできても while で連続してホップし、指の下のスロットへ即座に確定する(補間しない・
// 1回のイベントで1ホップだけだと合成ドラッグの大きな move で入れ替えが1回に留まって不整合になる)。
@Composable
fun ReorderScreen() {
    val order = remember { mutableStateOf(listOf(1, 2, 3, 4, 5)) }
    var draggingValue by remember { mutableStateOf<Int?>(null) }
    var dragOffsetPx by remember { mutableStateOf(0f) }
    val density = LocalDensity.current
    val rowHeightPx = with(density) { ROW_HEIGHT_DP.dp.toPx() }

    Column(modifier = Modifier.padding(16.dp)) {
        TaggedText(Tags.REORDER_RESULT, "order=" + order.value.joinToString(","))
        Column {
            order.value.forEach { value ->
                val offsetY = if (draggingValue == value) dragOffsetPx.roundToInt() else 0
                ListItem(
                    headlineContent = { Text(Tags.reorderRowLabel(value)) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(ROW_HEIGHT_DP.dp)
                        .offset { IntOffset(0, offsetY) }
                        .background(
                            if (draggingValue == value) MaterialTheme.colorScheme.surfaceVariant
                            else MaterialTheme.colorScheme.surface
                        )
                        .testTag(Tags.reorderRow(value))
                        .pointerInput(value) {
                            detectDragGesturesAfterLongPress(
                                onDragStart = { draggingValue = value; dragOffsetPx = 0f },
                                onDragEnd = { draggingValue = null; dragOffsetPx = 0f },
                                onDragCancel = { draggingValue = null; dragOffsetPx = 0f }
                            ) { change, dragAmount ->
                                change.consume()
                                dragOffsetPx += dragAmount.y
                                while (true) {
                                    val current = order.value.indexOf(value)
                                    if (dragOffsetPx > rowHeightPx / 2 && current < order.value.size - 1) {
                                        order.value = order.value.toMutableList().apply {
                                            removeAt(current)
                                            add(current + 1, value)
                                        }
                                        dragOffsetPx -= rowHeightPx
                                    } else if (dragOffsetPx < -rowHeightPx / 2 && current > 0) {
                                        order.value = order.value.toMutableList().apply {
                                            removeAt(current)
                                            add(current - 1, value)
                                        }
                                        dragOffsetPx += rowHeightPx
                                    } else {
                                        break
                                    }
                                }
                            }
                        }
                )
            }
        }
    }
}
