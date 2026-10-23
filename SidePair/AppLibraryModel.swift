import Combine
import Foundation

@MainActor
final class AppLibraryModel: ObservableObject {
    @Published private(set) var apps: [IPAAppMetadata] = []
    @Published private(set) var isBusy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var stageMessage: String?
    @Published private(set) var errorMessage: String?

    private let storageKey = "sidepairImportedIPAApps"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([IPAAppMetadata].self, from: data) {
            apps = saved
        }
    }

    func importIPA(from sourceURL: URL, signing: AppleSigningModel, connection: RSDConnectionModel) {
        guard !isBusy else { return }
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

                guard connection.isConnected else {
                    stageMessage = "IPA added. Connect the device to sign and install it."
                    return
                }
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
        connection: RSDConnectionModel
    ) async throws {
        guard connection.isConnected else {
            errorMessage = "Connect the device through LocalDevVPN before installing."
            return
        }
        let archiveURL = IPAArchiveInspector.archiveURL(for: app)
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            errorMessage = "The saved IPA is missing. Choose the file again from Files."
            return
        }

        errorMessage = nil
        stageMessage = "Signing with your Apple ID…"
        progress = 0
        isBusy = true
        update(app, state: .installing, error: nil, installedAt: app.installedAt)
        defer {
            isBusy = false
            stageMessage = nil
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
            let extractionDirectory = signedAppURL.deletingLastPathComponent().deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: extractionDirectory) }

            stageMessage = "Packaging signed IPA…"
            let signedIPAURL = try IPAArchiveInspector.packageSignedApp(at: signedAppURL)
            defer { try? FileManager.default.removeItem(at: signedIPAURL.deletingLastPathComponent()) }

            try await connection.installIPA(from: signedIPAURL) { [weak self] fraction, stage in
                guard let self else { return }
                self.progress = fraction
                self.stageMessage = stage
            }
            update(app, state: .installed, error: nil, installedAt: Date())
            progress = 1
            stageMessage = "Signed and installed"
        } catch {
            update(app, state: .failed, error: error.localizedDescription, installedAt: app.installedAt)
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func upsert(_ app: IPAAppMetadata) {
        if let existing = apps.first(where: { $0.bundleIdentifier == app.bundleIdentifier }),
           existing.archiveFileName != app.archiveFileName {
            let oldArchive = IPAArchiveInspector.archiveURL(for: existing)
            try? FileManager.default.removeItem(at: oldArchive)
        }
        apps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        apps.insert(app, at: 0)
        persist()
    }

    private func update(_ app: IPAAppMetadata, state: IPAInstallState, error: String?, installedAt: Date?) {
        guard let index = apps.firstIndex(where: { $0.bundleIdentifier == app.bundleIdentifier }) else { return }
        apps[index].installState = state
        apps[index].lastError = error
        apps[index].installedAt = installedAt
        persist()
    }

    func reportImportError(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

private enum IPAAppLibraryError: LocalizedError {
    case missingDeviceIdentifier

    var errorDescription: String? {
        "Could not read this iPhone's device identifier over the Remote Pairing connection. Reconnect the device and try again."
    }
}
