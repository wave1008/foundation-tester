package com.ftester.e2ex.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.TaggedText
import com.ftester.e2ex.util.exposeTestTagsAsResourceId

private val AUTO_CANDIDATES = listOf(
    Tags.AUTO_OPT_JAPAN to "Japan",
    Tags.AUTO_OPT_JAMAICA to "Jamaica",
    Tags.AUTO_OPT_JORDAN to "Jordan",
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InputsScreen() {
    var numberText by remember { mutableStateOf("") }
    var passwordText by remember { mutableStateOf("") }
    var multilineText by remember { mutableStateOf("") }
    var firstText by remember { mutableStateOf("") }
    var secondText by remember { mutableStateOf("") }
    var focusResult by remember { mutableStateOf("none") }
    var autoText by remember { mutableStateOf("") }
    var autoExpanded by remember { mutableStateOf(false) }
    var autoResult by remember { mutableStateOf("none") }
    var bottomText by remember { mutableStateOf("") }
    val secondFocusRequester = remember { FocusRequester() }
    val lineCount = if (multilineText.isEmpty()) 0 else multilineText.count { it == '\n' } + 1

    // echo は上端の固定領域にまとめる(スクロールしない・キーボードでも隠れない。契約 §入力の種類。
    // 欄はその下の imePadding つきスクロール領域に置く。フィールド側で個々に隠れても echo は常に読める)。
    Column(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            TaggedText(Tags.NUMBER_ECHO, "number=$numberText")
            TaggedText(Tags.PASSWORD_ECHO, "password_len=${passwordText.length}")
            TaggedText(Tags.MULTILINE_ECHO, "lines=$lineCount")
            TaggedText(Tags.FOCUS_ECHO, "focus=$focusResult")
            TaggedText(Tags.AUTO_ECHO, "auto=$autoResult")
            TaggedText(Tags.BOTTOM_ECHO, "bottom=$bottomText")
        }

        Column(
            modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()).imePadding().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            // オートコンプリートは欄の先頭に置く: CMP の iOS は候補(ExposedDropdownMenu)をソフトキーボードを避けずに欄の下へ
            // 出すので、下のほうの欄だとキーボードが出ている間は候補がキーボードの裏に入り、指では押せない
            // (XCUITest の tap はキーボードに当たる。送ると候補は閉じる)
            ExposedDropdownMenuBox(
                expanded = autoExpanded,
                onExpandedChange = { autoExpanded = it }
            ) {
                OutlinedTextField(
                    value = autoText,
                    onValueChange = {
                        autoText = it
                        autoExpanded = it.isNotEmpty()
                    },
                    label = { Text("国") },
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = autoExpanded) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .menuAnchor(ExposedDropdownMenuAnchorType.PrimaryEditable, true)
                        .testTag(Tags.FIELD_AUTO)
                )
                val filtered = AUTO_CANDIDATES.filter { (_, label) ->
                    label.startsWith(autoText, ignoreCase = true)
                }
                if (filtered.isNotEmpty()) {
                    ExposedDropdownMenu(
                        expanded = autoExpanded,
                        onDismissRequest = { autoExpanded = false },
                        modifier = Modifier.exposeTestTagsAsResourceId()
                    ) {
                        filtered.forEach { (tag, label) ->
                            DropdownMenuItem(
                                text = { Text(label) },
                                onClick = {
                                    autoText = label
                                    autoResult = label
                                    autoExpanded = false
                                },
                                modifier = Modifier.testTag(tag)
                            )
                        }
                    }
                }
            }

            OutlinedTextField(
                value = numberText,
                onValueChange = { numberText = it },
                label = { Text("数量") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.fillMaxWidth().testTag(Tags.FIELD_NUMBER)
            )

            OutlinedTextField(
                value = passwordText,
                onValueChange = { passwordText = it },
                label = { Text("パスワード") },
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                modifier = Modifier.fillMaxWidth().testTag(Tags.FIELD_PASSWORD)
            )

            OutlinedTextField(
                value = multilineText,
                onValueChange = { multilineText = it },
                label = { Text("メモ") },
                minLines = 3,
                modifier = Modifier.fillMaxWidth().testTag(Tags.FIELD_MULTILINE)
            )

            OutlinedTextField(
                value = firstText,
                onValueChange = { firstText = it },
                label = { Text("姓") },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
                keyboardActions = KeyboardActions(onNext = { secondFocusRequester.requestFocus() }),
                modifier = Modifier.fillMaxWidth().testTag(Tags.FIELD_FIRST)
            )
            OutlinedTextField(
                value = secondText,
                onValueChange = { secondText = it },
                label = { Text("名") },
                modifier = Modifier.fillMaxWidth()
                    .testTag(Tags.FIELD_SECOND)
                    .focusRequester(secondFocusRequester)
                    .onFocusChanged { if (it.isFocused) focusResult = "second" }
            )

            OutlinedTextField(
                value = bottomText,
                onValueChange = { bottomText = it },
                label = { Text("下の欄") },
                modifier = Modifier.fillMaxWidth().testTag(Tags.FIELD_BOTTOM)
            )
        }
    }
}
