import SwiftUI

/// Stepper の +/- は1部品(`stepper_qty`)に一体化しており、`btn_qty_plus`/`btn_qty_minus`
/// のような個別 id は存在しない(契約どおり。システム標準ラベルで表面化する)。
struct StepperScreen: View {
    @State private var qty = 1
    @State private var progress: Double = 0
    @State private var progressState = "progress=idle"
    @State private var isRunning = false

    var body: some View {
        ScreenColumn {
            Stepper("数量: \(qty)", value: $qty, in: 0...10)
                .accessibilityIdentifier(Tags.stepperQty)
            TaggedText(tag: Tags.txtQty, text: "qty=\(qty)")

            TaggedButton(tag: Tags.btnStartProgress, label: "進捗を開始") { start() }
            ProgressView(value: progress, total: 100)
                .accessibilityIdentifier(Tags.progressMain)
            TaggedText(tag: Tags.txtProgress, text: progressState)
            if isRunning {
                ProgressView()
                    .accessibilityIdentifier(Tags.spinnerBusy)
            }
        }
        .screenTitleTag("ステッパーと進捗")
    }

    private func start() {
        guard !isRunning else { return }
        isRunning = true
        progress = 0
        progressState = "progress=running"
        withAnimation(.linear(duration: 2.0)) { progress = 100 }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            isRunning = false
            progressState = "progress=done"
        }
    }
}
