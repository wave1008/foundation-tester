package com.ftester.e2e.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.Button
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.ftester.e2e.ui.ScreenColumn
import com.ftester.e2e.ui.SectionTitle

// 契約: docs/ui-contract.md「ID なし画面」。**この画面の要素に testTag を付けてはいけない**
// (方向セレクタだけで操作・検証できることを保証するための画面。付けた瞬間に検証にならない)。
// 行の高さ 48dp と行間は帯判定(:right が隣の行のスイッチを拾わない)の余裕として必要。
@Composable
fun NoIdScreen() {
    var notify by remember { mutableStateOf(false) }
    var location by remember { mutableStateOf(false) }
    var qty by remember { mutableStateOf(0) }

    ScreenColumn(scrollable = false) {
        SectionTitle("設定")

        ToggleRow("通知", notify) { notify = it }
        Text("notify=" + if (notify) "on" else "off")

        ToggleRow("位置情報", location) { location = it }
        Text("location=" + if (location) "on" else "off")

        Row(
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Button(onClick = { if (qty > 0) qty -= 1 }, modifier = Modifier.heightIn(min = 48.dp)) {
                Text("変更")
            }
            Text("数量")
            Button(onClick = { qty += 1 }, modifier = Modifier.heightIn(min = 48.dp)) {
                Text("変更")
            }
        }
        Text("qty=$qty")
    }
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(label)
        Switch(checked = checked, onCheckedChange = onChange)
    }
}
