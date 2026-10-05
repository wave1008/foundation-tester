package com.ftester.e2ey.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ftester.e2ey.ui.TaggedText

// A6: AnnotatedString + LinkAnnotation.Clickable。リンクは文(1つの Text)の中の部分範囲で、子ノードにはならない版がある。
@Composable
fun LinksScreen() {
    var result by remember { mutableStateOf("none") }
    val styles = TextLinkStyles(SpanStyle(color = Color(0xFF1565C0), textDecoration = TextDecoration.Underline))

    val terms = buildAnnotatedString {
        append("続行すると")
        withLink(LinkAnnotation.Clickable("terms", styles) { result = "terms" }) { append("利用規約") }
        append("と")
        withLink(LinkAnnotation.Clickable("privacy", styles) { result = "privacy" }) { append("プライバシーポリシー") }
        append("に同意したものとみなされます。")
    }
    val post = buildAnnotatedString {
        withLink(LinkAnnotation.Clickable("mention", styles) { result = "mention:alice" }) { append("@alice") }
        append(" さんが ")
        withLink(LinkAnnotation.Clickable("url", styles) { result = "url" }) { append("https://example.com/a") }
        append(" を共有しました")
    }
    val row = buildAnnotatedString {
        append("お知らせ: 詳細は")
        withLink(LinkAnnotation.Clickable("inner", styles) { result = "inner" }) { append("こちら") }
    }

    Column(modifier = Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        TaggedText("txt_links_result", "link=$result")
        Text(terms, fontSize = 13.sp, modifier = Modifier.fillMaxWidth().testTag("txt_terms"))
        Text(post, fontSize = 13.sp, modifier = Modifier.fillMaxWidth().testTag("txt_post"))
        Text(
            row,
            modifier = Modifier.fillMaxWidth().testTag("row_with_link").clickable { result = "row" }.padding(vertical = 12.dp)
        )
    }
}
