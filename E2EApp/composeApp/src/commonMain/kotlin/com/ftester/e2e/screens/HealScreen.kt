package com.ftester.e2e.screens

import androidx.compose.foundation.layout.Row
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
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
import com.ftester.e2e.util.Prefs

@Composable
fun HealScreen() {
    var schemaV1 by remember { mutableStateOf(Prefs.getBool("heal_schema_v1", true)) }
    var tapped by remember { mutableStateOf("-") }

    ScreenColumn(scrollable = true) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("旧ID(v1)を使う")
            Switch(
                checked = schemaV1,
                onCheckedChange = {
                    schemaV1 = it
                    Prefs.setBool("heal_schema_v1", it)
                },
                modifier = Modifier.testTag(Tags.SW_HEAL_SCHEMA)
            )
        }
        TaggedText(Tags.TXT_HEAL_SCHEMA, "schema=${if (schemaV1) "v1" else "v2"}")

        // ラベル固定・tag のみ切替がヒール検証の核: schema=v2 で id が解決不能でも、ラベル「修復対象」から FM が着地できるかを見る。
        TaggedButton(
            tag = if (schemaV1) Tags.BTN_HEAL_V1 else Tags.BTN_HEAL_V2,
            label = "修復対象"
        ) {
            tapped = if (schemaV1) "v1" else "v2"
        }
        TaggedText(Tags.TXT_HEAL_RESULT, "tapped=$tapped")
        TaggedButton(Tags.BTN_HEAL_RESET, "修復結果クリア") {
            tapped = "-"
        }
    }
}
