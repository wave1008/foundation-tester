package com.ftester.e2e.screens

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.ftester.e2e.Tags
import com.ftester.e2e.ui.ScreenColumn
import com.ftester.e2e.ui.TaggedButton
import com.ftester.e2e.ui.TaggedText

@Composable
fun SelectorScreen() {
    var result by remember { mutableStateOf("-") }

    ScreenColumn(scrollable = true) {
        TaggedText(Tags.SELECTOR_RESULT, "result=$result")

        // 「許可」⊂「通知を許可」の部分一致衝突は契約で意図的に作られた検証材料。
        TaggedButton(Tags.BTN_ALLOW, "許可") { result = "allow" }
        TaggedButton(Tags.BTN_ALLOW_NOTIFICATION, "通知を許可") { result = "allow_notification" }

        // 同一ラベル「項目」の3連。ラベル指定では曖昧・#id か .Type[n] でのみ引ける。
        TaggedButton(Tags.BTN_ITEM_1, "項目") { result = "item1" }
        TaggedButton(Tags.BTN_ITEM_2, "項目") { result = "item2" }
        TaggedButton(Tags.BTN_ITEM_3, "項目") { result = "item3" }

        TaggedText(Tags.TXT_SHARED_LABEL, "共通ラベル")
        TaggedButton(Tags.BTN_SHARED_LABEL, "共通ラベル") { result = "shared" }

        TaggedButton(Tags.BTN_ALIAS_NEW, "別名ボタン") { result = "alias" }

        TaggedButton(Tags.BTN_SELECTOR_RESET, "結果クリア") { result = "-" }

        // 700dp: 初期表示では絶対に画面内に入らない高さ(scrollTo / requireVisible の検証材料)。
        Spacer(modifier = Modifier.height(700.dp))
        TaggedText(Tags.TXT_OFFSCREEN, "画面外テキスト")
    }
}
