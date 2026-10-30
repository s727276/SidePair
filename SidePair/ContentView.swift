//
//  ContentView.swift
//  AquaSign
//

import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var pairing = PairingHostModel()
    @StateObject private var connection = RSDConnectionModel()
    @StateObject private var signing = AppleSigningModel()
    @StateObject private var library = AppLibraryModel()
    @State private var navigationPath: [AquaSignRoute] = []
    @State private var selectedTab: AquaSignTab = .pair
    @State private var isProcessingWidgetRefresh = false
    @AppStorage("sidepairShowSettingsInTabBar") private var showSettingsInTabBar = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            TabView(selection: $selectedTab) {
                pairingScreen
                    .tabItem { Label("Pair", systemImage: "rectangle.on.rectangle") }
                    .tag(AquaSignTab.pair)

                AppLibraryView(
                    connection: connection,
                    signing: signing,
                    library: library,
                    onOpenSettings: openSettings
                )
                .tabItem { Label("Signing", systemImage: "square.stack.3d.up.fill") }
                .tag(AquaSignTab.signing)

                DeviceManagerView(
                    connection: connection,
                    pairing: pairing,
                    onOpenSettings: openSettings,
                    onOpenPairedDevices: { navigate(to: .pairedDevices) }
                )
                .tabItem { Label("Device", systemImage: "iphone") }
                .tag(AquaSignTab.device)

                if showSettingsInTabBar {
                    SettingsView(
                        signing: signing,
                        onNavigate: navigate,
                        onOpenSettings: openSettings
                    )
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(AquaSignTab.settings)
                }
            }
            .navigationDestination(for: AquaSignRoute.self) { route in
                switch route {
                case .appLibrary:
                    AppLibraryView(
                        connection: connection,
                        signing: signing,
                        library: library,
                        onOpenSettings: openSettings
                    )
                case .appleSigning:
                    AppleSigningView(model: signing, connection: connection)
                case .developerAppIDs:
                    DeveloperAppIDsView(signing: signing) {
                        navigate(to: .appleSigning)
                    }
                case .settings:
                    SettingsView(
                        signing: signing,
                        onNavigate: navigate,
                        onOpenSettings: openSettings
                    )
                case .pairedDevices:
                    PairedDevicesView(
                        pairing: pairing,
                        connection: connection,
                        onPairAnother: startPairingAnotherDevice,
                        onConnectSelected: activateSelectedDevice,
                        onConfigureDevice: openPairingTab
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: openSettings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .toolbar(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                mainTabBar
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .background(.clear)
            }
        }
        .tint(.blue)
        .task {
            library.reconcilePendingSelfRefresh()
            signing.restoreSessionIfAvailable()
            if let selectedDevice = pairing.selectedDevice {
                connection.deviceIP = selectedDevice.deviceIP
            }
            await processWidgetRefreshRequest()
            if selectedTab == .pair { attemptAutomaticConnection() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await processWidgetRefreshRequest()
                if selectedTab == .pair { attemptAutomaticConnection() }
            }
        }
        .onChange(of: showSettingsInTabBar) { _, isEnabled in
            if !isEnabled, selectedTab == .settings {
                selectedTab = .pair
            }
        }
        .onChange(of: selectedTab) { _, tab in
            navigationPath.removeAll()
            if tab == .pair { attemptAutomaticConnection() }
        }
        .onChange(of: pairing.selectedDeviceID) { _, deviceID in
            guard deviceID != nil else { return }
            activateSelectedDevice()
        }
        .onChange(of: connection.deviceIP) { _, deviceIP in
            if let deviceID = pairing.selectedDeviceID {
                pairing.updateDeviceIP(deviceIP, for: deviceID)
            }
            attemptAutomaticConnection()
        }
    }

    private var pairingScreen: some View {
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
    }

    private var mainTabBar: some View {
        HStack(spacing: 7) {
            mainTabItem("Pair", symbol: "rectangle.on.rectangle", selected: selectedTab == .pair) {
                selectedTab = .pair
            }
            mainTabItem("Signing", symbol: "square.stack.3d.up.fill", selected: selectedTab == .signing) {
                selectedTab = .signing
            }
            mainTabItem("Device", symbol: "iphone", selected: selectedTab == .device) {
                selectedTab = .device
            }
            if showSettingsInTabBar {
                mainTabItem("Settings", symbol: "gearshape", selected: selectedTab == .settings) {
                    selectedTab = .settings
                }
            }
        }
        .padding(8)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.82), lineWidth: 1) }
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
    }

    private func mainTabItem(
        _ title: String,
        symbol: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? Color(red: 0.10, green: 0.46, blue: 0.91) : Color(red: 0.46, green: 0.52, blue: 0.64))
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background {
                if selected { Capsule().fill(.white.opacity(0.62)) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func navigate(to route: AquaSignRoute) {
        switch route {
        case .appLibrary:
            navigationPath.removeAll()
            selectedTab = .signing
        case .appleSigning:
            navigationPath = [.appleSigning]
        case .developerAppIDs:
            if navigationPath.last != .developerAppIDs {
                navigationPath.append(.developerAppIDs)
            }
        case .settings:
            openSettings()
        case .pairedDevices:
            if navigationPath.last != .pairedDevices {
                navigationPath.append(.pairedDevices)
            }
        }
    }

    private func openPairingTab() {
        navigationPath.removeAll()
        selectedTab = .pair
    }

    private func startPairingAnotherDevice() {
        guard !connection.isInstalling, !pairing.isBusy else { return }
        navigationPath.removeAll()
        selectedTab = .pair
        pairing.startPairing()
    }

    private func openSettings() {
        if showSettingsInTabBar {
            navigationPath.removeAll()
            selectedTab = .settings
        } else if navigationPath.last != .settings {
            navigationPath = [.settings]
        }
    }

    private func activateSelectedDevice() {
        guard !connection.isInstalling,
              !pairing.isBusy,
              let device = pairing.selectedDevice else { return }
        connection.disconnect()
        connection.deviceIP = device.deviceIP
        guard connection.hasValidDeviceIP, connection.isSupportedSystem else { return }
        connection.connect(using: device.pairingFileURL)
    }

    private func attemptAutomaticConnection() {
        guard selectedTab == .pair,
              navigationPath.isEmpty,
              pairing.pairingFileURL != nil,
              connection.hasValidDeviceIP,
              connection.isSupportedSystem,
              !connection.isConnecting,
              !connection.isConnected else { return }
        connection.connect(using: pairing.pairingFileURL)
    }

    @MainActor
    private func processWidgetRefreshRequest() async {
        let appGroupID = "group.com.Andrewdev.aquasign.shared"
        let requestKey = "aquaSignPendingWidgetRefresh"
        guard !isProcessingWidgetRefresh,
              let defaults = UserDefaults(suiteName: appGroupID),
              defaults.bool(forKey: requestKey) else { return }

        defaults.set(false, forKey: requestKey)
        isProcessingWidgetRefresh = true
        navigationPath.removeAll()
        selectedTab = .signing
        defer { isProcessingWidgetRefresh = false }

        signing.restoreSessionIfAvailable()
        for _ in 0..<240 {
            if !signing.isWorking { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard signing.status != nil else {
            library.reportError(signing.errorMessage ?? "Sign in to your Apple developer account before refreshing apps.")
            return
        }

        if !connection.isConnected && !connection.isConnecting {
            connection.connect(using: pairing.pairingFileURL)
        }
        for _ in 0..<120 {
            if connection.isConnected || !connection.isConnecting { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard connection.isConnected else {
            library.reportError(connection.failureMessage ?? "Connect LocalDevVPN and confirm its Device IP before refreshing apps.")
            return
        }

        await library.refreshAll(signing: signing, connection: connection)
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
            HStack {
                Text("Device connection")
                    .font(.headline)
                Spacer()
                connectionStatus
            }

            Text("AquaSign tests the saved Device IP automatically when Pair opens or the app returns to the foreground. A successful RSD connection is the only confirmation that the tunnel is reachable.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

            if pairing.pairingFileURL == nil {
                Label("Pair this iPhone first. AquaSign will try connecting after the pairing record is saved.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !connection.hasValidDeviceIP {
                Label("Enter a valid IPv4 Device IP from LocalDevVPN settings to enable automatic connection.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !connection.isSupportedSystem {
                Label("Automatic Remote Pairing connections require iOS 27 or later.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if connection.isConnecting {
                HStack(spacing: 9) {
                    ProgressView()
                    Text("Testing the RSD connection…")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.blue)
            } else if connection.isConnected, let details = connection.deviceDetails {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Label("Connected through LocalDevVPN", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Disconnect") { connection.disconnect() }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                            .disabled(connection.isInstalling)
                    }
                    deviceDetailRow("Device", value: details.name)
                    deviceDetailRow("Model", value: details.model)
                    deviceDetailRow("iOS", value: details.version)
                }
                .padding(14)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if let message = connection.failureMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if pairing.pairingFileURL != nil,
                      connection.hasValidDeviceIP,
                      connection.isSupportedSystem {
                Label("Not connected yet. AquaSign will test the connection when Pair becomes active or the app returns to the foreground.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder
    private var connectionStatus: some View {
        if connection.isConnecting {
            statusPill("CONNECTING", color: .orange)
        } else if connection.isConnected {
            statusPill("CONNECTED", color: .green)
        } else if !connection.isSupportedSystem {
            statusPill("UNAVAILABLE", color: .secondary)
        } else if connection.failureMessage != nil {
            statusPill("NEEDS ATTENTION", color: .orange)
        } else {
            statusPill("NOT CONNECTED", color: .secondary)
        }
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

enum AquaSignTab: Hashable {
    case pair
    case signing
    case device
    case settings
}

#Preview {
    ContentView()
}
