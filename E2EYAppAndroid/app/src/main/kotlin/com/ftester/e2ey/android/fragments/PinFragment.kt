package com.ftester.e2ey.android.fragments

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.TextWatcher
import android.view.View
import android.widget.EditText
import android.widget.TextView
import androidx.fragment.app.Fragment
import com.ftester.e2ey.android.R

private const val OTP_LEN = 6
private const val PIN_LEN = 4
private const val OTP_SUBMIT_DELAY_MS = 300L

// A7: OTP は箱 6 つ(表示)+ 透明な入力欄 1 つ、PIN は IME を使わない自前キーパッド。
class PinFragment : Fragment(R.layout.fragment_pin) {

    private val handler = Handler(Looper.getMainLooper())

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtOtp = view.findViewById<TextView>(R.id.txt_otp_result)
        val txtPin = view.findViewById<TextView>(R.id.txt_pin_result)
        val txtLen = view.findViewById<TextView>(R.id.txt_pin_len)
        txtOtp.text = "otp=none"
        txtPin.text = "pin=none"
        txtLen.text = "pin_len=0"

        val boxes = intArrayOf(
            R.id.otp_box_1, R.id.otp_box_2, R.id.otp_box_3, R.id.otp_box_4, R.id.otp_box_5, R.id.otp_box_6,
        ).map { view.findViewById<TextView>(it) }
        val field = view.findViewById<EditText>(R.id.field_otp)
        field.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) {
                val digits = s?.toString().orEmpty()
                boxes.forEachIndexed { i, b -> b.text = digits.getOrNull(i)?.toString() ?: "" }
                if (digits.length == OTP_LEN) {
                    handler.postDelayed({
                        txtOtp.text = "otp=$digits"
                        field.text.clear()
                    }, OTP_SUBMIT_DELAY_MS)
                }
            }
        })

        val dots = view.findViewById<TextView>(R.id.pin_dots)
        val pin = StringBuilder()
        fun renderPin() {
            dots.text = "●".repeat(pin.length)
            txtLen.text = "pin_len=${pin.length}"
        }
        val keys = intArrayOf(
            R.id.key_0, R.id.key_1, R.id.key_2, R.id.key_3, R.id.key_4,
            R.id.key_5, R.id.key_6, R.id.key_7, R.id.key_8, R.id.key_9,
        )
        keys.forEachIndexed { digit, id ->
            view.findViewById<View>(id).setOnClickListener {
                if (pin.length >= PIN_LEN) return@setOnClickListener
                pin.append(digit)
                if (pin.length == PIN_LEN) {
                    txtPin.text = "pin=$pin"
                    pin.setLength(0)
                }
                renderPin()
            }
        }
        view.findViewById<View>(R.id.key_del).setOnClickListener {
            if (pin.isNotEmpty()) pin.setLength(pin.length - 1)
            renderPin()
        }
    }

    override fun onDestroyView() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroyView()
    }
}
