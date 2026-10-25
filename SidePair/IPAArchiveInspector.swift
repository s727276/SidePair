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

    static func archiveURL(for metadata: IPAAppMetadata) -> URL {
        importDirectory().appendingPathComponent(metadata.archiveFileName)
    }

    static func profileExpiration(at appBundleURL: URL) -> Date? {
        let profileURL = appBundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let profileData = try? Data(contentsOf: profileURL),
              let plistData = MobileProvisioningProfileReader.plistData(from: profileData),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let profile = plist as? [String: Any] else { return nil }
        return profile["ExpirationDate"] as? Date
    }

    static func packageSignedApp(at appBundleURL: URL) throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidePairSigned-\(UUID().uuidString)", isDirectory: true)
        let payloadDirectory = workspace.appendingPathComponent("Payload", isDirectory: true)
        let archiveURL = workspace.appendingPathComponent("Signed.ipa")

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

    static func plistData(from data: Data) -> Data? {
        var offset = 0
        guard let contentInfo = readElement(in: data, offset: &offset, limit: data.count),
              contentInfo.tag == 0x30,
              let contentInfoChildren = children(of: contentInfo, in: data),
              contentInfoChildren.count >= 2,
              contentInfoChildren[1].tag == 0xA0,
              let explicitContent = children(of: contentInfoChildren[1], in: data),
              let signedData = explicitContent.first(where: { $0.tag == 0x30 }),
              let signedDataChildren = children(of: signedData, in: data),
              signedDataChildren.count >= 3,
              let encapsulatedContent = children(of: signedDataChildren[2], in: data),
              encapsulatedContent.count >= 2,
              encapsulatedContent[1].tag == 0xA0,
              let plistWrapper = children(of: encapsulatedContent[1], in: data),
              let octetString = plistWrapper.first(where: { $0.tag == 0x04 }) else { return nil }
        return data.subdata(in: octetString.content)
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
