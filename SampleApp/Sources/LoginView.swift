import SwiftUI

struct LoginView: View {
    let onSuccess: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("サンプルショップ")
                    .font(.largeTitle.bold())
                    .padding(.top, 40)
                    .accessibilityIdentifier("app_title")

                TextField("メールアドレス", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .accessibilityIdentifier("email")

                SecureField("パスワード", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("password")

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("login_error")
                }

                Button("ログイン") {
                    if email == "test@example.com", password == "password123" {
                        errorMessage = nil
                        onSuccess()
                    } else {
                        errorMessage = "メールアドレスまたはパスワードが違います"
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("login_btn")

                Spacer()
            }
            .padding(.horizontal, 24)
            .navigationTitle("ログイン")
        }
    }
}
