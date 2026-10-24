import Combine
import Darwin
import Foundation
import Security

struct AppleSigningStatus: Decodable, Equatable {
    let appleId: String
    let teamName: String
    let teamId: String
    let certificateName: String
    let certificateSerial: String
    let certificateStatus: String
    let certificateExpiration: String
    let profileStatus: String
    let profileUuid: String
    let profileExpiration: String
    let profileError: String
}

struct AppleTrustedNumber: Decodable, Identifiable {
    let numberWithDialCode: String
    let lastTwoDigits: String
    let pushMode: String
    let id: UInt32
}

struct AppleTwoFactorRequest: Decodable {
    let lastError: String?
    let unknown: Bool
    let sms: Bool
    let numbers: [AppleTrustedNumber]
    let selectedNumberId: UInt32?
}

struct AppleTwoFactorPrompt: Identifiable {
    let id = UUID()
    let request: AppleTwoFactorRequest
}

@MainActor
final class AppleSigningModel: ObservableObject {
    @Published var appleId = ""
    @Published var password = ""
    @Published private(set) var status: AppleSigningStatus?
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published var twoFactorPrompt: AppleTwoFactorPrompt?

    private var twoFactorReply: ((String?) -> Void)?
    private var restoreStarted = false

    var hasSigningBridge: Bool {
        #if SIGNING_BRIDGE
        true
        #else
        false
        #endif
    }

    func restoreSessionIfAvailable() {
        guard !restoreStarted else { return }
        restoreStarted = true
        guard hasSigningBridge else { return }
        do {
            guard let session = try AppleSigningKeychain.load() else { return }
            startRestore(sessionJSON: session)
        } catch {
            errorMessage = "Could not read the saved Apple signing session: \(error.localizedDescription)"
        }
    }

    func signIn(deviceName: String, deviceUDID: String) {
        guard !isWorking else { return }
        guard hasSigningBridge else {
            errorMessage = "This build does not include the Apple signing engine. No credentials were sent or saved."
            password = ""
            return
        }

        let account = appleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard account.contains("@"), !password.isEmpty else {
            errorMessage = "Enter a valid Apple ID and password."
            return
        }
        guard !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !deviceUDID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Connect this iPhone through LocalDevVPN before signing in so Apple can register it for the provisioning profile."
            return
        }

