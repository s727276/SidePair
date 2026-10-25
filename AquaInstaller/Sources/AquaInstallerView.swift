import SwiftUI
import UniformTypeIdentifiers

struct AquaInstallerView: View {
    @ObservedObject var model: AquaInstallerModel
    @State private var showingIPAImporter = false
    @State private var confirmingForgetSession = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("USB device", systemImage: "iphone.gen3")
                            .font(.headline)
                        Spacer()
                        Button {
                            model.refreshDevices()
                        } label: {
                            Label(model.isScanning ? "Scanning…" : "Scan", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isScanning || model.isWorking)
                    }

                    if model.devices.isEmpty {
                        Label("No paired iPhone found over USB", systemImage: "cable.connector")
                            .foregroundStyle(.secondary)
                        Text("Connect the iPhone by cable, unlock it, trust this Mac, then scan again. Aqua Installer only installs to a wired iPhone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Picker("Connected iPhone", selection: $model.selectedDeviceUDID) {
                            ForEach(model.devices) { device in
                                Text("\(device.name) · iOS \(device.osVersion)")
                                    .tag(device.udid as String?)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)

                        if let device = model.selectedDevice {
                            Text("Apple device UDID · \(device.udid)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("AquaSign build", systemImage: "shippingbox")
                        .font(.headline)
                    HStack(spacing: 12) {
                        Button {
                            showingIPAImporter = true
                        } label: {
                            Label("Choose AquaSign IPA", systemImage: "folder")
                        }
                        .disabled(model.isWorking)

                        Text(model.selectedIPAURL?.lastPathComponent ?? "No IPA selected")
                            .font(.subheadline)
                            .foregroundStyle(model.selectedIPAURL == nil ? Color.secondary : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text("Choose the unsigned AquaSign IPA from the GitHub Actions artifact. Aqua Installer checks its bundle ID, signs it on this Mac, and installs the signed app over USB.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Apple developer account", systemImage: "person.badge.key")
                        .font(.headline)
                    if model.hasSavedSession {
                        Label(
                            model.savedAccountName.map { "Saved session · \($0)" } ?? "Saved signing session in this Mac's Keychain",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.green)
                        Button("Forget saved session…") {
                            confirmingForgetSession = true
                        }
                        .disabled(model.isWorking)
                    } else {
                        TextField("Apple ID", text: $model.appleID)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.isWorking)
                        SecureField("Apple ID password", text: $model.password)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.isWorking)
                    }
                    Text("Your password is used for Apple authentication and is not saved. The signing session is stored in this Mac's Keychain; Apple credentials are never sent to GitHub Actions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 10) {
                if model.isWorking {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(model.statusMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label(model.statusMessage, systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    model.installAquaSign()
                } label: {
                    Label("Sign & install AquaSign over USB", systemImage: "arrow.down.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isWorking || model.selectedDevice == nil || model.selectedIPAURL == nil)

                Text("The iPhone must be unlocked, paired with this Mac, and have Developer Mode enabled. Apple must allow the selected device and app capabilities in the provisioning profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(minWidth: 620, minHeight: 690)
        .background(.background)
        .fileImporter(
            isPresented: $showingIPAImporter,
            allowedContentTypes: [ipaContentType],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first { model.chooseIPA(url) }
            case let .failure(error):
                if (error as? CocoaError)?.code != .userCancelled {
                    model.reportError(error.localizedDescription)
                }
            }
        }
        .sheet(item: $model.twoFactorPrompt) { prompt in
            TwoFactorChallengeView(
                prompt: prompt,
                onAnswer: { action, code, phoneID in
                    model.respondToTwoFactor(action: action, code: code, phoneID: phoneID)
                },
                onCancel: model.cancelTwoFactor
            )
        }
        .confirmationDialog(
            "Remove the saved Apple signing session from this Mac?",
            isPresented: $confirmingForgetSession,
            titleVisibility: .visible
        ) {
            Button("Forget signing session", role: .destructive) {
                model.forgetSavedSession()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes Aqua Installer's saved Apple developer session from the Keychain. It does not revoke certificates or change apps on your iPhone.")
        }
        .task {
            model.refreshDevices()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "cable.connector")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text("Aqua Installer")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Sign AquaSign locally. Install it by USB.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var ipaContentType: UTType {
        UTType(filenameExtension: "ipa", conformingTo: .data) ?? .data
    }
}
