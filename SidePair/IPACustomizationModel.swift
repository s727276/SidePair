import Combine
import Foundation
import UIKit

@MainActor
final class IPACustomizationModel: ObservableObject {
    let app: IPAAppMetadata

    @Published var displayName: String
    @Published var version: String
    @Published var confirmsAuthorizedModification = false
    @Published private(set) var bundleIdentifier: String
    @Published private(set) var infoPlistRows: [IPACustomizationInfoRow] = []
    @Published private(set) var iconPreview: UIImage?
    @Published private(set) var iconAvailabilityMessage = "Reading icon assets…"
    @Published private(set) var canReplaceIcon = false
    @Published private(set) var isPreparing = true
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?

    private var manifest: IPACustomizationManifest?
    private var selectedIconPNG: Data?

    var currentInfoPlistRows: [IPACustomizationInfoRow] {
        infoPlistRows.map { row in
            switch row.key {
            case "CFBundleDisplayName":
                IPACustomizationInfoRow(key: row.key, value: displayName)
            case "CFBundleShortVersionString":
                IPACustomizationInfoRow(key: row.key, value: version)
            default:
                row
            }
        }
    }

    var canReviewAndSign: Bool {
        !isPreparing && !isWorking && manifest != nil && confirmsAuthorizedModification
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(app: IPAAppMetadata) {
        self.app = app
        displayName = app.displayName
        version = app.version
        bundleIdentifier = app.bundleIdentifier
    }

    func prepare() {
        guard isPreparing, manifest == nil else { return }
        let appToPrepare = app
        Task {
            do {
                let loadedManifest = try await Task.detached(priority: .userInitiated) {
                    try IPACustomizationArchive.prepare(appToPrepare)
                }.value
                manifest = loadedManifest
                displayName = loadedManifest.displayName
                version = loadedManifest.version
                bundleIdentifier = loadedManifest.bundleIdentifier
                infoPlistRows = loadedManifest.infoRows
                iconAvailabilityMessage = loadedManifest.iconAvailabilityMessage
                canReplaceIcon = !loadedManifest.iconPaths.isEmpty
                if let iconData = loadedManifest.iconPreviewData {
                    iconPreview = UIImage(data: iconData)
                }
                isPreparing = false
            } catch {
                errorMessage = error.localizedDescription
                iconAvailabilityMessage = "Icon assets could not be inspected."
                isPreparing = false
            }
        }
    }

    func chooseIcon(from url: URL) {
        guard canReplaceIcon, !isWorking else { return }
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url)
                }.value
                guard let image = UIImage(data: data), let cgImage = image.cgImage else {
                    throw IPACustomizationError.invalidIcon
                }
                let width = cgImage.width
                let height = cgImage.height
                guard width == height else { throw IPACustomizationError.iconMustBeSquare }
                guard let pngData = image.pngData() else { throw IPACustomizationError.invalidIcon }
                selectedIconPNG = pngData
                iconPreview = image
                iconAvailabilityMessage = "Custom square PNG selected. All supported icon sizes will be replaced."
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func reviewAndSign(
        library: AppLibraryModel,
        signing: AppleSigningModel,
        connection: RSDConnectionModel,
        onSuccess: @escaping () -> Void
    ) {
        guard !isPreparing, !isWorking, let manifest else { return }
        let editedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let editedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !editedName.isEmpty, !editedVersion.isEmpty else {
            errorMessage = "Display name and version must not be empty."
            return
        }

        isWorking = true
        errorMessage = nil
        Task {
            do {
                try IPACustomizationArchive.writeSafeMetadata(
                    displayName: editedName,
                    version: editedVersion,
                    to: manifest.appBundleURL
                )
                if let selectedIconPNG {
                    try replaceIcons(selectedIconPNG, using: manifest)
                }

                let packagedIPA = try await Task.detached(priority: .userInitiated) {
                    try IPAArchiveInspector.packageCustomizedApp(at: manifest.appBundleURL)
                }.value
                defer { try? FileManager.default.removeItem(at: packagedIPA.deletingLastPathComponent()) }

                let customizedFileName = "Customized-\(UUID().uuidString).ipa"
                let customizedArchiveURL = IPAArchiveInspector.archiveURL(named: customizedFileName)
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: packagedIPA, to: customizedArchiveURL)
                }.value

                var customizedApp = app
                customizedApp.displayName = editedName
                customizedApp.version = editedVersion
                customizedApp.customizedArchiveFileName = customizedFileName
                library.activateCustomization(customizedApp)

                try await library.install(customizedApp, signing: signing, connection: connection)
                isWorking = false
                discardWorkspace()
                onSuccess()
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func reportError(_ message: String) {
        errorMessage = message
    }

    func discardWorkspace() {
        guard let manifest else { return }
        try? FileManager.default.removeItem(at: manifest.workspaceURL)
        self.manifest = nil
    }

    private func replaceIcons(_ iconData: Data, using manifest: IPACustomizationManifest) throws {
        guard !manifest.iconPaths.isEmpty,
              let selectedImage = UIImage(data: iconData) else {
            throw IPACustomizationError.noSupportedIconAssets
        }
        for relativePath in manifest.iconPaths {
            let fileURL = manifest.appBundleURL.appendingPathComponent(relativePath)
            let sourceData = try Data(contentsOf: fileURL)
            guard let existingImage = UIImage(data: sourceData), let existingCGImage = existingImage.cgImage else {
                throw IPACustomizationError.unsupportedIconAsset(relativePath)
            }
            let targetSize = CGSize(width: existingCGImage.width, height: existingCGImage.height)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
            let replacement = renderer.image { context in
                context.cgContext.interpolationQuality = .high
                selectedImage.draw(in: CGRect(origin: .zero, size: targetSize))
            }
            guard let pngData = replacement.pngData() else {
                throw IPACustomizationError.invalidIcon
            }
            try pngData.write(to: fileURL, options: .atomic)
        }
    }
}

private enum IPACustomizationError: LocalizedError {
    case invalidIcon
    case iconMustBeSquare
    case noSupportedIconAssets
    case unsupportedIconAsset(String)

    var errorDescription: String? {
        switch self {
        case .invalidIcon:
            "AquaSign couldn't read that PNG image. Choose a square PNG and try again."
        case .iconMustBeSquare:
            "The replacement app icon must be square."
        case .noSupportedIconAssets:
            "This IPA does not contain standalone PNG icon assets that AquaSign can safely replace."
        case let .unsupportedIconAsset(path):
            "AquaSign couldn't safely replace the icon asset at \(path). The original IPA remains unchanged."
        }
    }
}
