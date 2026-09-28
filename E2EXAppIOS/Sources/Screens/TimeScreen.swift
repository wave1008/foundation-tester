import SwiftUI

struct TimeScreen: View {
    private static let initialTime: Date = {
        var c = DateComponents()
        c.hour = 9; c.minute = 30
        return Calendar.current.date(from: c)!
    }()

    @State private var showPicker = false
    @State private var pendingTime = TimeScreen.initialTime
    @State private var result = "time=none"

    var body: some View {
        ScreenColumn {
            TaggedText(tag: Tags.txtTimeResult, text: result)
            TaggedButton(tag: Tags.btnOpenTime, label: "時刻を選ぶ") {
                pendingTime = TimeScreen.initialTime
                showPicker = true
            }
        }
        .screenTitleTag("時刻ピッカー")
        .sheet(isPresented: $showPicker) {
            VStack(spacing: 16) {
                // ja_JP ロケールの wheel ピッカーは 24 時間表記になる(契約どおり)。
                DatePicker("時刻", selection: $pendingTime, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .environment(\.locale, Locale(identifier: "ja_JP"))
                    .labelsHidden()
                HStack {
                    Button("キャンセル") {
                        result = "time=cancel"
                        showPicker = false
                    }
                    .accessibilityIdentifier(Tags.btnTimeCancel)
                    Spacer()
                    Button("OK") {
                        result = "time=" + TimeScreen.formatted(pendingTime)
                        showPicker = false
                    }
                    .accessibilityIdentifier(Tags.btnTimeOk)
                }
            }
            .padding(16)
            .presentationDetents([.medium])
        }
    }

    private static func formatted(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }
}
