import Foundation
import ZIPFoundation

struct IPACustomizationInfoRow: Identifiable, Sendable {
    let key: String
    let value: String

    var id: String { key }
}

struct IPACustomizationManifest: Sendable {
    let workspaceURL: URL
    let appBundleURL: URL
    let bundleIdentifier: String
    let displayName: String
    let version: String
    let infoRows: [IPACustomizationInfoRow]
    let iconPaths: [String]
    let iconPreviewData: Data?
    let iconAvailabilityMessage: String
}

enum IPACustomizationArchiveError: LocalizedError {
    case missingArchive
    case invalidPayload
    case identityChanged
    case invalidMetadata

    var errorDescription: String? {
        switch self {
        case .missingArchive:
            "The original IPA is missing. Choose it again from Files before customizing."
        case .invalidPayload:
            "AquaSign could not safely open this IPA. The original archive was left unchanged."
        case .identityChanged:
            "The app's bundle identifier does not match the imported IPA. AquaSign will not change app identity in this customization flow."
        case .invalidMetadata:
            "The app's Info.plist is malformed or missing required display information."
        }
    }
}

enum IPACustomizationArchive {
    static func prepare(_ app: IPAAppMetadata) throws -> IPACustomizationManifest {
        let sourceIPA = IPAArchiveInspector.archiveURL(for: app)
        guard FileManager.default.fileExists(atPath: sourceIPA.path) else {
            throw IPACustomizationArchiveError.missingArchive
        }

        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AquaSignCustomization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        do {
            try FileManager.default.unzipItem(at: sourceIPA, to: workspaceURL)
            let payloadURL = workspaceURL.appendingPathComponent("Payload", isDirectory: true)
            let appBundles = try FileManager.default.contentsOfDirectory(
                at: payloadURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "app" }
            guard appBundles.count == 1, let appBundleURL = appBundles.first else {
                throw IPACustomizationArchiveError.invalidPayload
            }

            let infoPlistURL = appBundleURL.appendingPathComponent("Info.plist")
            let infoData = try Data(contentsOf: infoPlistURL)
            var format = PropertyListSerialization.PropertyListFormat.xml
            guard let info = try PropertyListSerialization.propertyList(
                from: infoData,
                options: [],
                format: &format
            ) as? [String: Any],
            let bundleIdentifier = info["CFBundleIdentifier"] as? String,
            bundleIdentifier == app.bundleIdentifier,
            !bundleIdentifier.isEmpty else {
                throw IPACustomizationArchiveError.identityChanged
            }

            let displayName = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? app.displayName
            let version = (info["CFBundleShortVersionString"] as? String)
                ?? (info["CFBundleVersion"] as? String)
                ?? app.version
            guard !displayName.isEmpty, !version.isEmpty else {
                throw IPACustomizationArchiveError.invalidMetadata
            }

            let iconPaths = supportedIconPaths(in: info, appBundleURL: appBundleURL)
            let iconPreviewData = iconPaths
                .sorted { iconRank($0) > iconRank($1) }
                .first
                .flatMap { try? Data(contentsOf: appBundleURL.appendingPathComponent($0)) }
            let iconMessage = iconPaths.isEmpty
                ? "This IPA uses icon assets AquaSign cannot safely replace."
                : "Square PNG · supported icon assets only."
            let infoRows = info.keys.sorted().map { key in
                IPACustomizationInfoRow(key: key, value: displayValue(info[key] ?? ""))
            }

            return IPACustomizationManifest(
                workspaceURL: workspaceURL,
                appBundleURL: appBundleURL,
                bundleIdentifier: bundleIdentifier,
                displayName: displayName,
                version: version,
                infoRows: infoRows,
                iconPaths: iconPaths,
                iconPreviewData: iconPreviewData,
                iconAvailabilityMessage: iconMessage
            )
        } catch {
            try? FileManager.default.removeItem(at: workspaceURL)
            throw error
        }
    }

    static func writeSafeMetadata(displayName: String, version: String, to appBundleURL: URL) throws {
        let infoPlistURL = appBundleURL.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoPlistURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var info = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any] else {
            throw IPACustomizationArchiveError.invalidMetadata
        }

        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IPACustomizationArchiveError.invalidMetadata
        }
        info["CFBundleDisplayName"] = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        info["CFBundleShortVersionString"] = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let updatedData = try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0)
        try updatedData.write(to: infoPlistURL, options: .atomic)
    }

    private static func supportedIconPaths(in info: [String: Any], appBundleURL: URL) -> [String] {
        var iconNames: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = info[key] as? [String: Any],
                  let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any] else { continue }
            iconNames.append(contentsOf: primaryIcon["CFBundleIconFiles"] as? [String] ?? [])
            if let iconName = primaryIcon["CFBundleIconName"] as? String {
                iconNames.append(iconName)
            }
        }
        if let legacyIconNames = info["CFBundleIconFiles"] as? [String] {
            iconNames.append(contentsOf: legacyIconNames)
        }
        let normalizedNames = Set(iconNames.map { ($0 as NSString).lastPathComponent })
        guard !normalizedNames.isEmpty,
              let enumerator = FileManager.default.enumerator(
                at: appBundleURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        var paths: [String] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "png" {
            guard fileURL.deletingLastPathComponent().standardizedFileURL == appBundleURL.standardizedFileURL else { continue }
            let fileName = fileURL.lastPathComponent
            let baseName = (fileName as NSString).deletingPathExtension
            let matches = normalizedNames.contains { iconName in
                let iconBaseName = (iconName as NSString).deletingPathExtension
                return baseName == iconName || baseName == iconBaseName || baseName.hasPrefix("\(iconBaseName)@")
            }
            guard matches else { continue }
            let relativePath = String(fileURL.path.dropFirst(appBundleURL.path.count + 1))
            paths.append(relativePath)
        }
        return Array(Set(paths)).sorted()
    }

    private static func iconRank(_ path: String) -> Int {
        if path.contains("@3x") { return 3 }
        if path.contains("@2x") { return 2 }
        return 1
    }

    private static func displayValue(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0),
           let string = String(data: data, encoding: .utf8) {
            return String(string.prefix(240))
        }
        return String(describing: value)
    }
}
