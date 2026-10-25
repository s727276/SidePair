import SwiftUI
import UniformTypeIdentifiers

struct AppLibraryView: View {
    @ObservedObject var connection: RSDConnectionModel
    @ObservedObject var signing: AppleSigningModel
    let pairingFileURL: URL?
    @ObservedObject var library: AppLibraryModel
    let onNavigate: (AquaSignRoute) -> Void
    let onPair: () -> Void
    @AppStorage("sidepairShowIPACustomizationBeforeSigning") private var showCustomizationBeforeSigning = false
    @State private var showingImporter = false
    @State private var customizationApp: IPAAppMetadata?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                signingNote
                refreshAllCard

                if library.apps.isEmpty {
                    emptyLibraryCard
                } else {
                    appList
                }

                if library.isBusy || library.isRefreshingAll {
                    progressCard
                }

                if let summary = library.refreshSummaryMessage {
                    Label(summary, systemImage: library.errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(library.errorMessage == nil ? Color.green : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = library.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }

                connectionCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 32)
            .padding(.bottom, 24)
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
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [ipaContentType],
            allowsMultipleSelection: false,
            onCompletion: handleImport
        )
        .fullScreenCover(item: $customizationApp) { app in
            IPACustomizationView(
                app: app,
                library: library,
                signing: signing,
                connection: connection
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("App Library")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .tracking(-0.5)
                .foregroundStyle(Color.primary)
            Text("Apps ready for this iPhone")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }

    private var signingNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    signing.status == nil ? "Apple account needed" : "Apple account ready",
                    systemImage: signing.status == nil ? "person.crop.circle.badge.exclamationmark" : "checkmark.circle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(signing.status == nil ? .orange : .green)
                Spacer()
                Button(signing.status == nil ? "Sign in" : "Manage") {
                    onNavigate(.appleSigning)
                }
                .font(.subheadline.weight(.semibold))
            }
            Text("AquaSign signs imported IPAs with your Apple ID and refreshes them with a newly issued provisioning profile before reinstalling. Personal provisioning uses a team-scoped bundle ID. Free personal profiles commonly last seven days; Apple sets the exact expiration. Some apps or capabilities may not be eligible for your team.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var refreshAllCard: some View {
        let installedApps = library.refreshableApps
        return VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("Refresh all apps", systemImage: "arrow.clockwise")
                    .font(.headline)
                Spacer()
                Text("\(installedApps.count) to refresh")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text("Requires an active LocalDevVPN connection and your saved Apple signing session.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if library.apps.contains(where: { $0.installedAt != nil && library.isAquaSignApp($0) }) {
                Label("AquaSign refreshes last and may close while iOS replaces it.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let nextExpiringApp = nextExpiringApp {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(nextExpiringApp.displayName) profile expires in")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(expirationCountdown(nextExpiringApp.profileExpiration!, at: context.date))
                            .font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                        Text("Exact expiry · \(expirationTimestamp(nextExpiringApp.profileExpiration!))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(installedApps.isEmpty
                     ? "Install an app to enable Refresh All. AquaSign refreshes last when it is in your library."
                     : "Profile expiry will appear after AquaSign reads a signed app profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await library.refreshAll(signing: signing, connection: connection) }
            } label: {
                Label(library.isRefreshingAll ? "Refreshing apps…" : "Refresh all", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(library.isBusy || library.isRefreshingAll || installedApps.isEmpty)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var nextExpiringApp: IPAAppMetadata? {
        let appsWithExpiration = library.refreshableApps.filter { $0.profileExpiration != nil }
        let now = Date()
        return appsWithExpiration
            .filter { ($0.profileExpiration ?? .distantPast) > now }
            .min { ($0.profileExpiration ?? .distantFuture) < ($1.profileExpiration ?? .distantFuture) }
            ?? appsWithExpiration.max { ($0.profileExpiration ?? .distantPast) < ($1.profileExpiration ?? .distantPast) }
    }

    private func expirationCountdown(_ expiration: Date, at now: Date) -> String {
        let timeRemaining = expiration.timeIntervalSince(now)
        guard timeRemaining > 0 else { return "Expired" }
        let secondsRemaining = Int(timeRemaining.rounded(.up))
        let days = secondsRemaining / 86_400
        let hours = (secondsRemaining % 86_400) / 3_600
        let minutes = (secondsRemaining % 3_600) / 60
        let seconds = secondsRemaining % 60
        return "\(days)d \(hours)h \(minutes)m \(seconds)s"
    }

    private func expirationTimestamp(_ expiration: Date) -> String {
        expiration.formatted(.dateTime.month(.abbreviated).day().year().hour().minute().second())
    }

    private var emptyLibraryCard: some View {
        VStack(spacing: 18) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 43, weight: .medium))
                .foregroundStyle(Color(red: 0.53, green: 0.61, blue: 0.77))
                .frame(width: 112, height: 112)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Circle())

            VStack(spacing: 7) {
                Text("Your library is ready")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                Text("Choose any IPA. AquaSign signs it with your Apple ID and installs it over your paired connection.")
                    .font(.system(size: 17))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                showingImporter = true
            } label: {
                Text("Choose IPA")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(Color.blue, in: Capsule())
                    .shadow(color: .blue.opacity(0.18), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(library.isBusy || library.isRefreshingAll)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.vertical, 30)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .blue.opacity(0.06), radius: 18, y: 7)
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Your apps")
                .font(.headline)
                .padding(.horizontal, 4)
            ForEach(library.apps) { app in
                appCard(app)
            }
            Button {
                showingImporter = true
            } label: {
                Label("Choose another IPA", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(library.isBusy || library.isRefreshingAll)
        }
    }

    private func appCard(_ app: IPAAppMetadata) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "app.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 46, height: 46)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.displayName)
                        .font(.headline)
                    Text("Original ID · \(app.bundleIdentifier)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("Version \(app.version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(app.installState.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(app.installState.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(app.installState.color.opacity(0.1), in: Capsule())
            }

            if let expiration = app.profileExpiration {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Profile expires in \(expirationCountdown(expiration, at: context.date))")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(expiration > context.date ? Color.secondary : Color.orange)
                        Text("Exact expiry · \(expirationTimestamp(expiration))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if app.installedAt != nil {
                Label("Could not read this app's profile expiry", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let lastError = app.lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    customizationApp = app
                } label: {
                    Label("Customize", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .disabled(library.isBusy || library.isRefreshingAll)

                Button {
                    if showCustomizationBeforeSigning {
                        customizationApp = app
                    } else {
                        Task { try? await library.install(app, signing: signing, connection: connection) }
                    }
                } label: {
                    Label(
                        showCustomizationBeforeSigning
                            ? "Review & Sign"
                            : (library.isBusy ? "Working…" : (app.installedAt != nil ? "Refresh & reinstall" : "Sign & install")),
                        systemImage: showCustomizationBeforeSigning
                            ? "slider.horizontal.3"
                            : (app.installedAt != nil ? "arrow.clockwise" : "arrow.down.to.line")
                    )
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(library.isBusy || library.isRefreshingAll)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProgressView()
                Text(library.stageMessage ?? "Preparing IPA…")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(library.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: library.progress)
                .tint(.blue)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var connectionCard: some View {
        HStack(spacing: 13) {
            Image(systemName: "iphone")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 48)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Device connection")
                    .font(.subheadline.weight(.semibold))
                Text(connectionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(connection.isConnected ? "Disconnect" : "Connect") {
                if connection.isConnected {
                    connection.disconnect()
                } else {
                    connection.connect(using: pairingFileURL)
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .disabled(connection.isConnecting || connection.isInstalling || (!connection.isConnected && pairingFileURL == nil))
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var connectionDescription: String {
        if connection.isInstalling { return "Installing app…" }
        if connection.isConnected { return "Connected through LocalDevVPN" }
        if connection.isConnecting { return "Connecting…" }
        if case .failed = connection.state { return "Connection needs attention" }
        return "Not connected"
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabItem("Pair", symbol: "rectangle.on.rectangle", selected: false, action: onPair)
            tabItem("App Library", symbol: "square.stack.3d.up.fill", selected: true) {}
            tabItem("Settings", symbol: "gearshape", selected: false) { onNavigate(.settings) }
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

    private var ipaContentType: UTType {
        UTType(filenameExtension: "ipa", conformingTo: .data) ?? .data
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            library.importIPA(
                from: url,
                signing: signing,
                connection: connection,
                customizeBeforeSigning: showCustomizationBeforeSigning,
                onImported: { app in
                    if showCustomizationBeforeSigning { customizationApp = app }
                }
            )
        case let .failure(error):
            if (error as? CocoaError)?.code != .userCancelled {
                library.reportImportError(error)
            }
        }
    }
}


private extension IPAInstallState {
    var label: String {
        switch self {
        case .ready: "Ready"
        case .installing: "Installing"
        case .installed: "Installed"
        case .failed: "Needs attention"
        }
    }

    var color: Color {
        switch self {
        case .ready: .blue
        case .installing: .orange
        case .installed: .green
        case .failed: .orange
        }
    }
}