        authenticate(
            account: account,
            password: password,
            deviceName: deviceName,
            deviceUDID: deviceUDID
        )
    }

    func reportError(_ message: String) {
        errorMessage = message
    }

    private func authenticate(
        account: String,
        password: String,
        deviceName: String,
        deviceUDID: String
    ) {
        do {
            try prepareProtectedStorage()
        } catch {
            errorMessage = "Could not prepare protected local signing storage: \(error.localizedDescription)"
            self.password = ""
            return
        }

        let suppliedPassword = password
        self.password = ""
        errorMessage = nil
        status = nil
        isWorking = true

        #if SIGNING_BRIDGE
        let callbackContext = SigningTwoFactorContext { [weak self] requestJSON, reply in
            guard let self else {
                reply(nil)
                return
            }
            self.presentTwoFactor(requestJSON: requestJSON, reply: reply)
        }
        let retainedContext = Unmanaged.passRetained(callbackContext).toOpaque()
        let storagePath = Self.signingStorageURL().path
        let bundleID = Bundle.main.bundleIdentifier ?? "com.Andrewdev.aquasign"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var sessionOutput: UnsafeMutablePointer<CChar>?
            var statusOutput: UnsafeMutablePointer<CChar>?
            var errorOutput: UnsafeMutablePointer<CChar>?
            let result = invokeAppleSignIn(
                account: account,
                password: suppliedPassword,
                storagePath: storagePath,
                bundleID: bundleID,
                deviceName: deviceName,
                deviceUDID: deviceUDID,
                callbackContext: retainedContext,
                outSessionJSON: &sessionOutput,
                outStatusJSON: &statusOutput,
                outError: &errorOutput
            )

            let sessionJSON = sessionOutput.map { String(cString: $0) }
            let statusJSON = statusOutput.map { String(cString: $0) }
            let errorText = errorOutput.map { String(cString: $0) }
            if let sessionOutput { sidepair_signing_string_free(sessionOutput) }
            if let statusOutput { sidepair_signing_string_free(statusOutput) }
            if let errorOutput { sidepair_signing_string_free(errorOutput) }
            Unmanaged<SigningTwoFactorContext>.fromOpaque(retainedContext).release()

            DispatchQueue.main.async {
                guard let self else { return }
                self.isWorking = false
                self.twoFactorPrompt = nil
                self.twoFactorReply = nil
                if result == 0, let sessionJSON, let statusJSON,
                   let statusData = statusJSON.data(using: .utf8),
                   let signingStatus = try? JSONDecoder().decode(AppleSigningStatus.self, from: statusData) {
                    do {
                        try AppleSigningKeychain.save(sessionJSON)
                        self.appleId = account
                        self.status = signingStatus
                        self.errorMessage = signingStatus.profileError.isEmpty ? nil : signingStatus.profileError
                    } catch {
                        self.errorMessage = "Apple sign-in succeeded, but the session could not be saved securely: \(error.localizedDescription)"
                    }
                } else {
                    self.errorMessage = errorText ?? "Apple sign-in failed (\(result)). Check the credentials or verification response and try again."
                }
            }
        }
        #endif
    }

    func signIPA(at ipaURL: URL, deviceName: String, deviceUDID: String) async throws -> URL {
        #if SIGNING_BRIDGE
        try prepareProtectedStorage()
        guard let sessionJSON = try AppleSigningKeychain.load() else {
            throw AppleSigningBridgeError.noSavedSession
        }

        let storagePath = Self.signingStorageURL().path
        let sourcePath = ipaURL.path
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var signedAppOutput: UnsafeMutablePointer<CChar>?
                var errorOutput: UnsafeMutablePointer<CChar>?
                let result = sessionJSON.withCString { sessionPointer in
                    storagePath.withCString { storagePointer in
                        sourcePath.withCString { sourcePointer in
                            deviceName.withCString { deviceNamePointer in
                                deviceUDID.withCString { deviceUDIDPointer in
                                    sidepair_sign_ipa(
                                        sessionPointer,
                                        storagePointer,
                                        sourcePointer,
                                        deviceNamePointer,
                                        deviceUDIDPointer,
                                        &signedAppOutput,
                                        &errorOutput
                                    )
                                }
                            }
                        }
                    }
                }

                let signedAppPath = signedAppOutput.map { String(cString: $0) }
                let errorText = errorOutput.map { String(cString: $0) }
                if let signedAppOutput { sidepair_signing_string_free(signedAppOutput) }
                if let errorOutput { sidepair_signing_string_free(errorOutput) }

                if result == 0, let signedAppPath {
                    continuation.resume(returning: URL(fileURLWithPath: signedAppPath, isDirectory: true))
                } else {
                    continuation.resume(throwing: AppleSigningBridgeError.failed(
                        errorText ?? "The IPA could not be signed with the saved Apple account."
                    ))
                }
            }
        }
        #else
        throw AppleSigningBridgeError.engineUnavailable
        #endif
    }

    func respondToTwoFactor(action: String, code: String? = nil, phoneId: UInt32? = nil) {
        var response: [String: Any] = ["action": action]
        if let code { response["code"] = code }
        if let phoneId { response["id"] = phoneId }
        guard let data = try? JSONSerialization.data(withJSONObject: response),
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

    func signOut() {
        do {
            try AppleSigningKeychain.delete()
            status = nil
            errorMessage = nil
            appleId = ""
            password = ""
        } catch {
            errorMessage = "Could not remove the saved signing session: \(error.localizedDescription)"
        }
    }

    private func startRestore(sessionJSON: String) {
        guard hasSigningBridge else { return }
        isWorking = true
        errorMessage = nil
        do {
            try prepareProtectedStorage()
        } catch {
            isWorking = false
            errorMessage = "Could not open protected signing storage: \(error.localizedDescription)"
            return
        }

        let storagePath = Self.signingStorageURL().path
        let bundleID = Bundle.main.bundleIdentifier ?? "com.Andrewdev.aquasign"
        #if SIGNING_BRIDGE
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var statusOutput: UnsafeMutablePointer<CChar>?
            var errorOutput: UnsafeMutablePointer<CChar>?
            let result = sessionJSON.withCString { sessionPointer in
                storagePath.withCString { storagePointer in
                    bundleID.withCString { bundlePointer in
                        sidepair_restore_session(
                            sessionPointer,
                            storagePointer,
                            bundlePointer,
                            &statusOutput,
                            &errorOutput
                        )
                    }
                }
            }
            let statusJSON = statusOutput.map { String(cString: $0) }
            let errorText = errorOutput.map { String(cString: $0) }
            if let statusOutput { sidepair_signing_string_free(statusOutput) }
            if let errorOutput { sidepair_signing_string_free(errorOutput) }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isWorking = false
                if result == 0, let statusJSON, let data = statusJSON.data(using: .utf8),
                   let restoredStatus = try? JSONDecoder().decode(AppleSigningStatus.self, from: data) {
                    self.appleId = restoredStatus.appleId
                    self.status = restoredStatus
                    self.errorMessage = restoredStatus.profileError.isEmpty ? nil : restoredStatus.profileError
                } else {
                    self.errorMessage = errorText ?? "The saved Apple session has expired. Sign in again to refresh it."
                    try? AppleSigningKeychain.delete()
                }
            }
        }
        #endif
    }

    private func presentTwoFactor(requestJSON: String, reply: @escaping (String?) -> Void) {
        guard let data = requestJSON.data(using: .utf8),
              let request = try? JSONDecoder().decode(AppleTwoFactorRequest.self, from: data) else {
            errorMessage = "Apple requested verification, but AquaSign could not read the request."
            reply(nil)
            return
        }
        twoFactorReply = reply
        twoFactorPrompt = AppleTwoFactorPrompt(request: request)
    }

    private func prepareProtectedStorage() throws {
        let directory = Self.signingStorageURL()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
    }

    private static func signingStorageURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SidePairSigning", isDirectory: true)
    }
}

