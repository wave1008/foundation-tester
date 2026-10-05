package com.ftester.e2ey.screens

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import com.ftester.e2ey.ui.TaggedButton
import com.ftester.e2ey.ui.TaggedText

private fun pad2(n: Int) = n.toString().padStart(2, '0')

// A10: nestedScroll で送りの向きを読み、上部バー・FAB・下部バーを平行移動で隠す(木には居続ける)。
// 隠れたバーが上の echo 領域へはみ出して覆わないよう、容器を clipToBounds で切る。
@Composable
fun HideBarsScreen() {
    var result by remember { mutableStateOf("none") }
    var hidden by remember { mutableStateOf(false) }
    val frac by animateFloatAsState(if (hidden) 1f else 0f)
    val density = LocalDensity.current
    val barPx = with(density) { 56.dp.toPx() }

    val connection = remember {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                // 内容が上へ動く(= 下へ送る)と隠れ、少しでも戻すと現れる
                if (available.y < -1f) hidden = true else if (available.y > 1f) hidden = false
                return Offset.Zero
            }
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        Column(modifier = Modifier.fillMaxWidth().padding(16.dp, 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            TaggedText("txt_hide_result", "hide=$result")
            TaggedText("txt_bars_state", if (hidden) "bars=hidden" else "bars=shown")
        }
        Box(modifier = Modifier.weight(1f).fillMaxWidth().clipToBounds().nestedScroll(connection)) {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(top = 56.dp, bottom = 56.dp)
            ) {
                items(60) { n ->
                    Box(
                        modifier = Modifier.fillMaxWidth().height(56.dp)
                            .testTag("row_h_${pad2(n)}")
                            .clickable { result = "row_h_${pad2(n)}" }
                            .padding(horizontal = 16.dp),
                        contentAlignment = Alignment.CenterStart
                    ) { Text("行 H${pad2(n)}") }
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth().height(56.dp).align(Alignment.TopStart)
                    .graphicsLayer { translationY = -barPx * frac }
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .testTag("bar_top_hiding")
                    .padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text("受信トレイ")
                TaggedButton("btn_top_action", "並べ替え") { result = "top_action" }
            }
            Row(
                modifier = Modifier.fillMaxWidth().height(56.dp).align(Alignment.BottomStart)
                    .graphicsLayer { translationY = barPx * frac }
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .testTag("bar_bottom_hiding")
                    .padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                TaggedButton("btn_bottom_a", "受信") { result = "bottom_a" }
                TaggedButton("btn_bottom_b", "フォルダ") { result = "bottom_b" }
            }
            FloatingActionButton(
                onClick = { result = "fab" },
                modifier = Modifier.align(Alignment.BottomEnd).padding(end = 16.dp, bottom = 72.dp)
                    .graphicsLayer { translationY = (barPx + with(density) { 88.dp.toPx() }) * frac }
                    .testTag("fab_hiding")
            ) { Text("+", modifier = Modifier.clearAndSetSemantics { contentDescription = "作成" }) }
        }
    }
}
