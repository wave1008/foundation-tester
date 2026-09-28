import SwiftUI

struct DateScreen: View {
    // 契約の初期選択は UTC の 2026-01-15。カレンダー/表示も UTC に固定して、
    // 実行環境のタイムゾーンで表示月がずれないようにする。
    private static var utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private static let initialDate: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 1; c.day = 15
        return utcCalendar.date(from: c)!
    }()

    @State private var showPicker = false
    @State private var pendingDate = DateScreen.initialDate
    @State private var result = "date=none"

    var body: some View {
        ScreenColumn {
            TaggedText(tag: Tags.txtDateResult, text: result)
            TaggedButton(tag: Tags.btnOpenDate, label: "日付を選ぶ") {
                pendingDate = DateScreen.initialDate
                showPicker = true
            }
        }
        .screenTitleTag("日付ピッカー")
        .sheet(isPresented: $showPicker) {
            VStack(spacing: 16) {
                DatePicker("日付", selection: $pendingDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                    .labelsHidden()
                HStack {
                    Button("キャンセル") {
                        result = "date=cancel"
                        showPicker = false
                    }
                    .accessibilityIdentifier(Tags.btnDateCancel)
                    Spacer()
                    Button("OK") {
                        result = "date=" + DateScreen.formatted(pendingDate)
                        showPicker = false
                    }
                    .accessibilityIdentifier(Tags.btnDateOk)
                }
            }
            .padding(16)
            .presentationDetents([.medium, .large])
        }
    }

    private static func formatted(_ date: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