private enum AppleSigningBridgeError: LocalizedError {
    case engineUnavailable
    case noSavedSession
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .engineUnavailable:
            "This build does not include the Apple signing engine."
        case .noSavedSession:
            "Sign in with your Apple ID before signing an IPA."
        case let .failed(message):
            message
        }
    }
}

private enum AppleSigningKeychain {
    private static let service = "com.organizationName.SidePair.apple-signing"
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
        guard status == errSecSuccess, let data = result as? Data else {
            throw AppleSigningKeychainError(status)
        }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw AppleSigningKeychainError(addStatus) }
        } else if status != errSecSuccess {
            throw AppleSigningKeychainError(status)
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
            throw AppleSigningKeychainError(status)
        }
    }
}

private struct AppleSigningKeychainError: LocalizedError {
    let status: OSStatus
    init(_ status: OSStatus) { self.status = status }
    var errorDescription: String? { "Keychain operation failed (\(status))." }
}

private final class TwoFactorResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    func set(_ value: String?) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

private final class SigningTwoFactorContext: @unchecked Sendable {
    private let present: @MainActor (String, @escaping (String?) -> Void) -> Void

    init(present: @escaping @MainActor (String, @escaping (String?) -> Void) -> Void) {
        self.present = present
    }

    func waitForAnswer(requestJSON: String) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        let response = TwoFactorResponseBox()
        DispatchQueue.main.async { [present] in
            present(requestJSON) { answer in
                response.set(answer)
                semaphore.signal()
            }
        }
        semaphore.wait()
        return response.get()
    }
}

