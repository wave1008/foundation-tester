package com.ftester.e2e.android

import android.app.Activity
import android.text.Editable
import android.text.TextWatcher
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.TextView

private fun Activity.inflate(layout: Int, parent: ViewGroup): View =
    layoutInflater.inflate(layout, parent, false)

fun buildHomeScreen(activity: Activity, parent: ViewGroup, onNavigate: (Screen) -> Unit): View {
    val v = activity.inflate(R.layout.screen_home, parent)
    v.findViewById<Button>(R.id.nav_selector).setOnClickListener { onNavigate(Screen.SELECTOR) }
    v.findViewById<Button>(R.id.nav_input).setOnClickListener { onNavigate(Screen.INPUT) }
    v.findViewById<Button>(R.id.nav_gesture).setOnClickListener { onNavigate(Screen.GESTURE) }
    v.findViewById<Button>(R.id.nav_scroll).setOnClickListener { onNavigate(Screen.SCROLL) }
    v.findViewById<Button>(R.id.nav_async).setOnClickListener { onNavigate(Screen.ASYNC) }
    v.findViewById<Button>(R.id.nav_dialog).setOnClickListener { onNavigate(Screen.DIALOG) }
    v.findViewById<Button>(R.id.nav_lifecycle).setOnClickListener { onNavigate(Screen.LIFECYCLE) }
    v.findViewById<Button>(R.id.nav_heal).setOnClickListener { onNavigate(Screen.HEAL) }
    v.findViewById<Button>(R.id.nav_diagnostics).setOnClickListener { onNavigate(Screen.DIAGNOSTICS) }
    return v
}

fun buildSelectorScreen(activity: Activity, parent: ViewGroup): View {
    val v = activity.inflate(R.layout.screen_selector, parent)
    val result = v.findViewById<TextView>(R.id.txt_selector_result)
    fun set(value: String) { result.text = "result=$value" }

    v.findViewById<Button>(R.id.btn_allow).setOnClickListener { set("allow") }
    v.findViewById<Button>(R.id.btn_allow_notification).setOnClickListener { set("allow_notification") }
    v.findViewById<Button>(R.id.btn_item_1).setOnClickListener { set("item1") }
    v.findViewById<Button>(R.id.btn_item_2).setOnClickListener { set("item2") }
    v.findViewById<Button>(R.id.btn_item_3).setOnClickListener { set("item3") }
    v.findViewById<Button>(R.id.btn_shared_label).setOnClickListener { set("shared") }
    v.findViewById<Button>(R.id.btn_alias_new).setOnClickListener { set("alias") }
    v.findViewById<Button>(R.id.btn_selector_reset).setOnClickListener { set("-") }
    return v
}

fun buildInputScreen(activity: Activity, parent: ViewGroup): View {
    val v = activity.inflate(R.layout.screen_input, parent)
    val single = v.findViewById<EditText>(R.id.field_single)
    val password = v.findViewById<EditText>(R.id.field_password)
    val multiline = v.findViewById<EditText>(R.id.field_multiline)
    val echoSingle = v.findViewById<TextView>(R.id.txt_echo_single)
    val echoPassword = v.findViewById<TextView>(R.id.txt_echo_password)
    val echoMultiline = v.findViewById<TextView>(R.id.txt_echo_multiline)
    val echoLength = v.findViewById<TextView>(R.id.txt_echo_length)
    val submitted = v.findViewById<TextView>(R.id.txt_input_submitted)

    single.onTextChanged {
        echoSingle.text = "single=$it"
        echoLength.text = "len=${it.length}"
    }
    // パスワードは平文で echo する(検証用。実アプリでは絶対にやらない)。
    password.onTextChanged { echoPassword.text = "password=$it" }
    multiline.onTextChanged { echoMultiline.text = "multiline=${it.replace("\n", " ")}" }

    v.findViewById<Button>(R.id.btn_input_submit).setOnClickListener {
        submitted.text = "submitted=${single.text}"
    }
    v.findViewById<Button>(R.id.btn_input_clear).setOnClickListener {
        single.setText("")
        password.setText("")
        multiline.setText("")
        submitted.text = "submitted=-"
    }
    return v
}

private fun EditText.onTextChanged(block: (String) -> Unit) {
    addTextChangedListener(object : TextWatcher {
        override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
        override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
        override fun afterTextChanged(s: Editable?) { block(s?.toString() ?: "") }
    })
}

fun buildLifecycleScreen(activity: Activity, parent: ViewGroup): View {
    val v = activity.inflate(R.layout.screen_lifecycle, parent)
    val launch = v.findViewById<TextView>(R.id.txt_launch_count)
    val session = v.findViewById<TextView>(R.id.txt_session_count)
    fun render() {
        launch.text = "launch=${LaunchCounter.value}"
        session.text = "session=${SessionCounter.value}"
    }
    v.findViewById<Button>(R.id.btn_session_inc).setOnClickListener {
        SessionCounter.value += 1
        render()
    }
    v.findViewById<Button>(R.id.btn_reset_persisted).setOnClickListener {
        LaunchCounter.reset()
        render()
    }
    render()
    return v
}

fun buildHealScreen(activity: Activity, parent: ViewGroup): View {
    val v = activity.inflate(R.layout.screen_heal, parent)
    val sw = v.findViewById<androidx.appcompat.widget.SwitchCompat>(R.id.sw_heal_schema)
    val schema = v.findViewById<TextView>(R.id.txt_heal_schema)
    val v1 = v.findViewById<Button>(R.id.btn_heal_v1)
    val v2 = v.findViewById<Button>(R.id.btn_heal_v2)
    val result = v.findViewById<TextView>(R.id.txt_heal_result)

    // ラベルは不変(「修復対象」)で id だけが入れ替わるのがヒール検証の核。
    fun render(schemaV1: Boolean) {
        schema.text = "schema=${if (schemaV1) "v1" else "v2"}"
        v1.visibility = if (schemaV1) View.VISIBLE else View.GONE
        v2.visibility = if (schemaV1) View.GONE else View.VISIBLE
    }

    sw.isChecked = Prefs.getBool("heal_schema_v1", true)
    render(sw.isChecked)
    sw.setOnCheckedChangeListener { _, checked ->
        Prefs.setBool("heal_schema_v1", checked)
        render(checked)
    }
    v1.setOnClickListener { result.text = "tapped=v1" }
    v2.setOnClickListener { result.text = "tapped=v2" }
    v.findViewById<Button>(R.id.btn_heal_reset).setOnClickListener { result.text = "tapped=-" }
    return v
}
