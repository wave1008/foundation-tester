package com.ftester.e2ex.screens

import androidx.compose.foundation.layout.Box
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.ScreenColumn
import com.ftester.e2ex.ui.TaggedButton
import com.ftester.e2ex.ui.TaggedText
import com.ftester.e2ex.util.exposeTestTagsAsResourceId

private val FRUITS = listOf(
    Tags.OPT_FRUIT_APPLE to "りんご",
    Tags.OPT_FRUIT_BANANA to "バナナ",
    Tags.OPT_FRUIT_CHERRY to "さくらんぼ",
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MenuScreen() {
    var menuExpanded by remember { mutableStateOf(false) }
    var menuResult by remember { mutableStateOf("none") }
    var fruitExpanded by remember { mutableStateOf(false) }
    var fruitLabel by remember { mutableStateOf("") }
    var fruitResult by remember { mutableStateOf("none") }

    ScreenColumn(scrollable = true) {
        // メニューはボタンと同じ Box に置く(置かないと親の Column に揃って画面下に出る)。
        Box {
            TaggedButton(Tags.BTN_OPEN_MENU, "メニューを開く") { menuExpanded = true }
            // DropdownMenu は別ウィンドウ。onDismissRequest は外側タップ/戻るだけを拾う
            // (項目選択は onClick 側で閉じるので dismissed と混同しない)。
            DropdownMenu(
                expanded = menuExpanded,
                onDismissRequest = {
                    menuExpanded = false
                    menuResult = "dismissed"
                },
                modifier = Modifier.exposeTestTagsAsResourceId()
            ) {
                DropdownMenuItem(
                    text = { Text("コピー") },
                    onClick = { menuExpanded = false; menuResult = "copy" },
                    modifier = Modifier.testTag(Tags.MENU_ITEM_COPY)
                )
                DropdownMenuItem(
                    text = { Text("共有") },
                    onClick = { menuExpanded = false; menuResult = "share" },
                    modifier = Modifier.testTag(Tags.MENU_ITEM_SHARE)
                )
                DropdownMenuItem(
                    text = { Text("削除") },
                    onClick = { menuExpanded = false; menuResult = "delete" },
                    modifier = Modifier.testTag(Tags.MENU_ITEM_DELETE)
                )
            }
        }
        TaggedText(Tags.MENU_RESULT, "menu=$menuResult")

        ExposedDropdownMenuBox(
            expanded = fruitExpanded,
            onExpandedChange = { fruitExpanded = it }
        ) {
            TextField(
                value = fruitLabel,
                onValueChange = {},
                readOnly = true,
                label = { Text("果物") },
                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = fruitExpanded) },
                modifier = Modifier
                    .menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable, true)
                    .testTag(Tags.FIELD_FRUIT)
            )
            ExposedDropdownMenu(
                expanded = fruitExpanded,
                onDismissRequest = { fruitExpanded = false },
                modifier = Modifier.exposeTestTagsAsResourceId()
            ) {
                FRUITS.forEach { (tag, label) ->
                    DropdownMenuItem(
                        text = { Text(label) },
                        onClick = {
                            fruitLabel = label
                            fruitResult = tag.removePrefix("opt_fruit_")
                            fruitExpanded = false
                        },
                        modifier = Modifier.testTag(tag)
                    )
                }
            }
        }
        TaggedText(Tags.FRUIT_RESULT, "fruit=$fruitResult")
    }
}
