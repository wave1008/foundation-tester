package com.ftester.e2ey.android.fragments

import android.os.Bundle
import android.text.SpannableString
import android.text.Spanned
import android.text.method.LinkMovementMethod
import android.text.style.ClickableSpan
import android.view.MotionEvent
import android.view.View
import android.widget.TextView
import androidx.fragment.app.Fragment
import com.ftester.e2ey.android.R

// A6: ClickableSpan + LinkMovementMethod。リンクは1つの TextView ノードの中の範囲で、子ノードにならない。
class LinksFragment : Fragment(R.layout.fragment_links) {

    private fun spanAt(tv: TextView, ev: MotionEvent): ClickableSpan? {
        val layout = tv.layout ?: return null
        val x = ev.x.toInt() - tv.totalPaddingLeft + tv.scrollX
        val y = ev.y.toInt() - tv.totalPaddingTop + tv.scrollY
        val line = layout.getLineForVertical(y)
        if (x < layout.getLineLeft(line) || x > layout.getLineRight(line)) return null
        val off = layout.getOffsetForHorizontal(line, x.toFloat())
        return (tv.text as Spanned).getSpans(off, off, ClickableSpan::class.java).firstOrNull()
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtResult = view.findViewById<TextView>(R.id.txt_links_result)
        txtResult.text = "link=none"

        fun linked(tv: TextView, full: String, links: List<Pair<String, String>>) {
            val s = SpannableString(full)
            for ((word, echo) in links) {
                val start = full.indexOf(word)
                s.setSpan(object : ClickableSpan() {
                    override fun onClick(widget: View) {
                        txtResult.text = "link=$echo"
                    }
                }, start, start + word.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            tv.text = s
            tv.movementMethod = LinkMovementMethod.getInstance()
        }

        linked(
            view.findViewById(R.id.txt_terms),
            "続行すると利用規約とプライバシーポリシーに同意したものとみなされます。",
            listOf("利用規約" to "terms", "プライバシーポリシー" to "privacy"),
        )
        linked(
            view.findViewById(R.id.txt_post),
            "@alice さんが https://example.com/a を共有しました",
            listOf("@alice" to "mention:alice", "https://example.com/a" to "url"),
        )
        val row = view.findViewById<TextView>(R.id.row_with_link)
        linked(row, "お知らせ: 詳細はこちら", listOf("こちら" to "inner"))
        // TextView は span を押しても View のクリック(行本体)も撃つので、押下位置が span 上なら行本体を撃たない。
        var onSpan = false
        row.setOnTouchListener { v, ev ->
            if (ev.actionMasked == MotionEvent.ACTION_DOWN) onSpan = spanAt(v as TextView, ev) != null
            false
        }
        row.setOnClickListener { if (!onSpan) txtResult.text = "link=row" }
    }
}
