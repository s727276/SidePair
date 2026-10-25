import SwiftUI

struct TwoFactorChallengeView: View {
    let prompt: AppleTwoFactorPrompt
    let onAnswer: (String, String?, UInt32?) -> Void
    let onCancel: () -> Void
    @State private var code = ""

    private var request: AppleTwoFactorRequest { prompt.request }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.unknown
                 ? "Choose a verification method"
                 : (request.sms ? "Enter the text message code" : "Enter the trusted-device code"))
                .font(.title2.weight(.semibold))

            if let error = request.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if request.sms, let selectedID = request.selectedNumberId,
               let phone = request.numbers.first(where: { $0.id == selectedID }) {
                Text("A code was sent to \(phone.numberWithDialCode).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if !request.sms && !request.unknown {
                Text("Check a trusted Apple device for the verification code.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !request.unknown {
                TextField("Six-digit code", text: $code)
                    .font(.system(.title2, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Button("Verify code") {
                    onAnswer("code", code.trimmingCharacters(in: .whitespacesAndNewlines), nil)
                }
                .buttonStyle(.borderedProminent)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button("Send a code to a trusted device") {
                onAnswer("devices", nil, nil)
            }
            .buttonStyle(.bordered)

            ForEach(request.numbers) { number in
                Button("Text a code to ••\(number.lastTwoDigits)") {
                    onAnswer("sms", nil, number.id)
                }
                .buttonStyle(.bordered)
            }

            if !request.unknown {
                Button("Resend code") { onAnswer("resend", nil, nil) }
                    .buttonStyle(.bordered)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 300)
        .interactiveDismissDisabled()
    }
}
