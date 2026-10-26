import Foundation
import ZIPFoundation

struct IPAAppMetadata: Codable, Equatable, Identifiable {
    let bundleIdentifier: String
    var displayName: String
    var version: String
    let archiveFileName: String
    var customizedArchiveFileName: String? = nil
    var selfRefreshArchiveFileName: String? = nil
    var selfRefreshBuildNumber: String? = nil
    var managedTeamID: String? = nil
    var installState: IPAInstallState
    var lastError: String?
    var installedAt: Date?
    var profileExpiration: Date?

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

    static func copyAndValidateAppBundle(at appBundleURL: URL) throws -> PreparedIPA {
        let sourceIPA = try packageAppBundle(at: appBundleURL, prefix: "AquaSignSource")
        defer { try? FileManager.default.removeItem(at: sourceIPA.deletingLastPathComponent()) }
        let prepared = try copyAndValidate(from: sourceIPA)
        guard let teamID = profileTeamIdentifier(at: appBundleURL) else { return prepared }

        var metadata = prepared.metadata
        metadata.managedTeamID = teamID
        metadata.installState = .installed
        metadata.installedAt = Date()
        metadata.profileExpiration = profileExpiration(at: appBundleURL)
        return PreparedIPA(metadata: metadata, fileURL: prepared.fileURL)
    }

    static func archiveURL(for metadata: IPAAppMetadata, preferSelfRefreshSource: Bool = false) -> URL {
        if preferSelfRefreshSource,
           let selfRefreshArchiveFileName = metadata.selfRefreshArchiveFileName {
            let selfRefreshURL = archiveURL(named: selfRefreshArchiveFileName)
            if FileManager.default.fileExists(atPath: selfRefreshURL.path) { return selfRefreshURL }
        }
        return archiveURL(named: metadata.customizedArchiveFileName ?? metadata.archiveFileName)
    }

    static func archiveURL(named fileName: String) -> URL {
        importDirectory().appendingPathComponent(fileName)
    }

    static func profileExpiration(at appBundleURL: URL) -> Date? {
        let profileURL = appBundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let profileData = try? Data(contentsOf: profileURL) else { return nil }
        return MobileProvisioningProfileReader.expirationDate(from: profileData)
    }

    static func profileTeamIdentifier(at appBundleURL: URL) -> String? {
        let profileURL = appBundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let profileData = try? Data(contentsOf: profileURL) else { return nil }
        return MobileProvisioningProfileReader.teamIdentifier(from: profileData)
    }

    static func profileExpiration(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func packageSignedApp(at appBundleURL: URL) throws -> URL {
        try packageAppBundle(at: appBundleURL, prefix: "SidePairSigned")
    }

    static func packageCustomizedApp(at appBundleURL: URL) throws -> URL {
        try packageAppBundle(at: appBundleURL, prefix: "SidePairCustomized")
    }

    private static func packageAppBundle(at appBundleURL: URL, prefix: String) throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let payloadDirectory = workspace.appendingPathComponent("Payload", isDirectory: true)
        let archiveURL = workspace.appendingPathComponent("\(prefix).ipa")

        do {
            try FileManager.default.createDirectory(
                at: payloadDirectory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            try FileManager.default.copyItem(
                at: appBundleURL,
                to: payloadDirectory.appendingPathComponent(appBundleURL.lastPathComponent, isDirectory: true)
            )
            try FileManager.default.zipItem(
                at: payloadDirectory,
                to: archiveURL,
                shouldKeepParent: true,
                compressionMethod: .deflate
            )
            return archiveURL
        } catch {
            try? FileManager.default.removeItem(at: workspace)
            throw error
        }
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
        let displayName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? bundleIdentifier
        let version = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)
            ?? "Unknown"
        return (bundleIdentifier, displayName, version)
    }
}

private enum MobileProvisioningProfileReader {
    private struct Element {
        let tag: UInt8
        let content: Range<Int>
    }

    static func expirationDate(from data: Data) -> Date? {
        if let expiration = plistExpiration(in: data) { return expiration }
        var offset = 0
        guard let root = readElement(in: data, offset: &offset, limit: data.count) else { return nil }
        return expirationDate(in: root, data: data)
    }

