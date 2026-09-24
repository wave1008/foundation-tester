package com.ftester.e2e.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.ftester.e2e.Tags
import com.ftester.e2e.ui.TaggedButton
import com.ftester.e2e.ui.TaggedText
import kotlin.math.abs
import kotlin.math.round

/** 軸ごとの向き。8px 未満は none(手ぶれを斜めと誤判定しないため。契約は docs/ui-contract.md) */
private const val PAN_THRESHOLD = 8f

/** 倍率の不感帯。ピンチ以外の操作で拾う微小な zoom を in/out と読まないため */
private const val ZOOM_DEAD_ZONE = 0.05f

// マップ系アプリの検証材料。**ジェスチャ画面とは別画面**にしてある: あちらの #pad_swipe は
// detectDragGestures で drag を消費して方向を決める作りで、同じ領域に変形ジェスチャを重ねると
// どちらかが空振りする。
// 値は全て累積(#btn_map_reset でだけ戻る)。1操作ごとに戻すと、ジェスチャ直後の snapshot が
// 間に合わなかったときに検証が落ちる。
@Composable
fun MapScreen() {
    var zoom by remember { mutableStateOf(1f) }
    var panX by remember { mutableStateOf(0f) }
    var panY by remember { mutableStateOf(0f) }
    var doubleCount by remember { mutableStateOf(0) }
    var dragCount by remember { mutableStateOf(0) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .testTag(Tags.PAD_MAP)
            // タップ検出を先に置く: detectTapGestures はドラッグに化けた時点で降りるので
            // 変形ジェスチャを食わない。逆順だと**ダブルタップが取れない**
            .pointerInput(Unit) {
                detectTapGestures(onDoubleTap = { doubleCount += 1 })
            }
            .pointerInput(Unit) {
                // 1本指でも pan が来る(= swipeBy の検証に使える)。zoom は2本指のときだけ 1 以外
                detectTransformGestures { _, pan, gestureZoom, _ ->
                    panX += pan.x
                    panY += pan.y
                    zoom *= gestureZoom
                }
            }
            // 連続ジェスチャの witness: 指を上げ切るまでが1回のドラッグかを数える。消費しない
            // (Initial pass を素通り観測するだけ)ので detectTapGestures/detectTransformGestures の
            // 消費を妨げない。しきい値未満(= タップ)は数えない。
            .pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                    val start = down.position
                    var maxDx = 0f
                    var maxDy = 0f
                    var anyPressed = true
                    while (anyPressed) {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        val primary = event.changes.firstOrNull { it.id == down.id }
                        if (primary != null) {
                            val dx = abs(primary.position.x - start.x)
                            val dy = abs(primary.position.y - start.y)
                            if (dx > maxDx) maxDx = dx
                            if (dy > maxDy) maxDy = dy
                        }
                        anyPressed = event.changes.any { it.pressed }
                    }
                    if (maxDx >= PAN_THRESHOLD || maxDy >= PAN_THRESHOLD) {
                        dragCount += 1
                    }
                }
            }
    ) {
        Text("マップ領域", modifier = Modifier.align(Alignment.Center))

        Column(
            modifier = Modifier.align(Alignment.TopEnd).padding(12.dp),
            horizontalAlignment = Alignment.End
        ) {
            TaggedText(Tags.TXT_ZOOM_DIR, "zoom=${zoomDirection(zoom)}")
            TaggedText(Tags.TXT_ZOOM, "zoom=${formatZoom(zoom)}")
            TaggedText(Tags.TXT_PAN, "pan=${panLabel(panX, panY)}")
            TaggedText(Tags.TXT_DOUBLE_COUNT, "double=$doubleCount")
            TaggedText(Tags.TXT_DRAG_COUNT, "drag=$dragCount")
        }

        TaggedButton(
            Tags.BTN_MAP_RESET,
            "マップクリア",
            modifier = Modifier.align(Alignment.BottomStart).fillMaxWidth(0.45f).padding(12.dp)
        ) {
            zoom = 1f
            panX = 0f
            panY = 0f
            doubleCount = 0
            dragCount = 0
        }
    }
}

private fun zoomDirection(zoom: Float): String = when {
    zoom > 1f + ZOOM_DEAD_ZONE -> "in"
    zoom < 1f - ZOOM_DEAD_ZONE -> "out"
    else -> "-"
}

/** 小数1桁。Kotlin/Native と JVM で書式が割れないよう round で作る(String.format は共通で使えない) */
private fun formatZoom(zoom: Float): String {
    val scaled = round(zoom * 10).toInt()
    return "${scaled / 10}.${scaled % 10}"
}

/** 指の移動方向。両軸とも非 none なら斜め(fleetest の swipeBy の検証材料) */
private fun panLabel(x: Float, y: Float): String {
    if (abs(x) < PAN_THRESHOLD && abs(y) < PAN_THRESHOLD) return "-"
    val horizontal = if (abs(x) < PAN_THRESHOLD) "none" else if (x < 0) "left" else "right"
    val vertical = if (abs(y) < PAN_THRESHOLD) "none" else if (y < 0) "up" else "down"
    return "$horizontal-$vertical"
}
