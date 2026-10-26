import SwiftUI
import UniformTypeIdentifiers

struct AppLibraryView: View {
    @ObservedObject var connection: RSDConnectionModel
    @ObservedObject var signing: AppleSigningModel
    @ObservedObject var library: AppLibraryModel
    let onOpenSettings: () -> Void
    @AppStorage("sidepairShowIPACustomizationBeforeSigning") private var showCustomizationBeforeSigning = false
    @State private var showingImporter = false
    @State private var customizationApp: IPAAppMetadata?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                refreshOverview

                if library.apps.isEmpty {
                    emptyState
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

                addIPAButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .background(signingBackground)
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
        HStack(alignment: .center) {
            Text("Signing")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .tracking(-0.5)
                .foregroundStyle(Color(red: 0.06, green: 0.11, blue: 0.22))
            Spacer()
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

    private var refreshOverview: some View {
        let readyApps = library.refreshableApps(forTeamID: signing.status?.teamId)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 15) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color(red: 0.48, green: 0.58, blue: 0.77))
                    .frame(width: 66, height: 66)
                    .background(Color(red: 0.91, green: 0.94, blue: 0.99), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(readyApps.count == 1 ? "1 app ready" : "\(readyApps.count) apps ready")
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.08, green: 0.13, blue: 0.25))
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(nextExpiryDescription(for: readyApps, at: context.date))
                            .font(.system(size: 16))
                            .foregroundStyle(Color(red: 0.47, green: 0.53, blue: 0.66))
                    }
                }
                Spacer(minLength: 0)
            }

            if library.isPreparingAquaSignEntry {
                Label("Preparing AquaSign for refresh…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = library.aquaSignPreparationError {
                Label("AquaSign refresh source unavailable: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await library.refreshAll(signing: signing, connection: connection) }
            } label: {
                Text(library.isRefreshingAll ? "Refreshing…" : "Refresh All")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color(red: 0.13, green: 0.49, blue: 0.96), in: Capsule())
                    .foregroundStyle(.white)
                    .shadow(color: .blue.opacity(0.18), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(library.isBusy || library.isRefreshingAll || readyApps.isEmpty)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.78), lineWidth: 1)
        }
        .shadow(color: .blue.opacity(0.08), radius: 18, y: 7)
    }

    private var nextExpiringApp: IPAAppMetadata? {
        let appsWithExpiration = library.refreshableApps(forTeamID: signing.status?.teamId)
            .filter { $0.profileExpiration != nil }
        let now = Date()
        return appsWithExpiration
            .filter { ($0.profileExpiration ?? .distantPast) > now }
            .min { ($0.profileExpiration ?? .distantFuture) < ($1.profileExpiration ?? .distantFuture) }
            ?? appsWithExpiration.max { ($0.profileExpiration ?? .distantPast) < ($1.profileExpiration ?? .distantPast) }
    }

    private func nextExpiryDescription(for apps: [IPAAppMetadata], at date: Date) -> String {
        guard let app = nextExpiringApp, apps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }),
              let expiration = app.profileExpiration else { return "Next expiry · —" }
        let label = expirationSummary(expiration, at: date)
        return label.replacingOccurrences(of: "Expires in ", with: "Next expiry · ")
    }

    private func expirationSummary(_ expiration: Date, at date: Date) -> String {
        let remaining = expiration.timeIntervalSince(date)
        guard remaining > 0 else { return "Expired" }
        let days = max(Int(ceil(remaining / 86_400)), 1)
        return "Expires in \(days) \(days == 1 ? "day" : "days")"
    }

    private var signingBackground: some View {
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
                    .fill(.white.opacity(0.30))
                    .frame(width: geometry.size.width * 0.90)
                    .offset(x: -geometry.size.width * 0.46, y: -geometry.size.height * 0.40)
                Ellipse()
                    .fill(Color.blue.opacity(0.035))
                    .frame(width: geometry.size.width * 1.2, height: geometry.size.height * 0.48)
                    .rotationEffect(.degrees(-18))
                    .offset(x: geometry.size.width * 0.34, y: geometry.size.height * 0.40)
            }
        }
        .ignoresSafeArea()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Color(red: 0.48, green: 0.58, blue: 0.77))
                .frame(width: 70, height: 70)
                .background(.white.opacity(0.55), in: Circle())
            Text("No apps yet")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.08, green: 0.13, blue: 0.25))
            Text("Add an IPA to sign and install on this iPhone.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var appList: some View {
        VStack(spacing: 12) {
            ForEach(library.apps) { app in
                appRow(app)
            }
        }
    }

    private func appRow(_ app: IPAAppMetadata) -> some View {
        let isRefreshable = library.isRefreshable(app, forTeamID: signing.status?.teamId)
        let isAquaSign = library.isAquaSignApp(app)
        let sourceURL = IPAArchiveInspector.archiveURL(
            for: app,
            preferSelfRefreshSource: isAquaSign && app.customizedArchiveFileName == nil
        )
        let hasSource = FileManager.default.fileExists(atPath: sourceURL.path)
        let actionTitle = showCustomizationBeforeSigning
            ? "Review"
            : (app.installedAt == nil ? "Sign" : (isRefreshable ? "Refresh" : "Reinstall"))

        return HStack(spacing: 12) {
            Image(systemName: appIconSymbol(for: app))
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(appIconColor(for: app), in: RoundedRectangle(cornerRadius: 17, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(app.displayName)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.08, green: 0.13, blue: 0.25))
                    .lineLimit(1)
                if let expiration = app.profileExpiration {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(expirationSummary(expiration, at: context.date))
                            .font(.system(size: 14))
                            .foregroundStyle(expiration > context.date ? Color(red: 0.46, green: 0.52, blue: 0.64) : Color.orange)
                    }
                } else {
                    Text(app.installedAt == nil ? "Ready to sign" : "Profile expiry unavailable")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(red: 0.46, green: 0.52, blue: 0.64))
                }
                if !isRefreshable {
                    Text(refreshReason(for: app, hasSource: hasSource))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                }
                if let lastError = app.lastError, !lastError.isEmpty {
                    Text(lastError)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                customizationApp = app
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(red: 0.28, green: 0.48, blue: 0.75))
                    .frame(width: 34, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Customize \(app.displayName)")
            .disabled(library.isBusy || library.isRefreshingAll)

            Button {
                if showCustomizationBeforeSigning {
                    customizationApp = app
                } else {
                    Task {
                        try? await library.install(
                            app,
                            signing: signing,
                            connection: connection,
                            preferSelfRefreshSource: isAquaSign && app.customizedArchiveFileName == nil
                        )
                    }
                }
            } label: {
                Text(library.isBusy ? "Working…" : actionTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(hasSource ? Color(red: 0.13, green: 0.48, blue: 0.84) : Color.secondary)
                    .frame(minWidth: 78)
                    .padding(.horizontal, 11)
                    .frame(height: 40)
                    .background(.white.opacity(0.48), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(library.isBusy || library.isRefreshingAll || !hasSource)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .stroke(.white.opacity(0.78), lineWidth: 1)
        }
        .shadow(color: .blue.opacity(0.045), radius: 12, y: 5)
    }

    private func appIconSymbol(for app: IPAAppMetadata) -> String {
        let name = app.displayName.lowercased()
        if name.contains("aqua") { return "drop.fill" }
        if name.contains("note") { return "leaf.fill" }
        if name.contains("map") { return "mountain.2.fill" }
        return "app.fill"
    }

    private func appIconColor(for app: IPAAppMetadata) -> Color {
        let name = app.displayName.lowercased()
        if name.contains("aqua") { return Color(red: 0.18, green: 0.60, blue: 0.95) }
        if name.contains("note") { return Color(red: 0.38, green: 0.77, blue: 0.33) }
        if name.contains("map") { return Color(red: 0.58, green: 0.34, blue: 0.86) }
        return Color(red: 0.30, green: 0.55, blue: 0.86)
    }

    private func refreshReason(for app: IPAAppMetadata, hasSource: Bool) -> String {
        guard hasSource else { return "The saved IPA is missing. Add it again from Files." }
        return library.refreshAvailabilityMessage(for: app, teamID: signing.status?.teamId)
    }

    private var addIPAButton: some View {
        Button {
            showingImporter = true
        } label: {
            Text("Add IPA")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color(red: 0.13, green: 0.49, blue: 0.96), in: Capsule())
                .shadow(color: .blue.opacity(0.18), radius: 9, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(library.isBusy || library.isRefreshingAll)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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

