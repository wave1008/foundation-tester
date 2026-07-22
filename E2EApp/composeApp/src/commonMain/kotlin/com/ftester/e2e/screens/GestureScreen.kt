package com.ftester.e2e.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.ftester.e2e.Tags
import com.ftester.e2e.ui.TaggedButton
import com.ftester.e2e.ui.TaggedText
import kotlin.math.abs

// ブリッジの swipe は画面比率の固定座標で撃たれる(要素を狙わない):
//   iOS(InAppBridge.swipeVector) 縦 0.15h↔0.85h / 横 0.15w↔0.85w(y=0.5h)
//   Android(BridgeRouter.handleSwipe) 縦 0.3h↔0.7h / 横 0.2w↔0.8w(y=0.5h)
// よって #pad_swipe は**コンテンツ領域いっぱい**に敷き、その上に操作要素を重ねる構成にする。
// 重ねてよいのは Text(ポインタを消費しない)だけ。ボタン類は始点を塞がないよう
// 「幅 45% 以内(中央列 x=0.5w を空ける)」かつ「上下の端(中央行 y=0.5h を空ける)」に置く。
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun GestureScreen() {
    var tap by remember { mutableStateOf(0) }
    var press by remember { mutableStateOf(0) }
    var swipeDir by remember { mutableStateOf("-") }
    var last by remember { mutableStateOf("-") }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .testTag(Tags.PAD_SWIPE)
            .pointerInput(Unit) {
                var dx = 0f
                var dy = 0f
                detectDragGestures(
                    onDragStart = { dx = 0f; dy = 0f },
                    onDragEnd = {
                        // 判定は指の移動方向(上へ払う = up)。ブリッジの direction 定義と一致させる契約。
                        swipeDir = if (abs(dx) > abs(dy)) {
                            if (dx < 0) "left" else "right"
                        } else {
                            if (dy < 0) "up" else "down"
                        }
                        last = "swipe"
                    }
                ) { change, dragAmount ->
                    change.consume()
                    dx += dragAmount.x
                    dy += dragAmount.y
                }
            }
    ) {
        Text("スワイプ領域", modifier = Modifier.align(Alignment.Center))

        // 上部左: タップ系。幅 45% で中央列を空ける。
        Column(
            modifier = Modifier.align(Alignment.TopStart).fillMaxWidth(0.45f).padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            TaggedButton(Tags.BTN_TAP_COUNTER, "タップ", modifier = Modifier.fillMaxWidth()) {
                tap += 1
                last = "tap"
            }
            // material3 Button は onLongClick を持たないため Box + combinedClickable で自作する。
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(56.dp)
                    .background(MaterialTheme.colorScheme.primary, RoundedCornerShape(8.dp))
                    .testTag(Tags.BTN_LONG_PRESS)
                    .combinedClickable(onClick = {}, onLongClick = { press += 1; last = "longpress" }),
                contentAlignment = Alignment.Center
            ) {
                Text("長押し", color = MaterialTheme.colorScheme.onPrimary)
            }
        }

        // 右上: 読み取り専用の表示。Text はポインタを消費しないのでパッドの上に重ねてよい。
        Column(
            modifier = Modifier.align(Alignment.TopEnd).padding(12.dp),
            horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            TaggedText(Tags.TXT_TAP_COUNT, "tap=$tap")
            TaggedText(Tags.TXT_PRESS_COUNT, "press=$press")
            TaggedText(Tags.TXT_SWIPE_DIR, "swipe=$swipeDir")
            TaggedText(Tags.TXT_LAST_GESTURE, "last=$last")
        }

        TaggedButton(
            Tags.BTN_GESTURE_RESET,
            "ジェスチャクリア",
            modifier = Modifier.align(Alignment.BottomStart).fillMaxWidth(0.45f).padding(12.dp)
        ) {
            tap = 0
            press = 0
            swipeDir = "-"
            last = "-"
        }
    }
}
