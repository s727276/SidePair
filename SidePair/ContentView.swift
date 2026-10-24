//
//  ContentView.swift
//  AquaSign
//

import SwiftUI

struct ContentView: View {
    @StateObject private var pairing = PairingHostModel()
    @StateObject private var connection = RSDConnectionModel()
    @StateObject private var signing = AppleSigningModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    introCard
                    pairingCard
                    connectionCard
                    setupCard
                    if let pairingFileURL = pairing.pairingFileURL {
                        pairingFileCard(pairingFileURL)
                    }
                    privacyNote
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("AquaSign")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        AppLibraryView(connection: connection, signing: signing, pairingFileURL: pairing.pairingFileURL)
                    } label: {
                        Image(systemName: "square.stack.3d.up.fill")
                    }
                    .accessibilityLabel("App Library")

                    NavigationLink {
                        AppleSigningView(model: signing, connection: connection)
                    } label: {
                        Image(systemName: "person.badge.key.fill")
                    }
                    .accessibilityLabel("Apple signing")
                }
            }
        }
        .tint(.blue)
        .task { signing.restoreSessionIfAvailable() }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                Spacer()
                Label("iOS 27+", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(.blue.opacity(0.11), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Pair without a computer.")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .tracking(-0.5)
                Text("AquaSign hosts a secure Remote Pairing session on this iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Remote pairing")
                        .font(.headline)
                    Text(statusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                statusIndicator
            }

            if case let .pin(pin) = pairing.state {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ENTER THIS CODE IN SETTINGS")
                        .font(.caption2.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                    Text(pin)
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .tracking(7)
                        .foregroundStyle(.blue)
                        .accessibilityLabel("Pairing code \(pin)")
                    Text("We also sent this code in a notification.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            if case let .failed(message) = pairing.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: pairing.isBusy ? pairing.stopPairing : pairing.startPairing) {
                HStack(spacing: 9) {
                    if pairing.isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: pairing.state == .paired ? "arrow.clockwise" : "dot.radiowaves.left.and.right")
                    }
                    Text(pairing.isBusy ? "Stop pairing" : (pairing.state == .paired ? "Pair again" : "Start pairing"))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .foregroundStyle(.white)
                .background(pairing.isBusy ? Color.gray : Color.blue, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(pairing.isBusy && pairing.state == .connecting)

            if !pairing.isSupportedSystem {
                Text("This iOS version can show the setup guide, but on-device Remote Pairing requires iOS 27 or later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text("LocalDevVPN connection")
                    .font(.headline)
                Text("Connect the VPN first, then enter its Device IP. The default is 10.7.0.1—not the VPN’s Connected To address.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("DEVICE IP")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                TextField("10.7.0.1", text: $connection.deviceIP)
                    .font(.body.monospaced())
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(connection.isConnecting || connection.isConnected)
                    .padding(12)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if pairing.pairingFileURL == nil && !connection.isConnected {
                Label("Pair this iPhone first to create a Remote Pairing record.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if case let .failed(message) = connection.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if connection.isConnected, let details = connection.deviceDetails {
                VStack(spacing: 9) {
                    deviceDetailRow("Device", value: details.name)
                    deviceDetailRow("Model", value: details.model)
                    deviceDetailRow("iOS", value: details.version)
                }
                .padding(14)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Button {
                if connection.isConnected {
                    connection.disconnect()
                } else {
                    connection.connect(using: pairing.pairingFileURL)
                }
            } label: {
                HStack(spacing: 9) {
                    if connection.isConnecting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: connection.isConnected ? "link.badge.minus" : "network")
                    }
                    Text(connection.isConnecting ? "Connecting…" : (connection.isConnected ? "Disconnect" : "Connect device"))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(.white)
                .background(connection.isConnected ? Color.gray : Color.blue, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(connection.isConnecting || connection.isInstalling || (!connection.isConnected && pairing.pairingFileURL == nil))

            if !connection.isConnected && !connection.isConnecting && !connection.isSupportedSystem {
                Text("The on-device Remote Pairing tunnel requires iOS 27 or later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func deviceDetailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Before you begin")
                .font(.headline)
            setupStep(number: "1", title: "Turn on Developer Mode", detail: "Settings → Privacy & Security → Developer Mode. Follow the restart and passcode prompts.")
            setupStep(number: "2", title: "Stay on Wi-Fi", detail: "Your iPhone needs Wi-Fi and Local Network access while pairing.")
            setupStep(number: "3", title: "Pair from Settings", detail: "Start pairing here, then open Developer Mode settings, choose Pair with AquaSign, and enter the code shown here or in the notification.")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func setupStep(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.blue)
                .frame(width: 25, height: 25)
                .background(.blue.opacity(0.11), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pairingFileCard(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("Pairing record saved", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("\(pairing.deviceName ?? "This iPhone") · \(pairing.deviceModel ?? "iPhone")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ShareLink(item: url) {
                Label("Export pairing file", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var privacyNote: some View {
        Label("Pairing files contain sensitive device credentials. Share them only with apps and people you trust.", systemImage: "lock.shield")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch pairing.state {
        case .ready:
            statusPill("READY", color: .secondary)
        case .preparing:
            statusPill("PREPARING", color: .blue)
        case .waiting:
            statusPill("ADVERTISING", color: .blue)
        case .connecting:
            statusPill("CONNECTING", color: .orange)
        case .pin:
            statusPill("CONFIRM CODE", color: .orange)
        case .paired:
            statusPill("PAIRED", color: .green)
        case .failed:
            statusPill("NEEDS ATTENTION", color: .orange)
        }
    }

    private func statusPill(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(color.opacity(0.1), in: Capsule())
    }

    private var statusDescription: String {
        switch pairing.state {
        case .ready:
            "This iPhone will appear as a pairing host in Developer Mode."
        case .preparing:
            "Preparing an IDEvice pairing host and local listener…"
        case .waiting:
            "AquaSign is advertising over Bonjour. Open Developer Mode settings to connect."
        case .connecting:
            "A device connected. Waiting for the secure pairing handshake…"
        case .pin:
            "Approve the matching code in Developer Mode settings."
        case .paired:
            "The Remote Pairing record is stored on this iPhone."
        case .failed:
            "Pairing did not complete. Review the message and try again."
        }
    }
}

#Preview {
    ContentView()
}
