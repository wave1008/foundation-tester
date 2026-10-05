import SwiftUI

/// A7: OTP は「見える 6 つの箱 + 隠れた入力欄 1 つ」(箱は入力欄ではない)。PIN は自前キーパッド(ソフトキーボードを使わない)。
struct PinScreen: View {
    @State private var otp = ""
    @State private var otpResult = "otp=none"
    @State private var pin = ""
    @State private var pinResult = "pin=none"
    @FocusState private var otpFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            EchoArea {
                TaggedText(tag: "txt_otp_result", text: otpResult)
                TaggedText(tag: "txt_pin_result", text: pinResult)
                TaggedText(tag: "txt_pin_len", text: "pin_len=\(pin.count)")
            }
            ScrollView {
                VStack(spacing: 20) {
                    otpView
                    pinView
                }
                .padding(16)
            }
        }
        .screenTitleTag("PIN と OTP")
    }

    private var otpView: some View {
        ZStack {
            TextField("", text: $otp)
                .keyboardType(.numberPad)
                .focused($otpFocused)
                .opacity(0.011)
                .frame(height: 44)
                .accessibilityIdentifier("field_otp")
                .onChange(of: otp) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(6))
                    if digits != new { otp = digits; return }
                    if digits.count == 6 {
                        Task {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            otpResult = "otp=\(digits)"
                            otp = ""
                        }
                    }
                }
            HStack(spacing: 8) {
                ForEach(1...6, id: \.self) { i in
                    let chars = Array(otp)
                    Text(i <= chars.count ? String(chars[i - 1]) : "")
                        .frame(width: 44, height: 52)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary))
                        .accessibilityIdentifier("otp_box_\(i)")
                }
            }
            .background(Color(.systemBackground))
            .onTapGesture { otpFocused = true }
        }
    }

    private var pinView: some View {
        VStack(spacing: 12) {
            Text(String(repeating: "●", count: pin.count))
                .frame(height: 28)
                .accessibilityIdentifier("pin_dots")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach([1, 2, 3, 4, 5, 6, 7, 8, 9], id: \.self) { d in key(d) }
                Color.clear.frame(height: 52)
                key(0)
                Button { if !pin.isEmpty { pin.removeLast() } } label: {
                    Image(systemName: "delete.left").frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("削除")
                .accessibilityIdentifier("key_del")
            }
            .frame(maxWidth: 280)
        }
    }

    private func key(_ d: Int) -> some View {
        Button {
            guard pin.count < 4 else { return }
            pin.append(String(d))
            if pin.count == 4 {
                pinResult = "pin=\(pin)"
                pin = ""
            }
        } label: {
            Text(String(d)).frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("key_\(d)")
    }
}
