import Combine
import Foundation
import WidgetKit

@MainActor
final class AppLibraryModel: ObservableObject {
    @Published private(set) var apps: [IPAAppMetadata] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isRefreshingAll = false
    @Published private(set) var progress = 0.0
    @Published private(set) var stageMessage: String?
    @Published private(set) var refreshSummaryMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPreparingAquaSignEntry = false
    @Published private(set) var aquaSignPreparationError: String?

    private var aquaSignPreparationTask: Task<Void, Never>?

    private let storageKey = "sidepairImportedIPAApps"
    private let appGroupID = "group.com.Andrewdev.aquasign.shared"
    private let widgetSnapshotKey = "aquaSignWidgetApps"
    private let widgetKind = "com.Andrewdev.aquasign.sidepairwidgetextension.widget"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([IPAAppMetadata].self, from: data) {
            apps = saved
        }
        publishWidgetSnapshot()
        prepareAquaSignEntryIfNeeded()
    }

    var refreshableApps: [IPAAppMetadata] {
        apps.filter {
            $0.installedAt != nil && $0.managedTeamID != nil
                && (!isAquaSignApp($0) || aquaSignPreparationError == nil)
        }
    }

    func refreshableApps(forTeamID teamID: String?) -> [IPAAppMetadata] {
        guard let teamID = normalizedTeamID(teamID) else { return [] }
        return refreshableApps.filter { normalizedTeamID($0.managedTeamID) == teamID }
    }

    func isAquaSignApp(_ app: IPAAppMetadata) -> Bool {
        isAquaSignBundleIdentifier(app.bundleIdentifier)
    }

    private func isAquaSignBundleIdentifier(_ value: String) -> Bool {
        let bundleIdentifier = value.lowercased()
        let aquaSignBundleID = "com.andrewdev.aquasign"
        if bundleIdentifier == aquaSignBundleID { return true }

        let teamScopedPrefix = "\(aquaSignBundleID)."
        if bundleIdentifier.hasPrefix(teamScopedPrefix) {
            let teamSuffix = bundleIdentifier.dropFirst(teamScopedPrefix.count)
            if teamSuffix.count == 10,
               teamSuffix.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 122) }) {
                return true
            }
        }

        guard let currentBundleIdentifier = Bundle.main.bundleIdentifier?.lowercased() else { return false }
        return bundleIdentifier == currentBundleIdentifier
    }

    private func normalizedTeamID(_ teamID: String?) -> String? {
        guard let teamID else { return nil }
        let normalized = teamID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func prepareAquaSignEntryIfNeeded() {
        guard aquaSignPreparationTask == nil,
              !apps.contains(where: isAquaSignApp) else { return }

        isPreparingAquaSignEntry = true
        aquaSignPreparationError = nil
        let appBundleURL = Bundle.main.bundleURL
        aquaSignPreparationTask = Task { [weak self] in
            do {
                let prepared = try await Task.detached(priority: .utility) {
                    try IPAArchiveInspector.copyAndValidateAppBundle(at: appBundleURL)
                }.value
                guard let self else {
                    try? FileManager.default.removeItem(at: IPAArchiveInspector.archiveURL(for: prepared.metadata))
                    return
                }
                if self.apps.contains(where: self.isAquaSignApp) {
                    try? FileManager.default.removeItem(at: IPAArchiveInspector.archiveURL(for: prepared.metadata))
                } else {
                    self.upsert(prepared.metadata)
                }
                self.isPreparingAquaSignEntry = false
                self.aquaSignPreparationTask = nil
            } catch {
                self?.aquaSignPreparationError = error.localizedDescription
                self?.isPreparingAquaSignEntry = false
                self?.aquaSignPreparationTask = nil
            }
        }
    }

    func importIPA(
        from sourceURL: URL,
        signing: AppleSigningModel,
        connection: RSDConnectionModel,
        customizeBeforeSigning: Bool = false,
        onImported: @escaping (IPAAppMetadata) -> Void = { _ in }
    ) {
        guard !isBusy, !isRefreshingAll else { return }
        errorMessage = nil
        progress = 0
        stageMessage = "Checking IPA…"
        isBusy = true
        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()

        Task {
            defer {
                if hasSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
                isBusy = false
            }

            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try IPAArchiveInspector.copyAndValidate(from: sourceURL)
                }.value
                upsert(prepared.metadata)
                stageMessage = "IPA validated"
                if customizeBeforeSigning {
                    stageMessage = "IPA added. Review customization before signing."
                    isBusy = false
                    onImported(prepared.metadata)
                    return
                }

                guard connection.isConnected else {
                    stageMessage = "IPA added. Connect the device to sign and install it."
                    return
                }
                isBusy = false
                try await install(prepared.metadata, signing: signing, connection: connection)
            } catch {
                stageMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    func install(
        _ app: IPAAppMetadata,
        signing: AppleSigningModel,
        connection: RSDConnectionModel,
        isPartOfRefreshAll: Bool = false,
        progressOffset: Int = 0,
        totalCount: Int = 1
    ) async throws {
        guard !isBusy, (!isRefreshingAll || isPartOfRefreshAll) else {
            throw IPAAppLibraryError.operationInProgress
        }
        guard connection.isConnected else {
            errorMessage = "Connect the device through LocalDevVPN before installing."
            throw IPAAppLibraryError.connectionRequired
        }
        let archiveURL = IPAArchiveInspector.archiveURL(for: app)
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            errorMessage = "The saved IPA is missing. Choose the file again from Files."
            throw IPAAppLibraryError.missingArchive
        }

        errorMessage = nil
        progress = isPartOfRefreshAll ? Double(progressOffset) / Double(max(totalCount, 1)) : 0
        stageMessage = isPartOfRefreshAll
            ? "Refreshing \(progressOffset + 1) of \(totalCount): \(app.displayName)"
            : "Signing with your Apple ID…"
        isBusy = true
        update(
            app,
            state: .installing,
            error: nil,
            installedAt: app.installedAt,
            profileExpiration: app.profileExpiration,
            managedTeamID: app.managedTeamID
        )
        defer {
            isBusy = false
            if !isPartOfRefreshAll { stageMessage = nil }
        }

        do {
            guard let deviceDetails = connection.deviceDetails,
                  let deviceUDID = deviceDetails.udid,
                  !deviceUDID.isEmpty else {
                throw IPAAppLibraryError.missingDeviceIdentifier
            }
            let signedAppURL = try await signing.signIPA(
                at: archiveURL,
                deviceName: deviceDetails.name,
                deviceUDID: deviceUDID
            )
            let profileExpiration = IPAArchiveInspector.profileExpiration(at: signedAppURL)
                ?? (isAquaSignApp(app)
                    ? signing.status.flatMap { IPAArchiveInspector.profileExpiration(from: $0.profileExpiration) }
                    : nil)
            let extractionDirectory = signedAppURL.deletingLastPathComponent().deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: extractionDirectory) }

            stageMessage = isPartOfRefreshAll
                ? "Refreshing \(progressOffset + 1) of \(totalCount): packaging \(app.displayName)…"
                : "Packaging signed IPA…"
            let signedIPAURL = try IPAArchiveInspector.packageSignedApp(at: signedAppURL)
            defer { try? FileManager.default.removeItem(at: signedIPAURL.deletingLastPathComponent()) }

            try await connection.installIPA(from: signedIPAURL) { [weak self] fraction, stage in
                guard let self else { return }
                let appProgress = min(max(fraction, 0), 1)
                self.progress = isPartOfRefreshAll
                    ? (Double(progressOffset) + appProgress) / Double(max(totalCount, 1))
                    : appProgress
                self.stageMessage = isPartOfRefreshAll
                    ? "Refreshing \(progressOffset + 1) of \(totalCount): \(stage)"
                    : stage
            }
            update(
                app,
                state: .installed,
                error: nil,
                installedAt: Date(),
                profileExpiration: profileExpiration,
                managedTeamID: signing.status?.teamId
            )
            progress = isPartOfRefreshAll
                ? Double(progressOffset + 1) / Double(max(totalCount, 1))
                : 1
            if !isPartOfRefreshAll { stageMessage = "Signed and installed" }
        } catch {
            update(
                app,
                state: .failed,
                error: error.localizedDescription,
                installedAt: app.installedAt,
                profileExpiration: app.profileExpiration,
                managedTeamID: app.managedTeamID
            )
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func refreshAll(signing: AppleSigningModel, connection: RSDConnectionModel) async {
        guard !isBusy, !isRefreshingAll else { return }
        guard let teamID = normalizedTeamID(signing.status?.teamId) else {
            errorMessage = "Sign in to your Apple developer account before refreshing apps."
            return
        }
        let installedApps = refreshableApps(forTeamID: teamID).sorted {
            !isAquaSignApp($0) && isAquaSignApp($1)
        }
        guard !installedApps.isEmpty else {
            errorMessage = "There are no apps installed through this developer team to refresh yet."
            return
        }
        guard connection.isConnected else {
            errorMessage = "Connect through LocalDevVPN before refreshing your apps."
            return
        }

        errorMessage = nil
        refreshSummaryMessage = nil
        progress = 0
        isRefreshingAll = true
        var refreshedCount = 0
        var failedApps: [String] = []

        for (index, app) in installedApps.enumerated() {
            do {
                try await install(
                    app,
                    signing: signing,
                    connection: connection,
                    isPartOfRefreshAll: true,
                    progressOffset: index,
                    totalCount: installedApps.count
                )
                refreshedCount += 1
            } catch {
                failedApps.append(app.displayName)
            }
        }

        isRefreshingAll = false
        progress = 1
        stageMessage = "Refreshed \(refreshedCount) of \(installedApps.count) apps"
        refreshSummaryMessage = stageMessage
        if !failedApps.isEmpty {
            errorMessage = "Could not refresh \(failedApps.count) app\(failedApps.count == 1 ? "" : "s"): \(failedApps.joined(separator: ", ")). Review the affected app cards for details."
        }
    }

    private func upsert(_ app: IPAAppMetadata) {
        if let existing = apps.first(where: { $0.bundleIdentifier == app.bundleIdentifier }),
           existing.archiveFileName != app.archiveFileName {
            try? FileManager.default.removeItem(at: IPAArchiveInspector.archiveURL(named: existing.archiveFileName))
            if let customizedArchiveFileName = existing.customizedArchiveFileName {
                try? FileManager.default.removeItem(at: IPAArchiveInspector.archiveURL(named: customizedArchiveFileName))
            }
        }
        apps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        apps.insert(app, at: 0)
        persist()
    }

    private func update(
        _ app: IPAAppMetadata,
        state: IPAInstallState,
        error: String?,
        installedAt: Date?,
        profileExpiration: Date?,
        managedTeamID: String?
    ) {
        guard let index = apps.firstIndex(where: { $0.bundleIdentifier == app.bundleIdentifier }) else { return }
        apps[index].installState = state
        apps[index].lastError = error
        apps[index].installedAt = installedAt
        apps[index].profileExpiration = profileExpiration
        apps[index].managedTeamID = normalizedTeamID(managedTeamID)
        if state == .installed, let customizedArchiveFileName = app.customizedArchiveFileName {
            apps[index].displayName = app.displayName
            apps[index].version = app.version
            apps[index].customizedArchiveFileName = customizedArchiveFileName
        }
        persist()
    }

    func activateCustomization(_ customizedApp: IPAAppMetadata) {
        guard let index = apps.firstIndex(where: { $0.bundleIdentifier == customizedApp.bundleIdentifier }),
              let customizedArchiveFileName = customizedApp.customizedArchiveFileName else { return }
        let previousCustomizedArchive = apps[index].customizedArchiveFileName
        apps[index].displayName = customizedApp.displayName
        apps[index].version = customizedApp.version
        apps[index].customizedArchiveFileName = customizedArchiveFileName
        persist()
        if let previousCustomizedArchive, previousCustomizedArchive != customizedArchiveFileName {
            try? FileManager.default.removeItem(at: IPAArchiveInspector.archiveURL(named: previousCustomizedArchive))
        }
    }

    func reportError(_ message: String) {
        errorMessage = message
    }

    func reportImportError(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        publishWidgetSnapshot()
    }

    private func publishWidgetSnapshot() {
        let snapshot = refreshableApps
            .map { WidgetAppSnapshot(displayName: $0.displayName, profileExpiration: $0.profileExpiration) }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: appGroupID)?.set(data, forKey: widgetSnapshotKey)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }
}

private struct WidgetAppSnapshot: Encodable {
    let displayName: String
    let profileExpiration: Date?
}

private enum IPAAppLibraryError: LocalizedError {
    case connectionRequired
    case missingArchive
    case missingDeviceIdentifier
    case operationInProgress

    var errorDescription: String? {
        switch self {
        case .connectionRequired:
            "Connect the device through LocalDevVPN before installing."
        case .missingArchive:
            "The saved IPA is missing. Choose the file again from Files."
        case .missingDeviceIdentifier:
            "Could not read this iPhone's device identifier over the Remote Pairing connection. Reconnect the device and try again."
        case .operationInProgress:
            "Another app refresh or installation is already in progress."
        }
    }
}
