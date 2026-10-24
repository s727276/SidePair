import SwiftUI

struct AppleSigningView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppleSigningModel
    @ObservedObject var connection: RSDConnectionModel
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
                    deviceRegistrationNote
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
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            tabBar
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(.clear)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { model.restoreSessionIfAvailable() }
        .sheet(item: $model.twoFactorPrompt) { prompt in
            TwoFactorChallengeView(prompt: prompt) { action, code, phoneID in
                model.respondToTwoFactor(action: action, code: code, phoneId: phoneID)
            } onCancel: {
                model.cancelTwoFactor()
            }
        }
        .sheet(item: $model.certificateRecoveryPrompt) { prompt in
            CertificateRecoveryView(
                prompt: prompt,
                isWorking: model.isWorking,
                onRevoke: { serialNumber in
                    model.revokeAndRetryCertificate(serialNumber: serialNumber)
                },
                onCancel: {
                    model.cancelCertificateRecovery()
                }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Apple signing")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .tracking(-0.5)
                .foregroundStyle(Color.primary)
            Text("Sign apps with your personal developer account")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }

    private var deviceRegistrationNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                isReadyForDeviceRegistration ? "iPhone connected" : "Connect this iPhone first",
                systemImage: isReadyForDeviceRegistration ? "checkmark.circle.fill" : "iphone.and.arrow.forward"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isReadyForDeviceRegistration ? Color.green : Color.orange)

            if let details = connection.deviceDetails {
                Text("\(details.name) · \(details.model)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Connect through LocalDevVPN before continuing. AquaSign registers this iPhone with Apple before requesting its app-specific provisioning profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var privacyCard: some View {
        VStack(spacing: 19) {
            Image(systemName: "lock.fill")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(Color(red: 0.53, green: 0.61, blue: 0.77))
                .frame(width: 112, height: 112)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Circle())

            Text("Your sign-in and signing data\nstay on this iPhone.")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Your password is sent directly to Apple for authentication and is never stored by AquaSign. The signing session and development certificate are managed locally; Anisette verification uses a remote provider.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .blue.opacity(0.06), radius: 18, y: 7)
    }

    private var appleIDField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Apple ID")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.primary)
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
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 1)
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Password")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.primary)
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
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 1)
        }
    }

    private var isReadyForDeviceRegistration: Bool {
        guard connection.isConnected,
              let deviceUDID = connection.deviceDetails?.udid else { return false }
        return !deviceUDID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var continueButton: some View {
        Button {
            guard let details = connection.deviceDetails,
                  let deviceUDID = details.udid,
                  !deviceUDID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                model.reportError("Connect this iPhone through LocalDevVPN before signing in.")
                return
            }
            model.signIn(deviceName: details.name, deviceUDID: deviceUDID)
        } label: {
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
        .disabled(model.isWorking || !isReadyForDeviceRegistration)
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
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 25, style: .continuous))
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
        .overlay { Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1) }
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
            .background { if selected { Capsule().fill(Color(uiColor: .tertiarySystemGroupedBackground)) } }
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



private struct CertificateRecoveryView: View {
    let prompt: AppleCertificateRecoveryPrompt
    let isWorking: Bool
    let onRevoke: (String) -> Void
    let onCancel: () -> Void
    @State private var selectedSerial: String?
    @State private var showingConfirmation = false

    private var selectedCertificate: AppleDevelopmentCertificateOption? {
        prompt.info.certificates.first { $0.serialNumber == selectedSerial }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Certificate recovery", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)

                    Text(prompt.info.message)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Error 7460 can mean an active certificate or a pending request; revoking an active certificate may not clear a pending request. Revocation invalidates profiles that include the certificate, and affected apps may need to be re-signed and reinstalled. It cannot be undone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if prompt.info.certificates.isEmpty {
                        Label("No active iOS Development certificates are available to revoke.", systemImage: "info.circle")
                            .font(.subheadline.weight(.medium))
                        Text("Error 7460 can also mean a certificate request is pending. AquaSign cannot revoke a pending request. Check your Apple Developer account or contact Apple Developer Support; no certificate has been changed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Choose an active development certificate")
                            .font(.subheadline.weight(.semibold))

                        ForEach(prompt.info.certificates) { certificate in
                            certificateRow(certificate)
                        }

                        Button {
                            showingConfirmation = true
                        } label: {
                            HStack(spacing: 9) {
                                if isWorking { ProgressView().tint(.white) }
                                Text(isWorking ? "Revoking and retrying…" : "Review revocation")
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.red, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isWorking || selectedSerial == nil)
                    }
                }
                .padding(24)
            }
            .navigationTitle("Resolve certificate issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isWorking)
                }
            }
            .confirmationDialog(
                "Revoke the selected certificate?",
                isPresented: $showingConfirmation,
                titleVisibility: .visible
            ) {
                Button("Revoke and retry once", role: .destructive) {
                    guard let selectedSerial else { return }
                    onRevoke(selectedSerial)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let selectedCertificate {
                    Text("Revoke \(selectedCertificate.name)? Profiles containing it will become invalid. If a pending request caused error 7460, this may not resolve it. AquaSign will retry once and will not revoke another certificate automatically.")
                }
            }
        }
        .interactiveDismissDisabled()
        .presentationDetents([.medium, .large])
    }

    private func certificateRow(_ certificate: AppleDevelopmentCertificateOption) -> some View {
        let isSelected = selectedSerial == certificate.serialNumber
        return Button {
            selectedSerial = certificate.serialNumber
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(certificate.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(certificate.certificateType) · \(certificate.status)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !certificate.expiration.isEmpty {
                        Text("Expires \(certificate.expiration)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("Serial · \(certificate.serialNumber)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(isSelected ? Color.blue : Color(uiColor: .separator).opacity(0.35), lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }
}




