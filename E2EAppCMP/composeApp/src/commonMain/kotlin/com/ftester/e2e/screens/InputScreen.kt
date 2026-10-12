package com.ftester.e2e.screens

import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import com.ftester.e2e.Tags
import com.ftester.e2e.ui.ScreenColumn
import com.ftester.e2e.ui.TaggedButton
import com.ftester.e2e.ui.TaggedText

// レイアウトはソフトキーボードに支配される(実測。iPhone 17 Pro/iOS 27.0 で高さ 874、
// キーボード表示中に触れるのは概ね y<500 = タイトル下から約 384pt 分だけ)。制約は2つ:
//   1. scrollable=false。スクロール可だとフォーカス時の bringIntoView で列が動き、
//      次の入力欄がキーボード下へ回り込んで「ロケータを解決できません」になる。
//   2. シナリオが触る要素(echo・送信/クリア・単一行/パスワード欄)を**この 384pt に収める**。
//      複数行欄とその echo だけは折り返しの下でよい(シナリオが触らないため)。
// 送信/クリアを Row に並べているのはこの高さ予算を作るため。
// 背の低い iPhone(SE3・高さ 667)ではキーボード表示中に木に載るのは y<302 までで、パスワード欄・送信/クリアが
// 収まらない。iOS の Compose は hideKeyboard で閉じられないので、**入力欄の外(echo 等)を叩くとフォーカスを外して
// キーボードを閉じる**(実アプリで一般的な作り)。シナリオは iOS で `#txt_echo_single` を叩いてから撃つ。
// 欄・ボタンは自分でタップを消費するので、ここへは届かない(欄を叩いてもキーボードは閉じない)
@Composable
fun InputScreen() {
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    var single by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var multiline by remember { mutableStateOf("") }
    var submitted by remember { mutableStateOf("-") }
    // #field_single の IME アクション(検索)発火回数のみを数える。
    var imeCount by remember { mutableStateOf(0) }

    Box(Modifier.fillMaxSize().pointerInput(Unit) {
        detectTapGestures(onTap = {
            focusManager.clearFocus()
            keyboard?.hide()
        })
    }) {
        ScreenColumn(scrollable = false) {
            TaggedText(Tags.ECHO_SINGLE, "single=$single")
            TaggedText(Tags.ECHO_PASSWORD, "password=$password")
            TaggedText(Tags.ECHO_LENGTH, "len=${single.length}")
            TaggedText(Tags.IME_ACTION, "ime=$imeCount")
            TaggedText(Tags.TXT_INPUT_SUBMITTED, "submitted=$submitted")

            OutlinedTextField(
                value = single,
                onValueChange = { single = it },
                modifier = Modifier.fillMaxWidth().testTag(Tags.FIELD_SINGLE),
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { imeCount++ }),
                placeholder = { Text("単一行") }
            )
            OutlinedTextField(
                value = password,
                onValueChange = { password = it },
                modifier = Modifier.fillMaxWidth().testTag(Tags.FIELD_PASSWORD),
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                placeholder = { Text("パスワード") }
            )

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TaggedButton(Tags.BTN_INPUT_SUBMIT, "送信", modifier = Modifier.weight(1f)) {
                    submitted = single
                }
                TaggedButton(Tags.BTN_INPUT_CLEAR, "入力クリア", modifier = Modifier.weight(1f)) {
                    single = ""
                    password = ""
                    multiline = ""
                    submitted = "-"
                    imeCount = 0
                }
            }

            TaggedText(Tags.ECHO_MULTILINE, "multiline=${multiline.replace("\n", " ")}")
            OutlinedTextField(
                value = multiline,
                onValueChange = { multiline = it },
                modifier = Modifier.fillMaxWidth().testTag(Tags.FIELD_MULTILINE),
                minLines = 3,
                placeholder = { Text("複数行") }
            )
        }
    }
}