    static func teamIdentifier(from data: Data) -> String? {
        if let teamID = profileTeamIdentifier(in: data) { return teamID }
        var offset = 0
        guard let root = readElement(in: data, offset: &offset, limit: data.count) else { return nil }
        return profileTeamIdentifier(in: root, data: data)
    }

    private static func profileTeamIdentifier(in element: Element, data: Data) -> String? {
        if element.tag == 0x04,
           let teamID = profileTeamIdentifier(in: data.subdata(in: element.content)) {
            return teamID
        }
        if element.tag == 0x24,
           let octets = octetStringContent(in: element, data: data),
           let teamID = profileTeamIdentifier(in: octets) {
            return teamID
        }
        guard element.tag & 0x20 != 0,
              let nestedElements = children(of: element, in: data) else { return nil }
        for nested in nestedElements {
            if let teamID = profileTeamIdentifier(in: nested, data: data) { return teamID }
        }
        return nil
    }

    private static func profileTeamIdentifier(in data: Data) -> String? {
        guard let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let profile = propertyList as? [String: Any],
              let teamIdentifiers = profile["TeamIdentifier"] as? [String] else { return nil }
        return teamIdentifiers.first
    }

    private static func expirationDate(in element: Element, data: Data) -> Date? {
        if element.tag == 0x04,
           let expiration = plistExpiration(in: data.subdata(in: element.content)) {
            return expiration
        }
        if element.tag == 0x24,
           let octets = octetStringContent(in: element, data: data),
           let expiration = plistExpiration(in: octets) {
            return expiration
        }
        guard element.tag & 0x20 != 0,
              let nestedElements = children(of: element, in: data) else { return nil }
        for nested in nestedElements {
            if let expiration = expirationDate(in: nested, data: data) { return expiration }
        }
        return nil
    }

    private static func plistExpiration(in data: Data) -> Date? {
        guard let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let profile = propertyList as? [String: Any] else { return nil }
        return profile["ExpirationDate"] as? Date
    }

    private static func octetStringContent(in element: Element, data: Data) -> Data? {
        guard element.tag == 0x24,
              let segments = children(of: element, in: data) else { return nil }
        var content = Data()
        for segment in segments {
            if segment.tag == 0x04 {
                content.append(data.subdata(in: segment.content))
            } else if segment.tag == 0x24,
                      let nested = octetStringContent(in: segment, data: data) {
                content.append(nested)
            } else {
                return nil
            }
        }
        return content
    }

    private static func children(of element: Element, in data: Data) -> [Element]? {
        var elements: [Element] = []
        var offset = element.content.lowerBound
        while offset < element.content.upperBound {
            guard let child = readElement(in: data, offset: &offset, limit: element.content.upperBound) else { return nil }
            elements.append(child)
        }
        return elements
    }

    private static func readElement(in data: Data, offset: inout Int, limit: Int) -> Element? {
        guard offset < limit else { return nil }
        let tag = data[offset]
        offset += 1
        guard offset < limit else { return nil }

        let firstLengthByte = data[offset]
        offset += 1
        if firstLengthByte == 0x80 {
            guard tag & 0x20 != 0 else { return nil }
            let contentStart = offset
            var cursor = offset
            while cursor + 1 < limit {
                if data[cursor] == 0, data[cursor + 1] == 0 {
                    offset = cursor + 2
                    return Element(tag: tag, content: contentStart..<cursor)
                }
                guard readElement(in: data, offset: &cursor, limit: limit) != nil else { return nil }
            }
            return nil
        }

        var length = 0
        if firstLengthByte & 0x80 == 0 {
            length = Int(firstLengthByte)
        } else {
            let lengthByteCount = Int(firstLengthByte & 0x7F)
            guard lengthByteCount > 0,
                  lengthByteCount <= MemoryLayout<Int>.size,
                  offset + lengthByteCount <= limit else { return nil }
            for _ in 0..<lengthByteCount {
                let byte = Int(data[offset])
                offset += 1
                guard length <= (Int.max - byte) / 256 else { return nil }
                length = length * 256 + byte
            }
        }

        guard length <= limit - offset else { return nil }
        let content = offset..<(offset + length)
        offset += length
        return Element(tag: tag, content: content)
    }
}

private enum IPAArchiveError: LocalizedError {
    case invalidArchive
    case appBundleCount
    case missingInfoPlist
    case invalidInfoPlist
    case missingExecutable

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
        }
    }
}
