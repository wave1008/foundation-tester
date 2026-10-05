package com.ftester.e2ey.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.BottomSheetScaffold
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberBottomSheetScaffoldState
import androidx.compose.material3.rememberStandardBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import com.ftester.e2ey.ui.TaggedButton
import com.ftester.e2ey.ui.TaggedText
import kotlinx.coroutines.launch

private fun pad2(n: Int) = n.toString().padStart(2, '0')

// A9: BottomSheetScaffold(常駐シート)。Material3 のシートは畳む(PartiallyExpanded)と全開(Expanded)の二段で、
// 半分は「畳んだ状態の peekHeight を 50% へ上げる」ことで作る(畳む → 半分はミニプレーヤーを押す・半分 → 畳むは #btn_player_collapse)。
// 全開からの下払いは畳む(64dp)へ戻る。半分から下へ払っても畳まれない(契約からの逸脱)。
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlayerScreen() {
    val sheetState = rememberStandardBottomSheetState(initialValue = SheetValue.PartiallyExpanded, skipHiddenState = true)
    val scaffoldState = rememberBottomSheetScaffoldState(bottomSheetState = sheetState)
    val scope = rememberCoroutineScope()
    var half by remember { mutableStateOf(false) }
    var playing by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf("none") }

    val stateText = when {
        sheetState.currentValue == SheetValue.Expanded -> "expanded"
        half -> "half"
        else -> "collapsed"
    }
    // 全開から畳む向きへ動いたら半分の印を落とす(peekHeight を 64dp に戻す)。
    if (sheetState.currentValue == SheetValue.Expanded && half) half = false

    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        val peek = if (half) maxHeight * 0.5f else 64.dp
        BottomSheetScaffold(
            scaffoldState = scaffoldState,
            sheetPeekHeight = peek,
            sheetSwipeEnabled = true,
            sheetContent = {
                Column(modifier = Modifier.fillMaxWidth()) {
                    Row(
                        modifier = Modifier.fillMaxWidth().height(64.dp).testTag("mini_player")
                            .clickable { if (sheetState.currentValue != SheetValue.Expanded) half = true }
                            .padding(horizontal = 16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        TaggedText("txt_mini_title", "再生中: トラック 1")
                        TaggedButton("btn_mini_play", if (playing) "一時停止" else "再生") {
                            playing = !playing
                            result = if (playing) "play" else "pause"
                        }
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth().height(64.dp).padding(horizontal = 16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        TaggedText("txt_player_title", "トラック 1")
                        IconButton(
                            onClick = { half = false; scope.launch { sheetState.partialExpand() } },
                            modifier = Modifier.testTag("btn_player_collapse")
                        ) { Text("⌄", modifier = Modifier.clearAndSetSemantics { contentDescription = "畳む" }) }
                    }
                    // 全開で画面を満たす高さ。畳み・半分のときは下側が画面外で、キューは木に居続ける。
                    LazyColumn(modifier = Modifier.fillMaxWidth().height(this@BoxWithConstraints.maxHeight - 128.dp).testTag("list_queue")) {
                        items(30) { n ->
                            Box(
                                modifier = Modifier.fillMaxWidth().height(56.dp)
                                    .testTag("queue_row_${pad2(n)}")
                                    .clickable { result = "queue:queue_row_${pad2(n)}" }
                                    .padding(horizontal = 16.dp),
                                contentAlignment = Alignment.CenterStart
                            ) { Text("キュー ${pad2(n)}") }
                        }
                    }
                }
            }
        ) { inner ->
            Column(modifier = Modifier.fillMaxSize().padding(inner)) {
                Column(modifier = Modifier.fillMaxWidth().padding(16.dp, 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    TaggedText("txt_sheet_state", "sheet=$stateText")
                    TaggedText("txt_player_result", "player=$result")
                }
                LazyColumn(modifier = Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(bottom = 8.dp)) {
                    items(40) { n ->
                        Box(
                            modifier = Modifier.fillMaxWidth().height(56.dp)
                                .testTag("row_main_${pad2(n)}")
                                .clickable { result = "main:row_main_${pad2(n)}" }
                                .padding(horizontal = 16.dp),
                            contentAlignment = Alignment.CenterStart
                        ) { Text("本文 ${pad2(n)}") }
                    }
                }
            }
        }
    }
}
