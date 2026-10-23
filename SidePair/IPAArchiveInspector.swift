import Foundation
import ZIPFoundation

struct IPAAppMetadata: Codable, Equatable, Identifiable {
    let bundleIdentifier: String
    let displayName: String
    let version: String
    let archiveFileName: String
    var installState: IPAInstallState
    var lastError: String?
    var installedAt: Date?

    var id: String { bundleIdentifier }
}

enum IPAInstallState: String, Codable {
    case ready
    case installing
    case installed
    case failed
}

struct PreparedIPA {
    let metadata: IPAAppMetadata
    let fileURL: URL
}

enum IPAArchiveInspector {
    static func copyAndValidate(from sourceURL: URL) throws -> PreparedIPA {
        let directory = importDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        let destination = directory.appendingPathComponent("\(UUID().uuidString).ipa")
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        do {
            let details = try inspect(destination)
            let metadata = IPAAppMetadata(
                bundleIdentifier: details.bundleIdentifier,
                displayName: details.displayName,
                version: details.version,
                archiveFileName: destination.lastPathComponent,
                installState: .ready,
                lastError: nil,
                installedAt: nil
            )
            return PreparedIPA(metadata: metadata, fileURL: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func archiveURL(for metadata: IPAAppMetadata) -> URL {
        importDirectory().appendingPathComponent(metadata.archiveFileName)
    }

    private static func importDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SidePairImportedIPAs", isDirectory: true)
    }

    private static func inspect(_ url: URL) throws -> (bundleIdentifier: String, displayName: String, version: String) {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw IPAArchiveError.invalidArchive
        }

        let appFolders = Set(archive.compactMap { entry -> String? in
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count >= 2,
                  components[0] == "Payload",
                  components[1].hasSuffix(".app") else { return nil }
            return String(components[1])
        })
        guard appFolders.count == 1, let appFolder = appFolders.first else {
            throw IPAArchiveError.appBundleCount
        }

        let appRoot = "Payload/\(appFolder)"
        let infoPath = "\(appRoot)/Info.plist"
        guard let infoEntry = archive[infoPath] else { throw IPAArchiveError.missingInfoPlist }

        var infoData = Data()
        try archive.extract(infoEntry, consumer: { chunk in infoData.append(chunk) })
        guard let info = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any],
              let bundleIdentifier = info["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty,
              !executable.contains("/"),
              !executable.contains("..") else {
            throw IPAArchiveError.invalidInfoPlist
        }

        guard archive["\(appRoot)/\(executable)"] != nil else { throw IPAArchiveError.missingExecutable }
        guard archive["\(appRoot)/_CodeSignature/CodeResources"] != nil,
              archive["\(appRoot)/embedded.mobileprovision"] != nil else {
            throw IPAArchiveError.missingDeveloperSignature
        }

        let displayName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? bundleIdentifier
        let version = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)
            ?? "Unknown"
        return (bundleIdentifier, displayName, version)
    }
}

private enum IPAArchiveError: LocalizedError {
    case invalidArchive
    case appBundleCount
    case missingInfoPlist
    case invalidInfoPlist
    case missingExecutable
    case missingDeveloperSignature

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            "This file is not a readable IPA archive. Choose an .ipa file from Files."
        case .appBundleCount:
            "The IPA must contain exactly one app in its Payload folder."
        case .missingInfoPlist:
            "The app bundle is missing Info.plist."
        case .invalidInfoPlist:
            "The app bundle has an invalid Info.plist or bundle identifier."
        case .missingExecutable:
            "The app executable listed in Info.plist is missing from the bundle."
        case .missingDeveloperSignature:
            "This IPA does not contain a developer code signature and embedded provisioning profile. Install only a developer-signed IPA."
        }
    }
}
