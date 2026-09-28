// キーボードを1度だけ出すための空の画面(ImeOnboarding.primeOnce が使う)。
// 入力欄を1つ置いてフォーカスを当てるだけ。ブリッジ(instrumentation)と同じプロセスで動くので、
// 終わらせるのは ImeOnboarding が `current` を通して行う
package com.example.ftbridge;

import android.app.Activity;
import android.os.Bundle;
import android.text.InputType;
import android.view.WindowManager;
import android.widget.EditText;

public class KeyboardPrimerActivity extends Activity {
    static volatile KeyboardPrimerActivity current;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        current = this;
        EditText field = new EditText(this);
        field.setInputType(InputType.TYPE_CLASS_TEXT);
        setContentView(field);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE);
        field.requestFocus();
    }

    @Override
    protected void onDestroy() {
        if (current == this) current = null;
        super.onDestroy();
    }
}
