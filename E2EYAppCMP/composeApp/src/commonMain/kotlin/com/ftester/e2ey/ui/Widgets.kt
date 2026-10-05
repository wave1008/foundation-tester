package com.ftester.e2ey.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp

// 全画面が直接呼ぶ共有 API。シグネチャ変更は全画面に波及する。

@Composable
fun TaggedButton(
    tag: String,
    label: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onClick: () -> Unit
) {
    // 48dp 下限: Compose iOS は高密度画面で frame がクランプされ、小さいボタンほど tap が外れる罠がある。
    Button(
        onClick = onClick,
        modifier = modifier.testTag(tag).heightIn(min = 48.dp),
        enabled = enabled
    ) {
        Text(label)
    }
}

@Composable
fun TaggedText(tag: String, text: String, modifier: Modifier = Modifier) {
    Text(text = text, modifier = modifier.testTag(tag))
}

// material-icons-core は依存に含めていない(文字グリフで代用)。実アプリの
// Icon(contentDescription = …) と同じ木にするため、グリフの文字は a11y から消して説明だけを載せる
// (消さないと iOS のラベルが「戻る, ←」になる)。
@Composable
fun TaggedIconButton(
    tag: String,
    contentDescription: String,
    glyph: String,
    modifier: Modifier = Modifier,
    onClick: () -> Unit
) {
    IconButton(
        onClick = onClick,
        modifier = modifier.testTag(tag)
    ) {
        Text(glyph, modifier = Modifier.clearAndSetSemantics { this.contentDescription = contentDescription })
    }
}

@Composable
fun SectionTitle(text: String) {
    Text(text = text, style = MaterialTheme.typography.titleMedium)
}

@Composable
fun ScreenColumn(
    scrollable: Boolean = true,
    content: @Composable ColumnScope.() -> Unit
) {
    val base = Modifier.fillMaxSize().padding(16.dp)
    Column(
        modifier = if (scrollable) base.verticalScroll(rememberScrollState()) else base,
        verticalArrangement = Arrangement.spacedBy(8.dp),
        content = content
    )
}
