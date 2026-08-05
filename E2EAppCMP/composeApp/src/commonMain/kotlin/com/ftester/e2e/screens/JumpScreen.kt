package com.ftester.e2e.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.ftester.e2e.Tags
import com.ftester.e2e.ui.TaggedButton
import com.ftester.e2e.ui.TaggedText

// 飛び越し witness の寸法。**既定スワイプの始点を容器に乗せたうえで、移動量 > 容器 + 行**に
// する(どちらか一方でも崩れると witness が死ぬ):
//  - Android の既定スワイプは**画面 70% → 30%**(移動量 = 画面の 40%。BridgeRouter.java)。
//    容器が画面中央だと**指が容器に乗らず1ピクセルも動かない**(2026-08-06 に実測して作り直した)
//  - だから容器は下寄せ(上下の Spacer が 4:1)で、始点 70% を含む位置に置く
//  - 高さ 180dp(≒画面 20%)なら移動量(≒40%)との差が2行ぶん以上になり、
//    **jrow_05 / jrow_06 は上端でも下端でも一度もツリーに現れない**
// 行高 56dp は契約の下限(これ未満は Compose iOS で frame がクランプされ tap が外れる)
private val JUMP_CONTAINER_HEIGHT = 180.dp
private val JUMP_ROW_HEIGHT = 56.dp
private const val JUMP_ROW_COUNT = 12

@Composable
fun JumpScreen() {
    var selected by remember { mutableStateOf("-") }

    Column(Modifier.fillMaxSize().padding(16.dp)) {
        TaggedText(Tags.TXT_JUMP_SELECTED, "jumped=$selected")
        // 容器を**下寄せ**にする(上:下 = 4:1)。既定スワイプの始点は画面の 70% なので、
        // 中央に置くと指が容器に乗らない(= 何も動かず witness にならない)
        Spacer(Modifier.weight(4f))
        LazyColumn(
            modifier = Modifier.fillMaxWidth().height(JUMP_CONTAINER_HEIGHT).testTag(Tags.LIST_JUMP)
        ) {
            items(JUMP_ROW_COUNT) { index ->
                val n = index + 1
                TaggedButton(
                    tag = Tags.jrow(n),
                    label = Tags.jrowLabel(n),
                    modifier = Modifier.fillMaxWidth().height(JUMP_ROW_HEIGHT)
                ) {
                    selected = Tags.jrow(n)
                }
            }
        }
        Spacer(Modifier.weight(1f))
    }
}
