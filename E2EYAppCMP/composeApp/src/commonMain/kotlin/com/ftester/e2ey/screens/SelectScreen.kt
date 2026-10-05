package com.ftester.e2ey.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.Button
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import com.ftester.e2ey.ui.TaggedButton
import com.ftester.e2ey.ui.TaggedText

private fun pad2(n: Int) = n.toString().padStart(2, '0')

// A5: 長押しで入る選択モード。選択状態は toggleable(Compose の標準の選択状態)で公開する。
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SelectScreen() {
    var rows by remember { mutableStateOf((1..20).toList()) }
    var selecting by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf(setOf<Int>()) }
    var result by remember { mutableStateOf("none") }

    fun leave() { selecting = false; selected = emptySet() }

    Column(modifier = Modifier.fillMaxSize()) {
        Column(modifier = Modifier.fillMaxWidth().padding(16.dp, 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            TaggedText("txt_select_mode", if (selecting) "mode=select" else "mode=normal")
            TaggedText("txt_select_count", "selected=${selected.size}")
            TaggedText("txt_select_result", "select=$result")
            Button(
                onClick = { if (selecting) leave() else selecting = true },
                modifier = Modifier.testTag("btn_edit").height(48.dp)
            ) { Text(if (selecting) "完了" else "編集") }
        }
        // 選択モードの間はアクションバーに置き換わる
        Row(
            modifier = Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (selecting) {
                TaggedButton("btn_sel_all", "すべて選択") { selected = rows.toSet() }
                TaggedButton("btn_sel_delete", "削除") {
                    result = "deleted:" + selected.sorted().joinToString(",") { pad2(it) }
                    rows = rows - selected
                    leave()
                }
                IconButton(
                    onClick = { leave() },
                    modifier = Modifier.testTag("btn_sel_cancel")
                ) { Text("×", modifier = Modifier.clearAndSetSemantics { contentDescription = "キャンセル" }) }
            } else {
                Text("項目一覧")
            }
        }
        LazyColumn(modifier = Modifier.weight(1f).fillMaxWidth()) {
            items(rows, key = { it }) { n ->
                val isSel = n in selected
                val rowMod = if (selecting) {
                    Modifier.toggleable(value = isSel, onValueChange = {
                        selected = if (isSel) selected - n else selected + n
                    })
                } else {
                    Modifier.combinedClickable(
                        onClick = { result = "open:sel_row_${pad2(n)}" },
                        onLongClick = { selecting = true; selected = setOf(n) }
                    )
                }
                Box(
                    modifier = Modifier.fillMaxWidth().height(56.dp)
                        .testTag("sel_row_${pad2(n)}")
                        .then(rowMod)
                        .padding(horizontal = 16.dp),
                    contentAlignment = Alignment.CenterStart
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        // 行頭の印は a11y から外す(外さないと行のラベルが「✓ 項目 05」になる)
                        if (selecting) Text(
                            if (isSel) "✓ " else "○ ",
                            modifier = Modifier.clearAndSetSemantics { }
                        )
                        Text("項目 ${pad2(n)}")
                    }
                }
            }
        }
    }
}
