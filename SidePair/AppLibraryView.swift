import SwiftUI
import UniformTypeIdentifiers

struct AppLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var connection: RSDConnectionModel
    @ObservedObject var signing: AppleSigningModel
    let pairingFileURL: URL?
    @StateObject private var library = AppLibraryModel()
    @State private var showingImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                signingNote

                if library.apps.isEmpty {
                    emptyLibraryCard
                } else {
                    appList
                }

                if library.isBusy {
                    progressCard
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
                NavigationLink {
                    AppleSigningView(model: signing)
                } label: {
                    Text(signing.status == nil ? "Sign in" : "Manage")
                        .font(.subheadline.weight(.semibold))
                }
            }
            Text("SidePair signs imported IPAs with your Apple ID and refreshes them with a newly issued provisioning profile before reinstalling. Personal provisioning uses a team-scoped bundle ID. Free personal profiles commonly last seven days; Apple sets the exact expiration. Some apps or capabilities may not be eligible for your team.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                Text("Choose any IPA. SidePair signs it with your Apple ID and installs it over your paired connection.")
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
            .disabled(library.isBusy)
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
            .disabled(library.isBusy)
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

            if let lastError = app.lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { try? await library.install(app, signing: signing, connection: connection) }
            } label: {
                Label(
                    library.isBusy ? "Working…" : (app.installState == .installed ? "Refresh & reinstall" : "Sign & install"),
                    systemImage: app.installState == .installed ? "arrow.clockwise" : "arrow.down.to.line"
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(library.isBusy)
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

    private var ipaContentType: UTType {
        UTType(filenameExtension: "ipa", conformingTo: .data) ?? .data
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            library.importIPA(from: url, signing: signing, connection: connection)
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
