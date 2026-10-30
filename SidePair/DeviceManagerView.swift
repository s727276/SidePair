import SwiftUI

struct DeviceManagerView: View {
    @ObservedObject var connection: RSDConnectionModel
    @ObservedObject var pairing: PairingHostModel
    let onOpenSettings: () -> Void
    let onOpenPairedDevices: () -> Void
    @State private var showingUnavailableSection = false
    @State private var unavailableTitle = ""
    @State private var unavailableMessage = ""

    private var canManageDevice: Bool {
        connection.isConnected && !connection.isInstalling
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                header
                deviceCard
                pairedDevicesCard
                managementCard(
                    title: "Backups",
                    detail: "Create and manage backups of your device data.",
                    symbol: "icloud.and.arrow.up",
                    actionTitle: "Manage"
                )
                managementCard(
                    title: "Configuration Profiles",
                    detail: "Install, remove or view configuration profiles.",
                    symbol: "doc.text.badge.gearshape",
                    actionTitle: "Manage"
                )
                managementCard(
                    title: "Provisioning Profiles",
                    detail: "Browse and install provisioning profiles.",
                    symbol: "doc.text.badge.checkmark",
                    actionTitle: "Browse"
                )
                Text("Actions are available only while the RSD connection is confirmed.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(red: 0.47, green: 0.53, blue: 0.66))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .background(deviceManagerBackground)
        .toolbar(.hidden, for: .navigationBar)
        .alert(unavailableTitle, isPresented: $showingUnavailableSection) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(unavailableMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Device Manager")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .tracking(-0.5)
                    .foregroundStyle(Color(red: 0.06, green: 0.11, blue: 0.22))
                Text("Manage your paired device")
                    .font(.system(size: 17))
                    .foregroundStyle(Color(red: 0.47, green: 0.53, blue: 0.66))
            }
            Spacer(minLength: 8)
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color(red: 0.48, green: 0.55, blue: 0.68))
                    .frame(width: 46, height: 46)
                    .background(.regularMaterial, in: Circle())
                    .overlay { Circle().stroke(.white.opacity(0.7), lineWidth: 1) }
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 8)
    }

    private var pairedDevicesCard: some View {
        Button(action: onOpenPairedDevices) {
            HStack(spacing: 13) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color(red: 0.13, green: 0.48, blue: 0.84))
                    .frame(width: 50, height: 50)
                    .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Paired Devices")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.08, green: 0.13, blue: 0.25))
                    Text(pairing.selectedDevice?.name ?? "Add an authorized iPhone")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(red: 0.47, green: 0.53, blue: 0.66))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("\(pairing.devices.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.13, green: 0.48, blue: 0.84))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.1), in: Capsule())
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.78), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var deviceCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "iphone")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Color(red: 0.48, green: 0.55, blue: 0.68))
                .frame(width: 82, height: 82)
                .background(Color(red: 0.94, green: 0.96, blue: 0.99), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                connectionSummary
                if connection.isConnected {
                    if let details = connection.deviceDetails {
                        Text(details.name)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 0.08, green: 0.13, blue: 0.25))
                            .lineLimit(1)
                        Text("\(details.model) · iOS \(details.version)")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(red: 0.47, green: 0.53, blue: 0.66))
                    } else {
                        Text("Device details unavailable")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(disconnectedDescription)
                        .font(.system(size: 14))
                        .foregroundStyle(Color(red: 0.47, green: 0.53, blue: 0.66))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.78), lineWidth: 1)
        }
        .shadow(color: .blue.opacity(0.07), radius: 17, y: 6)
    }

    private var connectionSummary: some View {
        Group {
            if connection.isConnecting {
                Label("Connecting…", systemImage: "circle.dotted")
                    .foregroundStyle(.orange)
            } else if connection.isConnected {
                Label("Connected through LocalDevVPN", systemImage: "circle.fill")
                    .foregroundStyle(.green)
            } else if !connection.isSupportedSystem {
                Label("Unavailable", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else if connection.failureMessage != nil {
                Label("Connection needs attention", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label("Not connected", systemImage: "circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13, weight: .medium))
    }

    private var disconnectedDescription: String {
        if connection.isConnecting { return "Testing the saved RSD connection…" }
        if let failureMessage = connection.failureMessage { return failureMessage }
        if !connection.isSupportedSystem { return "Remote Pairing device management requires iOS 27 or later." }
        if pairing.pairingFileURL == nil { return "Pair an iPhone from the Pair tab to manage it here." }
        return "Open Paired Devices to confirm this iPhone’s Device IP and retry the connection."
    }

    private func managementCard(
        title: String,
        detail: String,
        symbol: String,
        actionTitle: String
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color(red: 0.54, green: 0.62, blue: 0.77))
                .frame(width: 56, height: 56)
                .background(Color(red: 0.92, green: 0.95, blue: 0.99), in: RoundedRectangle(cornerRadius: 17, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.08, green: 0.13, blue: 0.25))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(red: 0.47, green: 0.53, blue: 0.66))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Button(actionTitle) {
                guard canManageDevice else { return }
                unavailableTitle = title
                unavailableMessage = "This management section will be available in a follow-up update. The connected device is confirmed, but no profile or backup operation was started."
                showingUnavailableSection = true
            }
            .font(.system(size: 14, weight: .semibold))
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.88, green: 0.93, blue: 0.99))
            .foregroundStyle(canManageDevice ? Color(red: 0.13, green: 0.48, blue: 0.84) : Color.secondary)
            .disabled(!canManageDevice)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .stroke(.white.opacity(0.78), lineWidth: 1)
        }
        .shadow(color: .blue.opacity(0.045), radius: 12, y: 5)
    }

    private var deviceManagerBackground: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.90, green: 0.94, blue: 0.99),
                        Color(red: 0.98, green: 0.99, blue: 1.00),
                        Color(red: 0.90, green: 0.95, blue: 1.00)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(.white.opacity(0.28))
                    .frame(width: geometry.size.width * 0.90)
                    .offset(x: -geometry.size.width * 0.44, y: -geometry.size.height * 0.40)
                Ellipse()
                    .fill(Color.blue.opacity(0.035))
                    .frame(width: geometry.size.width * 1.2, height: geometry.size.height * 0.48)
                    .rotationEffect(.degrees(-18))
                    .offset(x: geometry.size.width * 0.34, y: geometry.size.height * 0.40)
            }
        }
        .ignoresSafeArea()
    }
}
