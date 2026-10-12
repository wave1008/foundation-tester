package com.ftester.e2e.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Button
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.material3.Text
import androidx.compose.ui.unit.dp
import com.ftester.e2e.Tags
import com.ftester.e2e.ui.TaggedButton
import com.ftester.e2e.ui.TaggedText
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

// ティッカーの周期(ms)。シナリオの静止の窓 0.5 秒より十分短く、動作中は窓あたり 5 回変わって静止が成立しない
private const val TICKER_INTERVAL_MS = 100L

@Composable
fun ScrollScreen() {
    var selected by remember { mutableStateOf("-") }
    var tagSelected by remember { mutableStateOf("-") }
    val listState = rememberLazyListState()
    val tagState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    var tickerRunning by remember { mutableStateOf(false) }
    var ticker by remember { mutableStateOf(0) }
    // アニメーション API でなくコルーチンの delay で回す(アニメ無効設定で止まらない)。画面を離れる/停止で取り消される
    LaunchedEffect(tickerRunning) {
        while (tickerRunning) {
            delay(TICKER_INTERVAL_MS)
            ticker++
        }
    }

    // ScreenColumn は使わず自前で組む: LazyColumn を weight で残り高さいっぱいに伸ばすため。
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        // #txt_ticker は selected の横に置く(縦に足すとリストが縮む)
        Row(verticalAlignment = Alignment.CenterVertically) {
            TaggedText(Tags.TXT_ROW_SELECTED, "selected=$selected")
            Spacer(Modifier.width(12.dp))
            TaggedText(Tags.TXT_TICKER, "ticker=$ticker")
        }
        // #txt_scroll_top はボタンの横に置く(縦に足すとリストが縮み、契約の「#row_08 まで完全に見える」が崩れる)
        Row(verticalAlignment = Alignment.CenterVertically) {
            TaggedButton(Tags.BTN_SCROLL_TOP, "先頭へ") {
                scope.launch { listState.animateScrollToItem(0) }
            }
            Spacer(Modifier.width(12.dp))
            TaggedText(Tags.TXT_SCROLL_TOP, "top=" + Tags.row(listState.firstVisibleItemIndex + 1))
            Spacer(Modifier.width(8.dp))
            // 360dp 幅で 1 行に収めるため横パディングを詰める(TaggedButton は contentPadding を持たない)
            Button(
                onClick = { tickerRunning = !tickerRunning },
                modifier = Modifier.testTag(Tags.BTN_TICKER_TOGGLE).heightIn(min = 48.dp),
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)
            ) {
                Text(if (tickerRunning) "ティッカー停止" else "ティッカー開始")
            }
        }
        // スコープセレクタ(`#list_rows >> ...`)の容器
        LazyColumn(state = listState,
                   modifier = Modifier.weight(1f).testTag(Tags.LIST_ROWS)) {
            items(Tags.ROW_COUNT) { index ->
                val n = index + 1
                // 56dp 未満だと Compose iOS の高密度スクロールで frame がクランプされ tap が外れる(契約 §全体規約)。
                TaggedButton(
                    tag = Tags.row(n),
                    label = Tags.rowLabel(n),
                    modifier = Modifier.fillMaxWidth().height(56.dp)
                ) {
                    selected = Tags.row(n)
                }
            }
        }
        // 横スクロールの検証材料(scrollFrame)。**リストの下に置く** —— 画面中央に置くと
        // 領域を指定しない従来スクロール(画面中央基準)がカルーセルに吸われる。
        // **1画面に 3〜4 個しか入らない幅**にする ——
        // 全部見えていると「横スクロールした」ことを不在で検証できない。
        // 並びは**カルーセル → その下にテキスト**(4 SUT 共通の契約。相対セレクタ
        // :above/:below を使うシナリオが SUT で割れないため)
        LazyRow(state = tagState,
                modifier = Modifier.fillMaxWidth().height(60.dp).testTag(Tags.CAROUSEL_TAGS)) {
            items(Tags.TAG_COUNT) { index ->
                val n = index + 1
                TaggedButton(
                    tag = Tags.tag(n),
                    label = Tags.tagLabel(n),
                    modifier = Modifier.width(120.dp).height(56.dp)
                ) {
                    tagSelected = Tags.tag(n)
                }
            }
        }
        TaggedText(Tags.TXT_TAG_SELECTED, "tag=$tagSelected")
    }
}
