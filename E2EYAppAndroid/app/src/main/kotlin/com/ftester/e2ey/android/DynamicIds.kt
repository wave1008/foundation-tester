package com.ftester.e2ey.android

import android.content.Context
import android.view.View

// アダプタが行へ割り当てる #id は res/values/ids.xml に静的宣言してある(View は resource-id を実行時生成できない)。
object DynamicIds {
    fun of(context: Context, name: String): Int {
        val id = context.resources.getIdentifier(name, "id", context.packageName)
        check(id != 0) { "id not declared in res/values/ids.xml: $name" }
        return id
    }

    // 宣言数を超えた行(送信で増えるチャット等)は id 無しにする。
    fun ofOrNone(context: Context, name: String): Int {
        val id = context.resources.getIdentifier(name, "id", context.packageName)
        return if (id == 0) View.NO_ID else id
    }
}

fun paddedName(prefix: String, n: Int, width: Int = 2): String = prefix + n.toString().padStart(width, '0')
