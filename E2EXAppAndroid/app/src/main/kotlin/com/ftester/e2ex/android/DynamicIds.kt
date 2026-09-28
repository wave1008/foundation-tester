package com.ftester.e2ex.android

import android.content.Context

// 動的リスト行(row_sheet_00..29 等)は View が resource-id を実行時生成できないため
// res/values/ids.xml に静的宣言してある。ここは "名前 -> 整数 id" の解決だけを一箇所に集める
// (呼び出し側で N 個の R.id.* を書き並べる代わりに使う)。
object DynamicIds {
    fun of(context: Context, name: String): Int {
        val id = context.resources.getIdentifier(name, "id", context.packageName)
        check(id != 0) { "id not declared in res/values/ids.xml: $name" }
        return id
    }
}

fun paddedName(prefix: String, n: Int, width: Int = 2): String = prefix + n.toString().padStart(width, '0')
