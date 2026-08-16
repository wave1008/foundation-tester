package com.ftester.e2e.screens

import androidx.compose.foundation.layout.Row
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.ftester.e2e.Tags
import com.ftester.e2e.ui.ScreenColumn
import com.ftester.e2e.ui.TaggedButton
import com.ftester.e2e.ui.TaggedText
import com.ftester.e2e.util.exposeTestTagsAsResourceId
import com.ftester.e2e.util.Prefs

@Composable
fun DialogScreen() {
    var result by remember { mutableStateOf("none") }
    var dialogOpen by remember { mutableStateOf(false) }
    var maybeCount by remember { mutableStateOf(0) }
    var auto by remember { mutableStateOf(Prefs.getBool("auto_dialog", false)) }

    // auto=true のとき、この画面に入るたびダイアログを自動で開く。
    LaunchedEffect(Unit) {
        if (auto) dialogOpen = true
    }

    ScreenColumn(scrollable = true) {
        TaggedText(Tags.TXT_DIALOG_RESULT, "dialog=$result")
        TaggedButton(Tags.BTN_SHOW_DIALOG, "ダイアログを開く") { dialogOpen = true }
        TaggedButton(Tags.BTN_MAYBE_DIALOG, "交互にダイアログ") {
            maybeCount++
            // 乱数不使用: 奇数回目だけ開く決定的な交互動作が検証要件。
            if (maybeCount % 2 == 1) dialogOpen = true
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("起動時ダイアログ")
            Switch(
                checked = auto,
                onCheckedChange = {
                    auto = it
                    Prefs.setBool("auto_dialog", it)
                },
                modifier = Modifier.testTag(Tags.SW_AUTO_DIALOG)
            )
        }
        TaggedText(Tags.TXT_AUTO_DIALOG, "auto=${if (auto) "on" else "off"}")
    }

    if (dialogOpen) {
        // ダイアログは**別ウィンドウ**に描画されるため App() ルートの
        // exposeTestTagsAsResourceId() が効かない。ここで再適用しないと Android では
        // ダイアログ内の testTag が resource-id 化されず #id を一切引けない(ラベルだけ残る)。
        AlertDialog(
            modifier = Modifier.exposeTestTagsAsResourceId(),
            onDismissRequest = { dialogOpen = false },
            title = { TaggedText(Tags.TXT_DIALOG_TITLE, "確認") },
            confirmButton = {
                TaggedButton(Tags.BTN_DIALOG_OK, "OK") {
                    result = "ok"
                    dialogOpen = false
                }
            },
            dismissButton = {
                TaggedButton(Tags.BTN_DIALOG_CANCEL, "キャンセル") {
                    result = "cancel"
                    dialogOpen = false
                }
            }
        )
    }
}