#if SIGNING_BRIDGE
private typealias SigningTwoFactorCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?,
    UnsafeMutablePointer<CChar>?,
    UInt
) -> Int32

@_silgen_name("sidepair_sign_in")
private func sidepair_sign_in(
    _ appleID: UnsafePointer<CChar>,
    _ password: UnsafePointer<CChar>,
    _ storageDirectory: UnsafePointer<CChar>,
    _ bundleID: UnsafePointer<CChar>,
    _ deviceName: UnsafePointer<CChar>,
    _ deviceUDID: UnsafePointer<CChar>,
    _ twoFactorCallback: SigningTwoFactorCallback?,
    _ callbackContext: UnsafeMutableRawPointer?,
    _ outSessionJSON: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ outStatusJSON: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("sidepair_sign_ipa")
private func sidepair_sign_ipa(
    _ sessionJSON: UnsafePointer<CChar>,
    _ storageDirectory: UnsafePointer<CChar>,
    _ ipaPath: UnsafePointer<CChar>,
    _ deviceName: UnsafePointer<CChar>,
    _ deviceUDID: UnsafePointer<CChar>,
    _ outSignedAppPath: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("sidepair_restore_session")
private func sidepair_restore_session(
    _ sessionJSON: UnsafePointer<CChar>,
    _ storageDirectory: UnsafePointer<CChar>,
    _ bundleID: UnsafePointer<CChar>,
    _ outStatusJSON: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("sidepair_signing_string_free")
private func sidepair_signing_string_free(_ value: UnsafeMutablePointer<CChar>?)

private func duplicateCString(_ value: String) -> UnsafeMutablePointer<CChar>? {
    value.withCString { strdup($0) }
}

private func invokeAppleSignIn(
    account: String,
    password: String,
    storagePath: String,
    bundleID: String,
    deviceName: String,
    deviceUDID: String,
    callbackContext: UnsafeMutableRawPointer,
    outSessionJSON: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    outStatusJSON: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    guard let accountPointer = duplicateCString(account) else { return -1 }
    defer { free(accountPointer) }
    guard let passwordPointer = duplicateCString(password) else { return -1 }
    defer { free(passwordPointer) }
    guard let storagePointer = duplicateCString(storagePath) else { return -1 }
    defer { free(storagePointer) }
    guard let bundlePointer = duplicateCString(bundleID) else { return -1 }
    defer { free(bundlePointer) }
    guard let deviceNamePointer = duplicateCString(deviceName) else { return -1 }
    defer { free(deviceNamePointer) }
    guard let deviceUDIDPointer = duplicateCString(deviceUDID) else { return -1 }
    defer { free(deviceUDIDPointer) }

    return sidepair_sign_in(
        accountPointer,
        passwordPointer,
        storagePointer,
        bundlePointer,
        deviceNamePointer,
        deviceUDIDPointer,
        signingTwoFactorCallback,
        callbackContext,
        outSessionJSON,
        outStatusJSON,
        outError
    )
}

private let signingTwoFactorCallback: SigningTwoFactorCallback = { context, requestJSON, responseJSON, responseCapacity in
    guard let context, let requestJSON, let responseJSON else { return 0 }
    let handler = Unmanaged<SigningTwoFactorContext>.fromOpaque(context).takeUnretainedValue()
    guard let answer = handler.waitForAnswer(requestJSON: String(cString: requestJSON)) else { return 0 }
    let bytes = Array(answer.utf8) + [0]
    guard bytes.count <= Int(responseCapacity) else { return 0 }
    for (index, byte) in bytes.enumerated() {
        responseJSON[index] = CChar(bitPattern: byte)
    }
    return 1
}
#endif
