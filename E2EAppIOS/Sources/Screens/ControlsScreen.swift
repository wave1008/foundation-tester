import SwiftUI

struct ControlsScreen: View {
    @State private var notify = false
    @State private var agree = false
    @State private var plan = "A"
    @State private var volume: Double = 50

    var body: some View {
        ScreenColumn {
            // ラベル Text とコントロール本体を別要素にする: タップ対象はコントロール本体のみ(ラベルは非対象)。
            HStack {
                Text("通知")
                Toggle("", isOn: $notify).labelsHidden().accessibilityIdentifier(Tags.swNotify)
            }
            TaggedText(tag: Tags.txtSwNotify, text: "notify=\(notify ? "on" : "off")")

            // iOS ネイティブにチェックボックスは無い。トグルボタンで代替する
            // (= ツリー上の型は Button。Compose 版の Checkbox とはここが違う)。
            HStack {
                Text("同意する")
                Button { agree.toggle() } label: {
                    // SF Symbol は既定で記号名("Square" 等)が a11y ラベルになる。
                    // radio_b/radio_c が同じ "Circle" になりラベルセレクタが曖昧になるため隠す。
                    Image(systemName: agree ? "checkmark.square.fill" : "square")
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                }
                .accessibilityIdentifier(Tags.cbAgree)
            }
            TaggedText(tag: Tags.txtCbAgree, text: "agree=\(agree)")

            // ラジオも iOS ネイティブには無いため単一選択ボタン3個で代替する(型は Button)。
            planRow("A", tag: Tags.radioA, label: "プランA")
            planRow("B", tag: Tags.radioB, label: "プランB")
            planRow("C", tag: Tags.radioC, label: "プランC")
            TaggedText(tag: Tags.txtRadio, text: "plan=\(plan)")

            // step 25: 0...100 を 25 刻みの 5 段(0/25/50/75/100)にする契約値。
            Slider(value: $volume, in: 0...100, step: 25)
                .accessibilityIdentifier(Tags.sliderVolume)
            TaggedText(tag: Tags.txtSlider, text: "volume=\(Int(volume.rounded()))")

            TaggedButton(tag: Tags.btnControlsReset, label: "コントロールリセット") {
                notify = false
                agree = false
                plan = "A"
                volume = 50
            }
        }
    }

    private func planRow(_ value: String, tag: String, label: String) -> some View {
        HStack {
            Text(label)
            Button { plan = value } label: {
                Image(systemName: plan == value ? "largecircle.fill.circle" : "circle")
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
            .accessibilityIdentifier(tag)
        }
    }
}

struct LifecycleScreen: View {
    @ObservedObject private var launch = LaunchCounter.shared
    @ObservedObject private var session = SessionCounter.shared

    var body: some View {
        ScreenColumn {
            TaggedText(tag: Tags.txtLaunchCount, text: "launch=\(launch.value)")
            TaggedText(tag: Tags.txtSessionCount, text: "session=\(session.value)")
            TaggedButton(tag: Tags.btnSessionInc, label: "セッション+1") { session.value += 1 }
            TaggedButton(tag: Tags.btnResetPersisted, label: "永続カウンタをリセット") { launch.reset() }
            TaggedText(tag: Tags.txtPlatform, text: "platform=iOS")
        }
    }
}
