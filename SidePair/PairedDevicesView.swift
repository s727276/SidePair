import SwiftUI

struct PairedDevicesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var pairing: PairingHostModel
    @ObservedObject var connection: RSDConnectionModel
    let onPairAnother: () -> Void
    let onConnectSelected: () -> Void
    let onConfigureDevice: () -> Void

    private var controlsDisabled: Bool {
        connection.isInstalling || pairing.isBusy
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                backButton
                header

                if pairing.devices.isEmpty {
                    emptyState
                } else {
                    deviceList
                }

                Button(action: onPairAnother) {
                    Text("Pair another device")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 62)
                        .background(Color(red: 0.10, green: 0.48, blue: 0.94), in: Capsule())
                        .shadow(color: .blue.opacity(0.16), radius: 12, y: 5)
                }
                .buttonStyle(.plain)
                .disabled(controlsDisabled)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .background(pairedDevicesBackground)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .semibold))
                Text("Device Manager")
                    .font(.system(size: 17, weight: .medium))
            }
            .foregroundStyle(Color(red: 0.17, green: 0.48, blue: 0.79))
            .padding(.horizontal, 17)
            .frame(height: 44)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().stroke(.white.opacity(0.78), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to Device Manager")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Paired Devices")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .tracking(-0.6)
                .foregroundStyle(Color(red: 0.05, green: 0.09, blue: 0.19))
            Text("Only devices paired with AquaSign can be managed.")
                .font(.system(size: 16))
                .foregroundStyle(Color(red: 0.47, green: 0.54, blue: 0.67))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 7)
    }

    private var deviceList: some View {
        VStack(spacing: 0) {
            ForEach(pairing.devices) { device in
                deviceRow(device)
                if device.id != pairing.devices.last?.id {
                    Rectangle()
                        .fill(Color(red: 0.83, green: 0.87, blue: 0.93).opacity(0.55))
                        .frame(height: 1)
                        .padding(.leading, 72)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.82), lineWidth: 1)
        }
        .shadow(color: .blue.opacity(0.06), radius: 17, y: 6)
    }

    private func deviceRow(_ device: PairedDevice) -> some View {
        let isSelected = pairing.selectedDeviceID == device.id
        let isConnected = isSelected && connection.isConnected
        let isConnecting = isSelected && connection.isConnecting

        return HStack(spacing: 16) {
            Image(systemName: "iphone")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Color(red: 0.48, green: 0.55, blue: 0.68))
                .frame(width: 58, height: 58)
                .background(Color(red: 0.91, green: 0.94, blue: 0.98), in: RoundedRectangle(cornerRadius: 17, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(device.name)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.07, green: 0.11, blue: 0.21))
                    .lineLimit(1)
                Text(deviceSubtitle(device, isConnected: isConnected, isConnecting: isConnecting))
                    .font(.system(size: 14))
                    .foregroundStyle(Color(red: 0.47, green: 0.54, blue: 0.67))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            Button {
                if isConnected {
                    dismiss()
                } else if isSelected {
                    if connection.hasValidDeviceIP {
                        onConnectSelected()
                    } else {
                        onConfigureDevice()
                    }
                } else {
                    pairing.selectDevice(device.id)
                }
            } label: {
                Text(deviceActionTitle(
                    isSelected: isSelected,
                    isConnected: isConnected,
                    isConnecting: isConnecting,
                    hasValidDeviceIP: connection.hasValidDeviceIP
                ))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(red: 0.15, green: 0.48, blue: 0.79))
                    .frame(minWidth: 72)
                    .frame(height: 44)
                    .padding(.horizontal, 8)
                    .background(Color.white.opacity(0.55), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(controlsDisabled || isConnecting)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
    }

    private func deviceSubtitle(_ device: PairedDevice, isConnected: Bool, isConnecting: Bool) -> String {
        if isConnected {
            return "\(device.model) · Connected\nthrough LocalDevVPN"
        }
        if isConnecting {
            return "\(device.model) · Connecting…\nthrough LocalDevVPN"
        }
        return "Pairing saved · Not connected"
    }

    private func deviceActionTitle(
        isSelected: Bool,
        isConnected: Bool,
        isConnecting: Bool,
        hasValidDeviceIP: Bool
    ) -> String {
        if isConnected { return "Manage" }
        if isConnecting { return "Connecting…" }
        if isSelected { return hasValidDeviceIP ? "Connect" : "Set IP" }
        return "Select"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "iphone")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Color(red: 0.48, green: 0.55, blue: 0.68))
                .frame(width: 64, height: 64)
                .background(Color(red: 0.91, green: 0.94, blue: 0.98), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("No paired devices yet")
                .font(.headline)
                .foregroundStyle(Color(red: 0.07, green: 0.11, blue: 0.21))
            Text("Pair another device, then approve the request in Developer Mode settings on that iPhone.")
                .font(.subheadline)
                .foregroundStyle(Color(red: 0.47, green: 0.54, blue: 0.67))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.82), lineWidth: 1)
        }
    }

    private var pairedDevicesBackground: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.91, green: 0.95, blue: 1.00),
                        Color(red: 0.97, green: 0.985, blue: 1.00),
                        Color(red: 0.91, green: 0.95, blue: 1.00)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(.white.opacity(0.3))
                    .frame(width: geometry.size.width * 1.05)
                    .offset(x: -geometry.size.width * 0.45, y: -geometry.size.height * 0.40)
                Ellipse()
                    .fill(Color.blue.opacity(0.035))
                    .frame(width: geometry.size.width * 1.2, height: geometry.size.height * 0.46)
                    .rotationEffect(.degrees(-18))
                    .offset(x: geometry.size.width * 0.34, y: geometry.size.height * 0.40)
            }
        }
        .ignoresSafeArea()
    }
}
