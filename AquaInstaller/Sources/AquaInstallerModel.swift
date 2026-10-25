import Combine
import Foundation
import Security

@MainActor
final class AquaInstallerModel: ObservableObject {
    @Published private(set) var devices: [ConnectedUSBDevice] = []
    @Published var selectedDeviceUDID: String?
    @Published var selectedIPAURL: URL?
    @Published var appleID = ""
    @Published var password = ""
    @Published private(set) var isScanning = false
    @Published private(set) var isWorking = false
    @Published private(set) var hasSavedSession = false
    @Published private(set) var savedAccountName: String?
    @Published private(set) var statusMessage = "Connect and unlock an iPhone over USB."
    @Published private(set) var errorMessage: String?
    @Published var twoFactorPrompt: AppleTwoFactorPrompt?

    private var twoFactorReply: ((String?) -> Void)?
    private let appBundleIdentifier = "com.Andrewdev.aquasign"

    var selectedDevice: ConnectedUSBDevice? {
        devices.first { $0.udid == selectedDeviceUDID }
    }

    private var signingStorageDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aqua Installer/Signing", isDirectory: true)
    }

    init() {
        if let sessionJSON = try? SigningSessionKeychain.load() {
            hasSavedSession = true
            if let data = sessionJSON.data(using: .utf8),
               let session = try? JSONDecoder().decode(StoredAppleSession.self, from: data) {
                savedAccountName = session.appleId
            }
            statusMessage = "A saved Apple developer session is available in this Mac's Keychain."
        }
    }

    func refreshDevices() {
        guard !isScanning, !isWorking else { return }
        isScanning = true
        errorMessage = nil
        statusMessage = "Looking for a paired iPhone connected by USB…"

        Task {
            defer { isScanning = false }
            do {
                let foundDevices = try await Task.detached(priority: .utility) {
                    try DeviceCtl.discoverWiredDevices()
                }.value
                devices = foundDevices
                if !foundDevices.contains(where: { $0.udid == selectedDeviceUDID }) {
                    selectedDeviceUDID = foundDevices.first?.udid
                }
                statusMessage = foundDevices.isEmpty
                    ? "No wired iPhone found. Connect it, unlock it, and trust this Mac."
                    : "Ready to sign AquaSign locally and install over USB."
            } catch {
                devices = []
                selectedDeviceUDID = nil
                errorMessage = error.localizedDescription
                statusMessage = "Device scan needs attention."
            }
        }
    }

    func chooseIPA(_ url: URL) {
        selectedIPAURL = url
        errorMessage = nil
        statusMessage = "Selected \(url.lastPathComponent). Aqua Installer will verify it is AquaSign before signing."
    }

    func reportError(_ message: String) {
        errorMessage = message
    }

    func installAquaSign() {
        guard !isWorking else { return }
        guard let device = selectedDevice else {
            errorMessage = "Connect and unlock a paired iPhone over USB, then scan for devices."
            return
        }
        guard let sourceIPAURL = selectedIPAURL else {
            errorMessage = "Choose the unsigned AquaSign IPA downloaded from GitHub Actions."
            return
        }

        let suppliedAppleID = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let suppliedPassword = password
        if !hasSavedSession && (suppliedAppleID.isEmpty || suppliedPassword.isEmpty) {
            errorMessage = "Enter your Apple ID and password to sign AquaSign locally."
            return
        }

        let hasSecurityScope = sourceIPAURL.startAccessingSecurityScopedResource()
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AquaInstaller-\(UUID().uuidString)", isDirectory: true)
        isWorking = true
        errorMessage = nil

        Task {
            defer {
                if hasSecurityScope { sourceIPAURL.stopAccessingSecurityScopedResource() }
                isWorking = false
                password = ""
            }

            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workingDirectory.path)
                    let copiedIPA = workingDirectory.appendingPathComponent("AquaSign.ipa")
                    try FileManager.default.copyItem(at: sourceIPAURL, to: copiedIPA)
                }.value
                defer { try? FileManager.default.removeItem(at: workingDirectory) }
                let copiedIPA = workingDirectory.appendingPathComponent("AquaSign.ipa")

                statusMessage = "Checking the selected IPA…"
                let bundleIdentifier = try await Task.detached(priority: .userInitiated) {
                    try DeviceCtl.bundleIdentifier(in: copiedIPA)
                }.value
                guard bundleIdentifier == appBundleIdentifier else {
                    throw DeviceCtlError.wrongApp(bundleIdentifier)
                }

                try FileManager.default.createDirectory(
                    at: signingStorageDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: signingStorageDirectory.path
                )

                let sessionJSON: String
                if let existingSession = try SigningSessionKeychain.load() {
                    sessionJSON = existingSession
                } else {
                    statusMessage = "Authenticating with Apple. Credentials are not sent to GitHub."
                    sessionJSON = try await SigningBridge.signIn(
                        appleID: suppliedAppleID,
                        password: suppliedPassword,
                        storageDirectory: signingStorageDirectory,
                        bundleID: appBundleIdentifier,
                        deviceName: device.name,
                        deviceUDID: device.udid,
                        presentTwoFactor: { [weak self] requestJSON, reply in
                            guard let self else {
                                reply(nil)
                                return
                            }
                            self.presentTwoFactor(requestJSON: requestJSON, reply: reply)
                        }
                    )
                    try SigningSessionKeychain.save(sessionJSON)
                    hasSavedSession = true
                    savedAccountName = suppliedAppleID
                    appleID = ""
                }

                statusMessage = "Signing AquaSign with your Apple development profile…"
                let signedAppURL = try await SigningBridge.signIPA(
                    sessionJSON: sessionJSON,
                    storageDirectory: signingStorageDirectory,
                    ipaURL: copiedIPA,
                    deviceName: device.name,
                    deviceUDID: device.udid
                )
                let signedWorkspace = signedAppURL.deletingLastPathComponent().deletingLastPathComponent()
                defer { try? FileManager.default.removeItem(at: signedWorkspace) }

                statusMessage = "Installing AquaSign on \(device.name) over USB. Keep the iPhone unlocked."
                try await Task.detached(priority: .userInitiated) {
                    try DeviceCtl.install(appBundleURL: signedAppURL, on: device)
                }.value
                statusMessage = "AquaSign was signed locally and installed on \(device.name)."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Installation stopped. No unsigned app was installed."
            }
        }
    }

    func forgetSavedSession() {
        do {
            try SigningSessionKeychain.delete()
            hasSavedSession = false
            savedAccountName = nil
            statusMessage = "Saved Apple developer session removed from this Mac."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func respondToTwoFactor(action: String, code: String? = nil, phoneID: UInt32? = nil) {
        var response: [String: Any] = ["action": action]
        if let code { response["code"] = code }
        if let phoneID { response["id"] = phoneID }
        guard JSONSerialization.isValidJSONObject(response),
              let data = try? JSONSerialization.data(withJSONObject: response),
              let json = String(data: data, encoding: .utf8) else {
            cancelTwoFactor()
            return
        }
        let reply = twoFactorReply
        twoFactorReply = nil
        twoFactorPrompt = nil
        reply?(json)
    }

    func cancelTwoFactor() {
        let reply = twoFactorReply
        twoFactorReply = nil
        twoFactorPrompt = nil
        reply?(nil)
    }

    private func presentTwoFactor(requestJSON: String, reply: @escaping (String?) -> Void) {
        guard let data = requestJSON.data(using: .utf8),
              let request = try? JSONDecoder().decode(AppleTwoFactorRequest.self, from: data) else {
            errorMessage = "Apple requested verification, but Aqua Installer could not read the request."
            reply(nil)
            return
        }
        twoFactorReply = reply
        twoFactorPrompt = AppleTwoFactorPrompt(request: request)
    }
}

private struct StoredAppleSession: Decodable {
    let appleId: String
}

private enum SigningSessionKeychain {
    private static let service = "com.Andrewdev.aquainstaller.apple-signing"
    private static let account = "developer-session"

    static func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let sessionJSON = String(data: data, encoding: .utf8) else {
            throw SigningSessionKeychainError(status)
        }
        return sessionJSON
    }

    static func save(_ sessionJSON: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(sessionJSON.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SigningSessionKeychainError(addStatus) }
        } else if status != errSecSuccess {
            throw SigningSessionKeychainError(status)
        }
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SigningSessionKeychainError(status)
        }
    }
}

private struct SigningSessionKeychainError: LocalizedError {
    let status: OSStatus

    init(_ status: OSStatus) { self.status = status }

    var errorDescription: String? {
        "Could not access the Apple signing session in this Mac's Keychain (\(status))."
    }
}
