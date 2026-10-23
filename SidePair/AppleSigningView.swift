import SwiftUI

struct AppleSigningView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = AppleSigningModel()
    @State private var isPasswordVisible = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                privacyCard

                if let status = model.status {
                    accountStatusCard(status)
                } else {
                    appleIDField
                    passwordField
                    continueButton
                }

                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }

                if !model.hasSigningBridge {
                    Text("This preview build does not include the Apple signing engine. No credentials are sent or saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }

                footer
            }
            .padding(.horizontal, 22)
            .padding(.top, 32)
            .padding(.bottom, 20)
        }
        .background(Color(red: 0.94, green: 0.97, blue: 1).ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            tabBar
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(.clear)
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.light)
        .task { model.restoreSessionIfAvailable() }
        .sheet(item: $model.twoFactorPrompt) { prompt in
            TwoFactorChallengeView(prompt: prompt) { action, code, phoneID in
                model.respondToTwoFactor(action: action, code: code, phoneId: phoneID)
            } onCancel: {
                model.cancelTwoFactor()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Apple signing")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .tracking(-0.5)
                .foregroundStyle(Color(red: 0.08, green: 0.13, blue: 0.25))
            Text("Sign apps with your personal developer account")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }

    private var privacyCard: some View {
        VStack(spacing: 19) {
            Image(systemName: "lock.fill")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(Color(red: 0.53, green: 0.61, blue: 0.77))
                .frame(width: 112, height: 112)
                .background(Color(red: 0.93, green: 0.96, blue: 1), in: Circle())

            Text("Your sign-in and signing data\nstay on this iPhone.")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(red: 0.08, green: 0.13, blue: 0.25))
                .fixedSize(horizontal: false, vertical: true)

            Text("Your password is sent directly to Apple for authentication and is never stored by SidePair. The signing session and private key are protected on this iPhone; Anisette verification uses a remote provider.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 18)
        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.95), lineWidth: 1)
        }
        .shadow(color: .blue.opacity(0.06), radius: 18, y: 7)
    }

    private var appleIDField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Apple ID")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(red: 0.08, green: 0.13, blue: 0.25))
            TextField("name@example.com", text: $model.appleId)
                .font(.system(size: 17))
                .keyboardType(.emailAddress)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(model.isWorking)
        }
        .padding(.horizontal, 22)
        .frame(height: 86)
        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .stroke(.white.opacity(0.95), lineWidth: 1)
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Password")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(red: 0.08, green: 0.13, blue: 0.25))
            HStack(spacing: 10) {
                Group {
                    if isPasswordVisible {
                        TextField("Password", text: $model.password)
                    } else {
                        SecureField("••••••••", text: $model.password)
                    }
                }
                .font(.system(size: 17))
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(model.isWorking)

                Button {
                    isPasswordVisible.toggle()
                } label: {
                    Image(systemName: isPasswordVisible ? "eye" : "eye.slash")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
                .disabled(model.isWorking)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 86)
        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .stroke(.white.opacity(0.95), lineWidth: 1)
        }
    }

    private var continueButton: some View {
        Button(action: model.signIn) {
            HStack(spacing: 9) {
                if model.isWorking { ProgressView().tint(.white) }
                Text(model.isWorking ? "Signing in…" : "Continue")
                    .font(.system(size: 18, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(Color.blue, in: Capsule())
            .shadow(color: .blue.opacity(0.18), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(model.isWorking)
    }

    private func accountStatusCard(_ status: AppleSigningStatus) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Account connected", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            statusRow("Apple ID", value: status.appleId)
            statusRow("Developer team", value: "\(status.teamName) · \(status.teamId)")
            Divider()
            statusRow("Certificate", value: status.certificateName)
            statusRow("Certificate status", value: status.certificateStatus)
            if !status.certificateExpiration.isEmpty {
                statusRow("Certificate expires", value: status.certificateExpiration)
            }
            Divider()
            statusRow("Provisioning profile", value: status.profileStatus)
            if !status.profileUuid.isEmpty { statusRow("Profile ID", value: status.profileUuid) }
            if !status.profileExpiration.isEmpty { statusRow("Profile expires", value: status.profileExpiration) }
            if !status.profileError.isEmpty {
                Label(status.profileError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 25, style: .continuous))
    }

    private func statusRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private var footer: some View {
        Text("Apple may ask for a verification code. A free account can have signing limits.")
            .font(.system(size: 14))
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabItem("Pair", symbol: "rectangle.on.rectangle", selected: false) { dismiss() }
            tabItem("App Library", symbol: "square.stack.3d.up.fill", selected: true) {}
            tabItem("Settings", symbol: "gearshape", selected: false) {}
        }
        .padding(8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.8), lineWidth: 1) }
        .shadow(color: .black.opacity(0.08), radius: 14, y: 5)
    }

    private func tabItem(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? Color.blue : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background { if selected { Capsule().fill(.white.opacity(0.65)) } }
        }
        .buttonStyle(.plain)
        .disabled(selected)
    }
}

private struct TwoFactorChallengeView: View {
    let prompt: AppleTwoFactorPrompt
    let onAnswer: (String, String?, UInt32?) -> Void
    let onCancel: () -> Void
    @State private var code = ""

    private var request: AppleTwoFactorRequest { prompt.request }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text(request.unknown
                     ? "Choose a verification method"
                     : (request.sms ? "Enter the text message code" : "Enter the trusted-device code"))
                    .font(.title3.weight(.semibold))

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
                    Text("Check your trusted Apple device for a verification code.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !request.unknown {
                    TextField("6-digit code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.title2.monospacedDigit())
                        .padding(14)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Button("Verify code") { onAnswer("code", code, nil) }
                        .buttonStyle(.borderedProminent)
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Button("Send a code to a trusted device") { onAnswer("devices", nil, nil) }
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
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("Verify Apple ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
